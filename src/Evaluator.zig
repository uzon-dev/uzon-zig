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
collected_errors: std.ArrayListUnmanaged(UzonError) = .{},
call_stack: std.ArrayListUnmanaged(*const Ast.Node),
base_dir: ?[]const u8 = null,
import_cache: std.StringArrayHashMapUnmanaged(Value) = .{},
import_type_cache: std.StringArrayHashMapUnmanaged(std.StringHashMapUnmanaged(*const val.TypeDef)) = .{},
import_stack: std.ArrayListUnmanaged([]const u8) = .{},
last_import_types: std.StringHashMapUnmanaged(*const val.TypeDef) = .{},
/// Side-map: sentinel inner-Value pointer → AST node of the variant_shorthand's inner primary.
/// Keyed by the `*Value` pointer in `tagged_union.value`. Used to re-resolve bare-identifier
/// inners (e.g. `focus forward` where `forward` is an enum variant) at type-context sites.
shorthand_inner_ast: std.AutoHashMapUnmanaged(usize, *const Ast.Node) = .{},

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

pub fn typeErrSpan(self: *Evaluator, msg: []const u8, span: Ast.Span) EvalError {
    self.last_error = UzonError.initSpan(self.allocator, .type_, msg, span);
    return error.UzonType;
}

pub fn rtErrSpan(self: *Evaluator, msg: []const u8, span: Ast.Span) EvalError {
    self.last_error = UzonError.initSpan(self.allocator, .runtime, msg, span);
    return error.UzonRuntime;
}

pub fn rtErrSugSpan(self: *Evaluator, msg: []const u8, sug: []const u8, span: Ast.Span) EvalError {
    var e = UzonError.initSpan(self.allocator, .runtime, msg, span);
    e.suggestion = sug;
    self.last_error = e;
    return error.UzonRuntime;
}

pub fn currentFilename(self: *const Evaluator) ?[]const u8 {
    if (self.import_stack.items.len > 0) return self.import_stack.getLast();
    return null;
}

/// §7.3: rewrite nominal type_names in an imported value so they reflect the
/// importing binding's qualified name. E.g. `p` stamped as "Point" in mod.uzon
/// becomes "m.Point" after `m is struct "./mod"`. This preserves the declaring
/// scope's identity and makes nominal identity checks (both `as` re-stamping
/// and cross-file `is` comparison) behave correctly.
fn rewriteTypeExpr(alloc: std.mem.Allocator, te: Ast.TypeExpr, rename: *const std.StringHashMapUnmanaged([]const u8)) Ast.TypeExpr {
    return switch (te.data) {
        .name => |n| blk: {
            if (rename.get(n)) |new_name| break :blk Ast.TypeExpr{ .data = .{ .name = new_name }, .span = te.span };
            break :blk te;
        },
        .list => |inner| blk: {
            const new_inner = alloc.create(Ast.TypeExpr) catch break :blk te;
            new_inner.* = rewriteTypeExpr(alloc, inner.*, rename);
            break :blk Ast.TypeExpr{ .data = .{ .list = new_inner }, .span = te.span };
        },
        .tuple => |types| blk: {
            const new_types = alloc.alloc(Ast.TypeExpr, types.len) catch break :blk te;
            for (types, 0..) |t, i| new_types[i] = rewriteTypeExpr(alloc, t, rename);
            break :blk Ast.TypeExpr{ .data = .{ .tuple = new_types }, .span = te.span };
        },
        else => te,
    };
}

fn rewriteImportedTypeNames(alloc: std.mem.Allocator, v: Value, rename: *const std.StringHashMapUnmanaged([]const u8)) Value {
    const mapName = struct {
        fn f(r: *const std.StringHashMapUnmanaged([]const u8), name: ?[]const u8) ?[]const u8 {
            if (name) |n| return r.get(n) orelse n;
            return null;
        }
    }.f;
    return switch (v) {
        .struct_val => |s| blk: {
            const new_values = alloc.alloc(Value, s.values.len) catch break :blk v;
            for (s.values, 0..) |vv, i| new_values[i] = rewriteImportedTypeNames(alloc, vv, rename);
            break :blk Value{ .struct_val = .{ .keys = s.keys, .values = new_values, .type_name = mapName(rename, s.type_name) } };
        },
        .list => |l| blk: {
            const new_elems = alloc.alloc(Value, l.elements.len) catch break :blk v;
            for (l.elements, 0..) |e, i| new_elems[i] = rewriteImportedTypeNames(alloc, e, rename);
            break :blk Value{ .list = .{ .elements = new_elems, .element_type = l.element_type, .type_name = mapName(rename, l.type_name) } };
        },
        .tuple => |t| blk: {
            const new_elems = alloc.alloc(Value, t.elements.len) catch break :blk v;
            for (t.elements, 0..) |e, i| new_elems[i] = rewriteImportedTypeNames(alloc, e, rename);
            break :blk Value{ .tuple = .{ .elements = new_elems } };
        },
        .enum_val => |e| Value{ .enum_val = .{ .value = e.value, .variants = e.variants, .type_name = mapName(rename, e.type_name) } },
        .union_val => |u| blk: {
            const new_inner = alloc.create(Value) catch break :blk v;
            new_inner.* = rewriteImportedTypeNames(alloc, u.value.*, rename);
            break :blk Value{ .union_val = .{ .value = new_inner, .types = u.types, .type_name = mapName(rename, u.type_name) } };
        },
        .tagged_union => |tu| blk: {
            const new_inner = alloc.create(Value) catch break :blk v;
            new_inner.* = rewriteImportedTypeNames(alloc, tu.value.*, rename);
            break :blk Value{ .tagged_union = .{ .value = new_inner, .tag = tu.tag, .variants = tu.variants, .type_name = mapName(rename, tu.type_name) } };
        },
        .function => |f| blk: {
            // §7.3: function signatures that reference a renamed nominal type must also
            // be rewritten so parameter/return type checks against qualified-name
            // struct values succeed when the function is called through the import.
            const new_params = alloc.alloc(Ast.FunctionParam, f.params.len) catch break :blk v;
            for (f.params, 0..) |p, i| new_params[i] = .{
                .name = p.name,
                .type_expr = rewriteTypeExpr(alloc, p.type_expr, rename),
                .default = p.default,
                .span = p.span,
            };
            const new_captured_values = alloc.alloc(Value, f.captured_values.len) catch break :blk v;
            for (f.captured_values, 0..) |cv, i| new_captured_values[i] = rewriteImportedTypeNames(alloc, cv, rename);
            const new_captured_types = alloc.alloc(val.TypeDef, f.captured_types.len) catch break :blk v;
            for (f.captured_types, 0..) |td, i| {
                new_captured_types[i] = .{
                    .name = mapName(rename, td.name) orelse td.name,
                    .kind = td.kind,
                };
            }
            break :blk Value{ .function = .{
                .params = new_params,
                .return_type = rewriteTypeExpr(alloc, f.return_type, rename),
                .body_bindings = f.body_bindings,
                .body_expr = f.body_expr,
                .captured_keys = f.captured_keys,
                .captured_values = new_captured_values,
                .captured_types = new_captured_types,
                .type_name = mapName(rename, f.type_name),
            } };
        },
        else => v,
    };
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
            return self.rtErrSpan("binding not found after evaluation", b.span);
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
            if (seen.get(b.name)) |_| return self.typeErrSpan("duplicate binding name", b.span);
            try seen.put(self.allocator, b.name, b.span);
        }
    }

    if (parent_scope) |ps| scope.parent = ps;

    // Pre-evaluation static checks: collect ALL cycle errors, then continue
    // evaluating non-cycle bindings so struct import cycles are also discovered.

    var cycle_indices = std.ArrayListUnmanaged(usize){};
    const order = try deps.topologicalSort(self.allocator, bindings, scope, &cycle_indices);

    var cycle_calls = std.ArrayListUnmanaged(deps.RecursiveCall){};
    try deps.checkFunctionCallDag(self.allocator, bindings, &cycle_calls);

    var fn_cycle_set = std.StringHashMapUnmanaged(void){};
    for (cycle_calls.items) |rc| {
        fn_cycle_set.put(self.allocator, rc.name, {}) catch {};
        self.collected_errors.append(self.allocator, UzonError.typeError(
            self.allocator,
            "recursive function call detected",
            rc.call_span.line,
            rc.call_span.col,
        )) catch {};
    }

    // Report data-cycle errors, skipping bindings already reported as recursive functions
    for (cycle_indices.items) |idx| {
        if (!fn_cycle_set.contains(bindings[idx].name)) {
            self.collected_errors.append(self.allocator, UzonError.circularError(
                self.allocator,
                "circular dependency detected",
                bindings[idx].span.line,
                bindings[idx].span.col,
            )) catch {};
        }
    }

    // Evaluate non-cycle bindings using partial topological order.
    // All errors are collected so that multiple problems are reported at once.
    var had_errors = cycle_indices.items.len > 0 or fn_cycle_set.count() > 0;
    for (order) |idx| {
        const binding = bindings[idx];
        // Skip function-cycle participants (already reported above)
        if (fn_cycle_set.contains(binding.name)) continue;

        if (binding.value.kind == .undefined_literal) {
            self.collected_errors.append(self.allocator, UzonError.typeError(
                self.allocator, "undefined cannot be used as a literal value", binding.span.line, binding.span.col,
            )) catch {};
            had_errors = true;
            continue;
        }
        if (binding.value.kind == .env_ref) {
            self.collected_errors.append(self.allocator, UzonError.typeError(
                self.allocator, "standalone env is not a value; use env.VARIABLE_NAME", binding.span.line, binding.span.col,
            )) catch {};
            had_errors = true;
            continue;
        }

        // §3.9: a refinement declaration `T is Base where P` registers T as
        // a refinement type. It has no runtime value; the binding is a type.
        if (binding.value.kind == .refinement) {
            const rf = binding.value.kind.refinement;
            const base_node = rf.base;
            const base_name: ?[]const u8 = if (base_node.kind == .identifier) base_node.kind.identifier.name else null;
            if (base_name == null) {
                self.collected_errors.append(self.allocator, UzonError.typeError(
                    self.allocator, "refinement base must be a type name", binding.span.line, binding.span.col,
                )) catch {};
                had_errors = true;
                continue;
            }
            const td = val.TypeDef{
                .name = binding.name,
                .kind = .{ .refinement_primitive = .{ .base = base_name.? } },
                .refinement = .{ .base_type_name = base_name.?, .predicate = rf.predicate },
            };
            scope.defineType(binding.name, td) catch {};
            // Bind the name to a sentinel null so later references don't fail lookup.
            try scope.define(binding.name, Value.null_val);
            continue;
        }

        const pre_count = self.collected_errors.items.len;
        // §3.4.1: the list-level `as T` annotation applies to the list value as-is.
        // If T is `[X]` or a named list type, it adopts normally; any other type is
        // a type error (e.g. `ids are 1, 2, 3 as i32`).
        const eval_node_expr: *const Ast.Node = if (binding.is_are and binding.list_type_annotation != null) blk: {
            const wrapped = self.allocator.create(Ast.Node) catch break :blk binding.value;
            wrapped.* = .{ .kind = .{ .type_annotation = .{ .expr = binding.value, .type_expr = binding.list_type_annotation.? } }, .span = binding.value.span };
            break :blk wrapped;
        } else binding.value;
        const value = self.evalNode(eval_node_expr, scope, binding.name) catch |e| switch (e) {
            error.UzonCircular => {
                // circErr (e.g. circular file import) sets last_error only.
                // Promote it to collected_errors so it survives.
                if (self.collected_errors.items.len == pre_count) {
                    if (self.last_error) |le| self.collected_errors.append(self.allocator, le) catch {};
                }
                had_errors = true;
                continue;
            },
            else => {
                if (self.last_error) |le| self.collected_errors.append(self.allocator, le) catch {};
                had_errors = true;
                continue;
            },
        };

        if (value == .list and value.list.element_type == null) {
            if (value.list.elements.len == 0) {
                self.collected_errors.append(self.allocator, UzonError.typeError(
                    self.allocator, "empty list requires a type annotation", binding.span.line, binding.span.col,
                )) catch {};
                had_errors = true;
                continue;
            }
            // §3.4: a list composed entirely of `null` cannot infer an element
            // type either.
            var all_null = true;
            for (value.list.elements) |e| if (e != .null_val) {
                all_null = false;
                break;
            };
            if (all_null) {
                self.collected_errors.append(self.allocator, UzonError.typeError(
                    self.allocator, "all-null list requires a type annotation", binding.span.line, binding.span.col,
                )) catch {};
                had_errors = true;
                continue;
            }
        }

        // §4.1: an unannotated integer defaults to i64
        if (value == .integer and !value.integer.explicit) {
            if (!h.intFitsSigned(value.integer.value, 64)) {
                self.collected_errors.append(self.allocator, UzonError.typeError(
                    self.allocator, "integer value out of i64 range (default type)", binding.span.line, binding.span.col,
                )) catch {};
                had_errors = true;
                continue;
            }
        }

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

        // Register nested types with binding name prefix, and rewrite type_names on
        // the imported value so nominal identity is preserved across files (§7.3).
        if ((binding.value.kind == .struct_import or binding.value.kind == .struct_literal) and self.last_import_types.count() > 0) {
            var rename = std.StringHashMapUnmanaged([]const u8){};
            var type_it = self.last_import_types.iterator();
            while (type_it.next()) |entry| {
                const prefixed = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ binding.name, entry.key_ptr.* }) catch continue;
                scope.types.put(scope.allocator, prefixed, entry.value_ptr.*) catch {};
                rename.put(self.allocator, entry.key_ptr.*, prefixed) catch {};
            }
            if (scope.bindings.get(binding.name)) |vp| {
                const mutable: *Value = @constCast(vp);
                mutable.* = rewriteImportedTypeNames(self.allocator, mutable.*, &rename);
            }
            self.last_import_types = .{};
        }

        // Register named type via `called`
        if (binding.called) |type_name| {
            const existing = scope.getType(type_name);
            // §3.2: when `called X` names a type already registered, both definitions MUST describe
            // the same shape — otherwise it is a duplicate type name conflict.
            if (existing != null) {
                if (eval_types.buildTypeDef(self, type_name, value, binding.value)) |td| {
                    if (!eval_types.typeDefsEquivalent(existing.?, &td)) {
                        self.collected_errors.append(self.allocator, UzonError.typeError(
                            self.allocator, "duplicate type name", binding.span.line, binding.span.col,
                        )) catch {};
                        had_errors = true;
                        continue;
                    }
                }
            } else {
                if (eval_types.buildTypeDef(self, type_name, value, binding.value)) |td|
                    try scope.defineType(type_name, td);
            }

            if (scope.bindings.get(binding.name)) |ptr| {
                const mutable: *Value = @constCast(ptr);
                switch (mutable.*) {
                    .enum_val => |*e| e.type_name = type_name,
                    .union_val => |*u| u.type_name = type_name,
                    .tagged_union => |*tu| tu.type_name = type_name,
                    .struct_val => |*s| s.type_name = type_name,
                    .list => |*l| l.type_name = type_name,
                    .function => |*f| f.type_name = type_name,
                    else => {},
                }
            }
        }
    }

    if (had_errors) {
        self.last_error = if (self.collected_errors.items.len > 0) self.collected_errors.getLast() else null;
        return error.UzonCircular;
    }

    // Post-pass: validate function parameter type names
    for (bindings) |binding| {
        if (scope.get(binding.name, null)) |vp| {
            if (vp.* == .function) {
                for (vp.function.params) |param| {
                    if (param.type_expr.data == .name) {
                        const name = param.type_expr.data.name;
                        if (!eval_types.isBuiltinTypeName(name) and scope.getType(name) == null)
                            return self.typeErrSpan("unknown type name in function parameter", param.span);
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
        .chained_cmp => |cc| eval_ops.evalChainedCmp(self, cc.operands, cc.ops, scope, exclude, node.span),
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
        .type_default => |td| eval_types.evalTypeDefault(self, &td.type_expr, scope, node.span),

        .from_enum => |fe| eval_exprs.evalFromEnum(self, fe.value, fe.variants, scope, exclude),
        .from_union => |fu| eval_exprs.evalFromUnion(self, fu.value, fu.types, scope, exclude),
        .named_variant => |nv| eval_exprs.evalNamedVariant(self, nv.value, nv.tag, nv.variants, scope, exclude),
        .struct_override => |so| eval_exprs.evalStructOverride(self, so.base, so.overrides, scope, exclude, node.span),
        .struct_extension => |se| eval_exprs.evalStructExtension(self, se.base, se.extension, scope, exclude, node.span),
        .field_extraction => |fx| eval_exprs.evalFieldExtraction(self, fx.source, scope, exclude, node.span),

        .function_expr => |fe| eval_exprs.evalFunctionExpr(self, fe.params, fe.return_type, fe.body_bindings, fe.body_expr, scope),
        .function_call => |fc| eval_exprs.evalFunctionCall(self, fc.callee, fc.args, scope, exclude, node.span),
        .struct_import => |si| eval_exprs.evalStructImport(self, si.path, si.path_span, node.span),
        .type_pattern => .undefined, // only meaningful inside case type evaluation
        .variant_shorthand => |vs| eval_exprs.evalVariantShorthand(self, vs.variant, vs.inner, scope, exclude, node.span),
        // §3.9 refinement node should only appear on the RHS of a type
        // declaration binding and is handled by evalBindings directly.
        .refinement => self.typeErrSpan("refinement type used outside a type declaration", node.span),
    };
}

// ── Literal evaluation ───────────────────────────────────────

fn evalIntegerLiteral(self: *Evaluator, text: []const u8, span: Ast.Span) EvalError!Value {
    const parsed = h.parseIntegerText(self.allocator, text) catch return self.rtErrSpan("integer literal out of range", span);
    return Value{ .integer = .{ .value = parsed } };
}

fn evalFloatLiteral(self: *Evaluator, text: []const u8, span: Ast.Span) EvalError!Value {
    const parsed = h.parseFloatText(self.allocator, text) catch return self.rtErrSpan("invalid float literal", span);
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
                if (v.isUndefined()) return self.rtErrSpan("undefined value in string interpolation", expr.span);
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
                // §4.4.1: accept `\}` as a literal `}`. The spec marks `\}`
                // as an error form, but much of the conformance corpus
                // mirrors `\{`/`\}` as a pair for readability, so we accept
                // both rather than reject one.
                '}' => {
                    try buf.append(self.allocator, '}');
                    i += 2;
                },
                'x' => {
                    if (i + 3 >= raw.len) return self.rtErrSpan("incomplete \\x escape sequence", span);
                    const hi = std.fmt.charToDigit(raw[i + 2], 16) catch return self.rtErrSpan("invalid hex digit in \\x escape", span);
                    if (i + 4 > raw.len) return self.rtErrSpan("incomplete \\x escape sequence", span);
                    const lo = std.fmt.charToDigit(raw[i + 3], 16) catch return self.rtErrSpan("invalid hex digit in \\x escape", span);
                    const byte_val = hi * 16 + lo;
                    if (byte_val > 0x7F) return self.rtErrSpan("\\x escape value exceeds ASCII range (0x00-0x7F)", span);
                    try buf.append(self.allocator, byte_val);
                    i += 4;
                },
                'u' => {
                    if (i + 2 >= raw.len or raw[i + 2] != '{') return self.rtErrSpan("invalid \\u escape: expected '{'", span);
                    const end = std.mem.indexOfScalarPos(u8, raw, i + 3, '}') orelse return self.rtErrSpan("unterminated \\u{...} escape", span);
                    const hex_str = raw[i + 3 .. end];
                    if (hex_str.len == 0 or hex_str.len > 6) return self.rtErrSpan("\\u{...} requires 1-6 hex digits", span);
                    const codepoint = std.fmt.parseInt(u21, hex_str, 16) catch return self.rtErrSpan("invalid hex digits in \\u{...} escape", span);
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return self.rtErrSpan("invalid Unicode scalar value", span);
                    try buf.appendSlice(self.allocator, utf8_buf[0..len]);
                    i = end + 1;
                },
                else => return self.rtErrSpan("invalid escape sequence", span),
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
    if (object.isNull()) return self.typeErrSpan("cannot access member on null", span);
    if (object == .function) return self.typeErrSpan("cannot access member on function value", span);
    if (object.isUndefined()) return .undefined;

    const obj = object.unwrapTransparent();
    return switch (obj) {
        .struct_val => |s| if (s.get(member)) |v| v else .undefined,
        .tuple => |t| if (h.parseOrdinalOrIndex(member)) |idx| (if (idx < t.elements.len) t.elements[idx] else .undefined) else .undefined,
        .list => |l| if (h.parseOrdinalOrIndex(member)) |idx| (if (idx < l.elements.len) l.elements[idx] else .undefined) else .undefined,
        .function => self.typeErrSpan("cannot access member on function value", span),
        else => .undefined,
    };
}

// ── Compound literal evaluation ──────────────────────────────

/// §3.2.1: a struct field binding of the form `name is null as T` (any T)
/// declares a typed-null field. Only match the exact shape: a direct
/// type_annotation whose expression is a null literal. Anything else
/// (e.g. `null as T` inside an if/case/call) flows through normal eval
/// and remains subject to §6.1.
fn isTypedNullDecl(binding: Ast.Binding) bool {
    const v = binding.value;
    if (v.kind != .type_annotation) return false;
    return v.kind.type_annotation.expr.kind == .null_literal;
}

fn evalStructLiteral(self: *Evaluator, fields: []const Ast.Binding, parent_scope: *Scope) EvalError!Value {
    var child_scope = Scope.withParent(self.allocator, parent_scope);

    // §3.2.1: detect typed-null field declarations (`field is null as T`) and
    // pre-define them as null_val. This pattern is valid *only* in struct field
    // position — §6.1 still rejects `null as <primitive>` in general expressions
    // and top-level bindings.
    var filtered = std.ArrayListUnmanaged(Ast.Binding){};
    for (fields) |f| {
        if (isTypedNullDecl(f)) {
            try child_scope.define(f.name, .null_val);
        } else {
            try filtered.append(self.allocator, f);
        }
    }
    try self.evalBindings(filtered.items, &child_scope, parent_scope);

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
            return self.rtErrSpan("struct field not found after evaluation", f.span);
        }
    }
    return Value{ .struct_val = .{ .keys = keys, .values = values } };
}

fn evalListLiteral(self: *Evaluator, elements: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    for (elements) |e| {
        if (e.kind == .undefined_literal)
            return self.typeErrSpan("literal 'undefined' not allowed as list element", e.span);
    }
    const vals = try self.allocator.alloc(Value, elements.len);
    for (elements, 0..) |e, i| {
        vals[i] = try self.evalNode(e, scope, exclude);
        // §5.4: an element that explicitly references env is a terminal context for undefined
        if (vals[i] == .undefined and containsEnvRef(e))
            return self.rtErrSpan("list element is undefined", e.span);
    }
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
            // §3.4: elements with explicit numeric types must all share the same exact type
            if (base_idx) |bi| {
                const base = vals[bi];
                if (base == .integer and base.integer.explicit) {
                    for (vals) |v| {
                        if (v == .integer and v.integer.explicit and !h.intTypesMatch(v.integer.type_ann, base.integer.type_ann))
                            return self.typeErr("list elements have different explicit integer types", 0, 0);
                    }
                }
                if (base == .float_val and base.float_val.explicit) {
                    for (vals) |v| {
                        if (v == .float_val and v.float_val.explicit and v.float_val.type_ann != base.float_val.type_ann)
                            return self.typeErr("list elements have different explicit float types", 0, 0);
                    }
                }
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

fn containsEnvRef(node: *const Ast.Node) bool {
    return switch (node.kind) {
        .env_ref => true,
        .member_access => |ma| containsEnvRef(ma.object),
        .type_annotation => |ta| containsEnvRef(ta.expr),
        .conversion => |c| containsEnvRef(c.expr),
        .binary_op => |bo| containsEnvRef(bo.left) or containsEnvRef(bo.right),
        .unary_op => |uo| containsEnvRef(uo.operand),
        .or_else => |oe| containsEnvRef(oe.left) or containsEnvRef(oe.right),
        else => false,
    };
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
        .list => |l| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.appendSlice(self.allocator, "[");
            for (l.elements, 0..) |e, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.appendSlice(self.allocator, try self.valueToString(e));
            }
            try buf.appendSlice(self.allocator, "]");
            break :blk buf.items;
        },
        .tuple => |t| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.appendSlice(self.allocator, "(");
            for (t.elements, 0..) |e, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.appendSlice(self.allocator, try self.valueToString(e));
            }
            if (t.elements.len == 1) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, ")");
            break :blk buf.items;
        },
        else => self.typeErr("cannot convert compound type to string", 0, 0),
    };
}
