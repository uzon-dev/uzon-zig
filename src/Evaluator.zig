const std = @import("std");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");
const deps = @import("deps.zig");
const err_mod = @import("error.zig");
const UzonError = err_mod.UzonError;

const eval_ops = @import("eval_ops.zig");
const eval_types = @import("eval_types.zig");
const eval_exprs = @import("eval_exprs.zig");
const h = @import("eval_helpers.zig");

const Evaluator = @This();

allocator: std.mem.Allocator,
last_error: ?UzonError,
call_stack: std.ArrayListUnmanaged(*const Ast.Node),
base_dir: ?[]const u8 = null,
import_cache: std.StringArrayHashMapUnmanaged(Value) = .{},
import_stack: std.ArrayListUnmanaged([]const u8) = .{},
last_import_types: std.StringHashMapUnmanaged(*const val.TypeDef) = .{},

pub const EvalError = error{ UzonType, UzonRuntime, UzonCircular, OutOfMemory };

pub fn init(allocator: std.mem.Allocator) Evaluator {
    return .{ .allocator = allocator, .last_error = null, .call_stack = .{} };
}

// ── Error helpers ────────────────────────────────────────────

pub fn typeErr(self: *Evaluator, msg: []const u8, line: u32, col: u32) EvalError {
    self.last_error = UzonError.typeError(self.allocator, msg, line, col);
    return error.UzonType;
}

pub fn typeErrSug(self: *Evaluator, msg: []const u8, sug: []const u8, line: u32, col: u32) EvalError {
    self.last_error = UzonError.initWithSuggestion(self.allocator, .type_, msg, sug, line, col);
    return error.UzonType;
}

pub fn rtErr(self: *Evaluator, msg: []const u8, line: u32, col: u32) EvalError {
    self.last_error = UzonError.runtimeError(self.allocator, msg, line, col);
    return error.UzonRuntime;
}

pub fn rtErrSug(self: *Evaluator, msg: []const u8, sug: []const u8, line: u32, col: u32) EvalError {
    self.last_error = UzonError.initWithSuggestion(self.allocator, .runtime, msg, sug, line, col);
    return error.UzonRuntime;
}

pub fn circErr(self: *Evaluator, msg: []const u8, line: u32, col: u32) EvalError {
    self.last_error = UzonError.circularError(self.allocator, msg, line, col);
    return error.UzonCircular;
}

pub fn currentFilename(self: *const Evaluator) ?[]const u8 {
    if (self.import_stack.items.len > 0) return self.import_stack.getLast();
    return null;
}

// ── Public entry points ──────────────────────────────────────

pub fn evalDocument(self: *Evaluator, doc: Ast.Document) EvalError!Value {
    return self.evalDocumentInScope(doc, null);
}

pub fn evalDocumentInScope(self: *Evaluator, doc: Ast.Document, import_scope: ?*Scope) EvalError!Value {
    var scope = Scope.init(self.allocator);
    try self.evalBindings(doc.bindings, &scope, null);

    if (import_scope) |is| {
        var type_it = scope.types.iterator();
        while (type_it.next()) |entry| is.types.put(is.allocator, entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const n = doc.bindings.len;
    const keys = try self.allocator.alloc([]const u8, n);
    const values = try self.allocator.alloc(Value, n);
    for (doc.bindings, 0..) |b, i| {
        keys[i] = b.name;
        if (scope.get(b.name, null)) |v| {
            values[i] = v.*;
        } else {
            return self.rtErr("binding not found after evaluation", b.span.line, b.span.col);
        }
    }
    return Value{ .struct_val = .{ .keys = keys, .values = values } };
}

pub fn evalBindings(self: *Evaluator, bindings: []const Ast.Binding, scope: *Scope, parent_scope: ?*const Scope) EvalError!void {
    if (bindings.len == 0) return;

    // Duplicate binding detection
    {
        var seen = std.StringHashMapUnmanaged(Ast.Span){};
        for (bindings) |b| {
            if (seen.get(b.name)) |_| return self.typeErr("duplicate binding name", b.span.line, b.span.col);
            try seen.put(self.allocator, b.name, b.span);
        }
    }

    if (parent_scope) |ps| scope.parent = ps;

    const order = deps.topologicalSort(self.allocator, bindings, scope) catch |e| switch (e) {
        error.UzonCircular => return self.circErr("circular dependency detected", bindings[0].span.line, bindings[0].span.col),
        error.OutOfMemory => return error.OutOfMemory,
    };

    deps.checkFunctionCallDag(self.allocator, bindings) catch |e| switch (e) {
        error.UzonCircular => return self.typeErr("recursive function call detected", bindings[0].span.line, bindings[0].span.col),
        error.OutOfMemory => return error.OutOfMemory,
    };

    for (order) |idx| {
        const binding = bindings[idx];
        if (binding.value.kind == .undefined_literal)
            return self.typeErr("undefined cannot be used as a literal value", binding.span.line, binding.span.col);
        if (binding.value.kind == .env_ref)
            return self.typeErr("standalone env is not a value; use env.VARIABLE_NAME", binding.span.line, binding.span.col);

        const value = try self.evalNode(binding.value, scope, binding.name);

        if (value == .list and value.list.elements.len == 0 and value.list.element_type == null)
            if (binding.value.kind == .list_literal)
                return self.typeErr("empty list requires a type annotation", binding.span.line, binding.span.col);

        if (binding.is_are) {
            const list_val: Value = switch (value) {
                .list => value,
                else => blk: {
                    const elems = try self.allocator.alloc(Value, 1);
                    elems[0] = value;
                    break :blk Value{ .list = .{ .elements = elems } };
                },
            };
            try scope.define(binding.name, list_val);
        } else {
            try scope.define(binding.name, value);
        }

        // Register nested types with binding name prefix
        if ((binding.value.kind == .struct_import or binding.value.kind == .struct_literal) and self.last_import_types.count() > 0) {
            var type_it = self.last_import_types.iterator();
            while (type_it.next()) |entry| {
                const prefixed = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ binding.name, entry.key_ptr.* }) catch continue;
                scope.types.put(scope.allocator, prefixed, entry.value_ptr.*) catch {};
            }
            self.last_import_types = .{};
        }

        // Register named type via `called`
        if (binding.called) |type_name| {
            if (scope.getType(type_name) != null)
                return self.typeErr("duplicate type name", binding.span.line, binding.span.col);
            if (eval_types.buildTypeDef(self, type_name, value)) |td|
                try scope.defineType(type_name, td);

            if (scope.bindings.get(binding.name)) |ptr| {
                const mutable: *Value = @constCast(ptr);
                switch (mutable.*) {
                    .enum_val => |*e| e.type_name = type_name,
                    .union_val => |*u| u.type_name = type_name,
                    .tagged_union => |*tu| tu.type_name = type_name,
                    .struct_val => |*s| s.type_name = type_name,
                    .function => |*f| f.type_name = type_name,
                    else => {},
                }
            }
        }
    }

    // Post-pass: validate function parameter type names
    for (bindings) |binding| {
        if (scope.get(binding.name, null)) |vp| {
            if (vp.* == .function) {
                for (vp.function.params) |param| {
                    if (param.type_expr.data == .name) {
                        const name = param.type_expr.data.name;
                        if (!eval_types.isBuiltinTypeName(name) and scope.getType(name) == null)
                            return self.typeErr("unknown type name in function parameter", param.span.line, param.span.col);
                    }
                }
            }
        }
    }
}

// ── Node evaluation ──────────────────────────────────────────

pub fn evalNode(self: *Evaluator, node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    return switch (node.kind) {
        .integer_literal => |lit| self.evalIntegerLiteral(lit.value, node.span),
        .float_literal => |lit| self.evalFloatLiteral(lit.value, node.span),
        .string_literal => |sl| self.evalStringLiteral(sl.parts, scope, exclude, node.span),
        .bool_literal => |bl| Value.boolean(bl.value),
        .null_literal => .null_val,
        .undefined_literal => .undefined,
        .inf_literal => |inf| Value{ .float_val = .{ .value = if (inf.negative) -std.math.inf(f64) else std.math.inf(f64) } },
        .nan_literal => Value{ .float_val = .{ .value = std.math.nan(f64) } },
        .env_ref => .undefined,

        .identifier => |id| self.evalIdentifier(id.name, scope, exclude),
        .member_access => |ma| self.evalMemberAccess(ma.object, ma.member, scope, exclude, node.span),

        .binary_op => |bo| eval_ops.evalBinaryOp(self, bo.op, bo.left, bo.right, scope, exclude, node.span),
        .unary_op => |uo| eval_ops.evalUnaryOp(self, uo.op, uo.operand, scope, exclude, node.span),
        .or_else => |oe| eval_ops.evalOrElse(self, oe.left, oe.right, scope, exclude, node.span),

        .if_expr => |ie| eval_exprs.evalIfExpr(self, ie.condition, ie.then_branch, ie.else_branch, scope, exclude, node.span),
        .case_expr => |ce| eval_exprs.evalCaseExpr(self, ce.mode, ce.scrutinee, ce.when_clauses, ce.else_branch, scope, exclude, node.span),

        .struct_literal => |sl| self.evalStructLiteral(sl.fields, scope),
        .list_literal => |ll| self.evalListLiteral(ll.elements, scope, exclude),
        .tuple_literal => |tl| self.evalTupleLiteral(tl.elements, scope, exclude),
        .grouping => |g| self.evalNode(g.expr, scope, exclude),

        .type_annotation => |ta| eval_types.evalTypeAnnotation(self, ta.expr, &ta.type_expr, scope, exclude, node.span),
        .conversion => |cv| eval_types.evalConversion(self, cv.expr, &cv.type_expr, scope, exclude, node.span),

        .from_enum => |fe| eval_exprs.evalFromEnum(self, fe.value, fe.variants, scope, exclude),
        .from_union => |fu| eval_exprs.evalFromUnion(self, fu.value, fu.types, scope, exclude),
        .named_variant => |nv| eval_exprs.evalNamedVariant(self, nv.value, nv.tag, nv.variants, scope, exclude),
        .struct_override => |so| eval_exprs.evalStructOverride(self, so.base, so.overrides, scope, exclude, node.span),
        .struct_extension => |se| eval_exprs.evalStructExtension(self, se.base, se.extension, scope, exclude, node.span),
        .field_extraction => |fx| eval_exprs.evalFieldExtraction(self, fx.source, scope, exclude, node.span),

        .function_expr => |fe| eval_exprs.evalFunctionExpr(self, fe.params, fe.return_type, fe.body_bindings, fe.body_expr, scope),
        .function_call => |fc| eval_exprs.evalFunctionCall(self, fc.callee, fc.args, scope, exclude, node.span),
        .struct_import => |si| eval_exprs.evalStructImport(self, si.path, node.span),
        .type_pattern => .undefined, // only meaningful inside case type evaluation
    };
}

// ── Literal evaluation ───────────────────────────────────────

fn evalIntegerLiteral(self: *Evaluator, text: []const u8, span: Ast.Span) EvalError!Value {
    const parsed = h.parseIntegerText(self.allocator, text) catch return self.rtErr("invalid integer literal", span.line, span.col);
    return Value{ .integer = .{ .value = parsed } };
}

fn evalFloatLiteral(self: *Evaluator, text: []const u8, span: Ast.Span) EvalError!Value {
    const parsed = h.parseFloatText(self.allocator, text) catch return self.rtErr("invalid float literal", span.line, span.col);
    return Value{ .float_val = .{ .value = parsed } };
}

fn evalStringLiteral(self: *Evaluator, parts: []const Ast.StringPart, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (parts.len == 1) {
        if (parts[0] == .literal) return Value.str(try self.unescapeString(parts[0].literal, span));
    }
    var buf = std.ArrayListUnmanaged(u8){};
    for (parts) |part| {
        switch (part) {
            .literal => |s| buf.appendSlice(self.allocator, try self.unescapeString(s, span)) catch return error.OutOfMemory,
            .interpolation => |expr| {
                const v = try self.evalNode(expr, scope, exclude);
                if (v.isUndefined()) return self.rtErr("undefined value in string interpolation", span.line, span.col);
                buf.appendSlice(self.allocator, try self.valueToString(v)) catch return error.OutOfMemory;
            },
        }
    }
    return Value.str(buf.items);
}

fn unescapeString(self: *Evaluator, raw: []const u8, span: Ast.Span) EvalError![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var buf = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            switch (raw[i + 1]) {
                'n' => {
                    try buf.append(self.allocator, '\n');
                    i += 2;
                },
                't' => {
                    try buf.append(self.allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try buf.append(self.allocator, '\r');
                    i += 2;
                },
                '\\' => {
                    try buf.append(self.allocator, '\\');
                    i += 2;
                },
                '"' => {
                    try buf.append(self.allocator, '"');
                    i += 2;
                },
                '0' => {
                    try buf.append(self.allocator, 0);
                    i += 2;
                },
                '{' => {
                    try buf.append(self.allocator, '{');
                    i += 2;
                },
                'x' => {
                    if (i + 3 >= raw.len) return self.rtErr("incomplete \\x escape sequence", span.line, span.col);
                    const hi = std.fmt.charToDigit(raw[i + 2], 16) catch return self.rtErr("invalid hex digit in \\x escape", span.line, span.col);
                    if (i + 4 > raw.len) return self.rtErr("incomplete \\x escape sequence", span.line, span.col);
                    const lo = std.fmt.charToDigit(raw[i + 3], 16) catch return self.rtErr("invalid hex digit in \\x escape", span.line, span.col);
                    const byte_val = hi * 16 + lo;
                    if (byte_val > 0x7F) return self.rtErr("\\x escape value exceeds ASCII range (0x00-0x7F)", span.line, span.col);
                    try buf.append(self.allocator, byte_val);
                    i += 4;
                },
                'u' => {
                    if (i + 2 >= raw.len or raw[i + 2] != '{') return self.rtErr("invalid \\u escape: expected '{'", span.line, span.col);
                    const end = std.mem.indexOfScalarPos(u8, raw, i + 3, '}') orelse return self.rtErr("unterminated \\u{...} escape", span.line, span.col);
                    const hex_str = raw[i + 3 .. end];
                    if (hex_str.len == 0 or hex_str.len > 6) return self.rtErr("\\u{...} requires 1-6 hex digits", span.line, span.col);
                    const codepoint = std.fmt.parseInt(u21, hex_str, 16) catch return self.rtErr("invalid hex digits in \\u{...} escape", span.line, span.col);
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return self.rtErr("invalid Unicode scalar value", span.line, span.col);
                    try buf.appendSlice(self.allocator, utf8_buf[0..len]);
                    i = end + 1;
                },
                else => return self.rtErr("invalid escape sequence", span.line, span.col),
            }
        } else {
            try buf.append(self.allocator, raw[i]);
            i += 1;
        }
    }
    return buf.items;
}

// ── Identifier and member access ─────────────────────────────

fn evalIdentifier(self: *Evaluator, name: []const u8, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    _ = self;
    if (scope.get(name, exclude)) |v| return v.*;
    return .undefined;
}

fn evalMemberAccess(self: *Evaluator, object_node: *const Ast.Node, member: []const u8, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (object_node.kind == .env_ref) {
        const env_val = std.posix.getenv(member);
        if (env_val) |ev| return Value.str(try self.allocator.dupe(u8, ev));
        return .undefined;
    }
    const object = try self.evalNode(object_node, scope, exclude);
    if (object.isNull()) return self.typeErr("cannot access member on null", span.line, span.col);
    if (object.isUndefined()) return .undefined;

    const obj = object.unwrapTransparent();
    return switch (obj) {
        .struct_val => |s| if (s.get(member)) |v| v else .undefined,
        .tuple => |t| if (h.parseOrdinalOrIndex(member)) |idx| (if (idx < t.elements.len) t.elements[idx] else .undefined) else .undefined,
        .list => |l| if (h.parseOrdinalOrIndex(member)) |idx| (if (idx < l.elements.len) l.elements[idx] else .undefined) else .undefined,
        else => .undefined,
    };
}

// ── Compound literal evaluation ──────────────────────────────

fn evalStructLiteral(self: *Evaluator, fields: []const Ast.Binding, parent_scope: *Scope) EvalError!Value {
    var child_scope = Scope.withParent(self.allocator, parent_scope);
    try self.evalBindings(fields, &child_scope, parent_scope);

    if (child_scope.types.count() > 0) {
        self.last_import_types = .{};
        var type_it = child_scope.types.iterator();
        while (type_it.next()) |entry| self.last_import_types.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    const n = fields.len;
    const keys = try self.allocator.alloc([]const u8, n);
    const values = try self.allocator.alloc(Value, n);
    for (fields, 0..) |f, i| {
        keys[i] = f.name;
        if (child_scope.get(f.name, null)) |v| {
            values[i] = v.*;
        } else {
            return self.rtErr("struct field not found after evaluation", f.span.line, f.span.col);
        }
    }
    return Value{ .struct_val = .{ .keys = keys, .values = values } };
}

fn evalListLiteral(self: *Evaluator, elements: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    const vals = try self.allocator.alloc(Value, elements.len);
    for (elements, 0..) |e, i| vals[i] = try self.evalNode(e, scope, exclude);
    if (vals.len == 0) return Value{ .list = .{ .elements = vals } };

    if (vals.len >= 2) {
        var base_idx: ?usize = null;
        const base_cat: ?[]const u8 = for (vals, 0..) |v, i| {
            if (v != .null_val and v != .undefined) {
                base_idx = i;
                break h.valueTypeCategory(v);
            }
        } else null;
        if (base_cat) |bc| {
            var has_float = std.mem.eql(u8, bc, "float");
            for (vals, 0..) |v, i| {
                if (v == .null_val or v == .undefined) continue;
                const vc = h.valueTypeCategory(v) orelse continue;
                if (!std.mem.eql(u8, bc, vc)) {
                    const numeric_mix = (std.mem.eql(u8, bc, "integer") and std.mem.eql(u8, vc, "float")) or
                        (std.mem.eql(u8, bc, "float") and std.mem.eql(u8, vc, "integer"));
                    if (!numeric_mix) return self.typeErr("list elements must have the same type", 0, 0);
                    if (std.mem.eql(u8, vc, "float")) has_float = true;
                }
                if (std.mem.eql(u8, bc, "struct") and v == .struct_val)
                    if (base_idx) |bi| if (i != bi) try self.validateStructHomogeneity(vals[bi].struct_val, v.struct_val);
            }
            if (has_float) {
                for (vals, 0..) |v, vi| {
                    if (v == .integer) vals[vi] = Value{ .float_val = .{ .value = @floatFromInt(v.integer.value) } };
                }
            }
        }
    }
    return Value{ .list = .{ .elements = vals } };
}

fn validateStructHomogeneity(self: *Evaluator, base: val.Struct, other: val.Struct) EvalError!void {
    if (base.type_name != null or other.type_name != null) {
        const bn = base.type_name orelse "";
        const on = other.type_name orelse "";
        if (!std.mem.eql(u8, bn, on)) return self.typeErr("list struct elements have different named types", 0, 0);
    }
    if (base.keys.len != other.keys.len) return self.typeErr("list struct elements have different field counts", 0, 0);
    for (base.keys, 0..) |key, i| {
        var found = false;
        for (other.keys, 0..) |ok, oi| {
            if (std.mem.eql(u8, key, ok)) {
                found = true;
                const bv = base.values[i];
                const ov = other.values[oi];
                if (bv == .null_val or bv == .undefined or ov == .null_val or ov == .undefined) break;
                const bt = h.valueTypeCategory(bv) orelse break;
                const ot = h.valueTypeCategory(ov) orelse break;
                if (!std.mem.eql(u8, bt, ot)) {
                    const numeric_mix = (std.mem.eql(u8, bt, "integer") and std.mem.eql(u8, ot, "float")) or
                        (std.mem.eql(u8, bt, "float") and std.mem.eql(u8, ot, "integer"));
                    if (!numeric_mix) return self.typeErr("list struct elements have different value types for same field", 0, 0);
                }
                break;
            }
        }
        if (!found) return self.typeErr("list struct elements have different field names", 0, 0);
    }
}

fn evalTupleLiteral(self: *Evaluator, elements: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    const vals = try self.allocator.alloc(Value, elements.len);
    for (elements, 0..) |e, i| vals[i] = try self.evalNode(e, scope, exclude);
    return Value{ .tuple = .{ .elements = vals } };
}

// ── Value-to-string ──────────────────────────────────────────

fn valueToString(self: *Evaluator, v: Value) EvalError![]const u8 {
    return switch (v) {
        .null_val => "null",
        .undefined => "undefined",
        .bool_val => |b| if (b) "true" else "false",
        .integer => |i| blk: {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i.value}) catch return error.OutOfMemory;
            break :blk try self.allocator.dupe(u8, s);
        },
        .float_val => |f| try h.formatFloat(self.allocator, f.value),
        .string => |s| s,
        .enum_val => |e| e.value,
        .union_val => |u| self.valueToString(u.value.*),
        .tagged_union => |tu| self.valueToString(tu.value.*),
        else => self.typeErr("cannot convert compound type to string", 0, 0),
    };
}
