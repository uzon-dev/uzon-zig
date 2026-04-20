const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");
const h = @import("eval_helpers.zig");
const eval_types = @import("eval_types.zig");
const eval_ops = @import("eval_ops.zig");

const EvalError = Evaluator.EvalError;

// ── if/case expressions ──────────────────────────────────────

pub fn evalIfExpr(self: *Evaluator, cond_node: *const Ast.Node, then_node: *const Ast.Node, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (then_node.kind == .undefined_literal)
        return self.typeErrSpan("literal 'undefined' not allowed in if/then branch", then_node.span);
    if (else_node.kind == .undefined_literal)
        return self.typeErrSpan("literal 'undefined' not allowed in if/else branch", else_node.span);
    const cond = try self.evalNode(cond_node, scope, exclude);
    switch (cond) {
        .bool_val => |bv| {
            // §5.9 R8: symmetric narrowing for `is [not] type T` / `is [not] named V`.
            var then_ns: Scope = undefined;
            var else_ns: Scope = undefined;
            var then_scope: *Scope = scope;
            var else_scope: *Scope = scope;
            if (buildIfNarrowedScopes(self, cond_node, scope, &then_ns, &else_ns)) {
                then_scope = &then_ns;
                else_scope = &else_ns;
            }

            if (bv) {
                const result = try self.evalNode(then_node, then_scope, exclude);
                const else_val = self.evalNode(else_node, else_scope, exclude) catch |e| switch (e) {
                    error.UzonRuntime => return result,
                    else => return e,
                };
                if (!h.branchTypesCompatible(result, else_val))
                    return self.typeErrSpan("if/else branches have incompatible types", span);
                return result;
            } else {
                const then_val = self.evalNode(then_node, then_scope, exclude) catch |e| switch (e) {
                    error.UzonRuntime => return try self.evalNode(else_node, else_scope, exclude),
                    else => return e,
                };
                const result = try self.evalNode(else_node, else_scope, exclude);
                if (!h.branchTypesCompatible(then_val, result))
                    return self.typeErrSpan("if/else branches have incompatible types", span);
                return result;
            }
        },
        else => return self.typeErrSug("if condition must be bool", "compare explicitly, e.g. 'if x > 0 then ...'", span.line, span.col),
    }
}

/// §5.9 R8: build symmetric narrowed scopes for `if x is [not] type T` and
/// `if x is [not] named V`. Returns true if a narrowing pattern matched.
fn buildIfNarrowedScopes(self: *Evaluator, cond_node: *const Ast.Node, scope: *Scope, then_ns: *Scope, else_ns: *Scope) bool {
    if (cond_node.kind != .binary_op) return false;
    const bo = cond_node.kind.binary_op;
    const is_type = bo.op == .is_type or bo.op == .is_not_type;
    const is_name = bo.op == .is_named or bo.op == .is_not_named;
    if (!is_type and !is_name) return false;
    if (bo.left.kind != .identifier) return false;
    if (bo.right.kind != .identifier) return false;
    const sc_name = bo.left.kind.identifier.name;
    const target = bo.right.kind.identifier.name;
    const sc_val_ptr = scope.get(sc_name, null) orelse return false;
    const sc_val = sc_val_ptr.*;
    const then_positive = (bo.op == .is_type or bo.op == .is_named);
    then_ns.* = Scope.withParent(self.allocator, scope);
    else_ns.* = Scope.withParent(self.allocator, scope);
    if (is_type) {
        narrowByType(then_ns, sc_name, sc_val, target, then_positive);
        narrowByType(else_ns, sc_name, sc_val, target, !then_positive);
    } else {
        narrowByName(then_ns, sc_name, sc_val, target, then_positive);
        narrowByName(else_ns, sc_name, sc_val, target, !then_positive);
    }
    return true;
}

fn narrowByType(child: *Scope, sc_name: []const u8, sc_val: Value, type_name: []const u8, positive: bool) void {
    const inner = sc_val.unwrapTransparent();
    if (positive) {
        const adopted = h.adoptToType(inner, type_name);
        const narrowed = if (h.valueMatchesType(adopted, type_name)) adopted else h.defaultValueForType(type_name);
        child.define(sc_name, narrowed) catch {};
        return;
    }
    // Negative narrowing: only unwrap when exactly one non-T union member remains.
    if (sc_val != .union_val) return;
    var non_t_count: usize = 0;
    var only_non_t: ?[]const u8 = null;
    for (sc_val.union_val.types) |t| {
        if (std.mem.eql(u8, t, type_name)) continue;
        non_t_count += 1;
        only_non_t = t;
    }
    if (non_t_count != 1) return;
    const t = only_non_t.?;
    const adopted = h.adoptToType(inner, t);
    const narrowed = if (h.valueMatchesType(adopted, t)) adopted else h.defaultValueForType(t);
    child.define(sc_name, narrowed) catch {};
}

fn narrowByName(child: *Scope, sc_name: []const u8, sc_val: Value, variant_name: []const u8, positive: bool) void {
    if (sc_val != .tagged_union) return;
    const tu = sc_val.tagged_union;
    const tag_matches = std.mem.eql(u8, tu.tag, variant_name);
    if (positive) {
        if (tag_matches) {
            child.define(sc_name, tu.value.*) catch {};
        } else {
            for (tu.variants) |v| if (std.mem.eql(u8, v.name, variant_name)) {
                const def = if (v.type_name) |tn| h.defaultValueForType(tn) else Value.null_val;
                child.define(sc_name, def) catch {};
                return;
            };
        }
        return;
    }
    // Negative narrowing: only unwrap when exactly one non-V variant remains.
    var non_v_count: usize = 0;
    var only_non_v_idx: ?usize = null;
    for (tu.variants, 0..) |v, i| {
        if (std.mem.eql(u8, v.name, variant_name)) continue;
        non_v_count += 1;
        only_non_v_idx = i;
    }
    if (non_v_count != 1) return;
    const single = tu.variants[only_non_v_idx.?];
    if (!tag_matches) {
        child.define(sc_name, tu.value.*) catch {};
    } else {
        const def = if (single.type_name) |tn| h.defaultValueForType(tn) else Value.null_val;
        child.define(sc_name, def) catch {};
    }
}

pub fn evalCaseExpr(self: *Evaluator, mode: Ast.CaseMode, scrutinee_node: *const Ast.Node, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    return switch (mode) {
        .value => evalCaseValue(self, scrutinee_node, when_clauses, else_node, scope, exclude, span),
        .type_ => evalCaseType(self, scrutinee_node, when_clauses, else_node, scope, exclude, span),
        .named => evalCaseNamed(self, scrutinee_node, when_clauses, else_node, scope, exclude, span),
    };
}

fn evalCaseValue(self: *Evaluator, scrutinee_node: *const Ast.Node, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const scrutinee = try self.evalNode(scrutinee_node, scope, exclude);
    if (scrutinee.isUndefined()) return self.rtErrSpan("case scrutinee is undefined", scrutinee_node.span);
    if (scrutinee == .union_val) return self.typeErrSpan("case value cannot be used with untagged unions; use case type", span);

    const match_scrutinee = scrutinee.unwrapTransparent();

    var matched_idx: ?usize = null;
    for (when_clauses, 0..) |wc, i| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErrSpan("undefined cannot be used as a when value", span);
        // Enum variant resolution in when clauses
        const when_val = blk: {
            if (match_scrutinee == .enum_val and wc.value.kind == .identifier) {
                const ident_name = wc.value.kind.identifier.name;
                for (match_scrutinee.enum_val.variants) |v| {
                    if (std.mem.eql(u8, v, ident_name))
                        break :blk Value{ .enum_val = .{ .value = ident_name, .variants = match_scrutinee.enum_val.variants, .type_name = match_scrutinee.enum_val.type_name } };
                }
            }
            break :blk try self.evalNode(wc.value, scope, exclude);
        };
        if (!when_val.isNull() and !when_val.isUndefined() and !match_scrutinee.isNull())
            if (!h.branchTypesCompatible(match_scrutinee, when_val))
                return self.typeErrSpan("case when value must be same type as scrutinee", span);
        if (h.runtimeEqual(match_scrutinee, when_val)) {
            matched_idx = i;
            break;
        }
    }

    return evalCaseBranches(self, when_clauses, else_node, matched_idx, scope, exclude, span);
}

fn evalCaseType(self: *Evaluator, scrutinee_node: *const Ast.Node, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const scrutinee = try self.evalNode(scrutinee_node, scope, exclude);
    if (scrutinee.isUndefined()) return self.rtErrSpan("case scrutinee is undefined", scrutinee_node.span);

    const check_val = scrutinee.unwrapTransparent();
    const scrutinee_name: ?[]const u8 = if (scrutinee_node.kind == .identifier) scrutinee_node.kind.identifier.name else null;

    // Validate all when-clause types
    for (when_clauses) |wc| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErrSpan("undefined cannot be used as a when value", span);
        const tn = whenClauseTypeString(self.allocator, wc) orelse continue;
        if (scrutinee == .union_val) {
            var valid = false;
            for (scrutinee.union_val.types) |t| if (std.mem.eql(u8, t, tn)) {
                valid = true;
                break;
            };
            if (!valid) return self.typeErrSpan("when type is not a member of the union", span);
        } else if (scrutinee == .tagged_union) {
            var valid = false;
            for (scrutinee.tagged_union.variants) |v| if (v.type_name) |vtn| if (std.mem.eql(u8, vtn, tn)) {
                valid = true;
                break;
            };
            if (!valid) return self.typeErrSpan("when type is not a variant type of the tagged union", span);
        }
    }

    var matched_idx: ?usize = null;
    for (when_clauses, 0..) |wc, i| {
        if (scrutinee == .tagged_union) {
            const tn = whenClauseTypeName(wc) orelse continue;
            for (scrutinee.tagged_union.variants) |v| {
                if (std.mem.eql(u8, v.name, scrutinee.tagged_union.tag))
                    if (v.type_name) |vtn| if (std.mem.eql(u8, vtn, tn)) {
                        matched_idx = i;
                    };
            }
            if (matched_idx != null) break;
        } else if (valueMatchesWhenType(check_val, wc)) {
            matched_idx = i;
            break;
        }
    }

    // Evaluate with narrowed scopes
    if (matched_idx) |idx| {
        const mt = whenClauseTypeName(when_clauses[idx]);
        var ns = makeNarrowedScope(self, scope, scrutinee_name, check_val, mt);
        const result = try self.evalNode(when_clauses[idx].result, &ns, exclude);
        for (when_clauses, 0..) |wc, i| {
            if (i != idx) {
                const wt = whenClauseTypeName(wc);
                var ws = makeNarrowedScope(self, scope, scrutinee_name, check_val, wt);
                const other = self.evalNode(wc.result, &ws, exclude) catch |e| switch (e) {
                    error.UzonRuntime => continue,
                    else => return e,
                };
                if (!h.branchTypesCompatible(result, other))
                    return self.typeErrSpan("case type branches have incompatible types", span);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErrSpan("case type branches have incompatible types", span);
        return result;
    } else {
        const result = try self.evalNode(else_node, scope, exclude);
        for (when_clauses) |wc| {
            const wt = whenClauseTypeName(wc);
            var ws = makeNarrowedScope(self, scope, scrutinee_name, check_val, wt);
            const other = self.evalNode(wc.result, &ws, exclude) catch |e| switch (e) {
                error.UzonRuntime => continue,
                else => return e,
            };
            if (!h.branchTypesCompatible(result, other))
                return self.typeErrSpan("case type branches have incompatible types", span);
        }
        return result;
    }
}

/// Extract simple type name from a when clause node (identifier or null for compound types).
fn whenClauseTypeName(wc: Ast.WhenClause) ?[]const u8 {
    return if (wc.value.kind == .identifier) wc.value.kind.identifier.name else null;
}

/// Get the type string for a when clause (simple name or serialized compound type).
fn whenClauseTypeString(allocator: std.mem.Allocator, wc: Ast.WhenClause) ?[]const u8 {
    if (wc.value.kind == .identifier) return wc.value.kind.identifier.name;
    if (wc.value.kind == .type_pattern) return typeExprToString(allocator, wc.value.kind.type_pattern.type_expr) catch null;
    return null;
}

/// Check if a value matches a when clause type (simple name or compound type pattern).
fn valueMatchesWhenType(check_val: Value, wc: Ast.WhenClause) bool {
    if (wc.value.kind == .identifier) return h.valueMatchesType(check_val, wc.value.kind.identifier.name);
    if (wc.value.kind == .type_pattern) return valueMatchesTypeExpr(check_val, wc.value.kind.type_pattern.type_expr);
    return false;
}

/// Adopt a value to match a compound type expression (recursive analog of h.adoptToType).
fn adoptToTypeExpr(allocator: std.mem.Allocator, v: Value, te: Ast.TypeExpr) Value {
    return switch (te.data) {
        .name => |name| h.adoptToType(v, name),
        .list => |inner| blk: {
            if (v != .list) break :blk v;
            const l = v.list;
            const new_elements = allocator.alloc(Value, l.elements.len) catch break :blk v;
            for (l.elements, 0..) |elem, i| {
                new_elements[i] = adoptToTypeExpr(allocator, elem, inner.*);
            }
            // §3.6: for an empty list, stamp the element_type from the target
            // so that valueMatchesTypeExpr can confirm the match.
            const elem_type: ?[]const u8 = if (l.elements.len == 0) blk2: {
                break :blk2 switch (inner.data) {
                    .name => |n| n,
                    else => l.element_type,
                };
            } else l.element_type;
            break :blk Value{ .list = .{ .elements = new_elements, .element_type = elem_type } };
        },
        .tuple => |types| blk: {
            if (v != .tuple) break :blk v;
            const t = v.tuple;
            if (t.elements.len != types.len) break :blk v;
            const new_elements = allocator.alloc(Value, t.elements.len) catch break :blk v;
            for (t.elements, types, 0..) |elem, typ, i| {
                new_elements[i] = adoptToTypeExpr(allocator, elem, typ);
            }
            break :blk Value{ .tuple = .{ .elements = new_elements } };
        },
        .null_type, .path => v,
    };
}

/// Check if a value matches a compound type expression.
fn valueMatchesTypeExpr(v: Value, te: Ast.TypeExpr) bool {
    return switch (te.data) {
        .name => |name| h.valueMatchesType(v, name),
        .list => |inner| blk: {
            if (v != .list) break :blk false;
            const l = v.list;
            if (l.elements.len == 0) {
                // Empty list: check element_type annotation
                if (l.element_type) |et| break :blk typeExprMatchesName(inner.*, et);
                break :blk false;
            }
            // Check first non-null element matches inner type
            for (l.elements) |e| {
                if (e == .null_val) continue;
                break :blk valueMatchesTypeExpr(e, inner.*);
            }
            break :blk false;
        },
        .tuple => |types| blk: {
            if (v != .tuple) break :blk false;
            const t = v.tuple;
            if (t.elements.len != types.len) break :blk false;
            for (t.elements, types) |elem, typ| {
                if (!valueMatchesTypeExpr(elem, typ)) break :blk false;
            }
            break :blk true;
        },
        .null_type => v == .null_val,
        .path => false,
    };
}

fn typeExprMatchesName(te: Ast.TypeExpr, name: []const u8) bool {
    return switch (te.data) {
        .name => |n| std.mem.eql(u8, n, name),
        else => false,
    };
}

/// Serialize a TypeExpr to a canonical string for union type storage.
fn typeExprToString(allocator: std.mem.Allocator, te: Ast.TypeExpr) ![]const u8 {
    return switch (te.data) {
        .name => |n| n,
        .list => |inner| blk: {
            const inner_str = try typeExprToString(allocator, inner.*);
            break :blk try std.fmt.allocPrint(allocator, "[{s}]", .{inner_str});
        },
        .tuple => |types| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.append(allocator, '(');
            for (types, 0..) |t, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const ts = try typeExprToString(allocator, t);
                try buf.appendSlice(allocator, ts);
            }
            try buf.append(allocator, ')');
            break :blk buf.items;
        },
        .null_type => "null",
        .path => |p| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            for (p, 0..) |seg, i| {
                if (i > 0) try buf.append(allocator, '.');
                try buf.appendSlice(allocator, seg);
            }
            break :blk buf.items;
        },
    };
}

fn evalCaseNamed(self: *Evaluator, scrutinee_node: *const Ast.Node, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const scrutinee = try self.evalNode(scrutinee_node, scope, exclude);
    if (scrutinee.isUndefined()) return self.rtErrSpan("case scrutinee is undefined", scrutinee_node.span);
    const tu = switch (scrutinee) {
        .tagged_union => |t| t,
        else => return self.typeErrSpan("'case named' requires tagged union", span),
    };

    const scrutinee_name: ?[]const u8 = if (scrutinee_node.kind == .identifier) scrutinee_node.kind.identifier.name else null;

    var matched_idx: ?usize = null;
    for (when_clauses, 0..) |wc, i| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErrSpan("undefined cannot be used as a when value", span);
        const vn = if (wc.value.kind == .identifier) wc.value.kind.identifier.name else continue;
        if (!h.isValidVariantTag(tu.variants, vn))
            return self.typeErrSpan("unknown variant name in 'case named'", span);
        if (std.mem.eql(u8, tu.tag, vn)) {
            matched_idx = i;
            break;
        }
    }

    if (matched_idx) |idx| {
        var narrowed = Scope.withParent(self.allocator, scope);
        if (scrutinee_name) |sn| narrowed.define(sn, tu.value.*) catch {};
        const result = try self.evalNode(when_clauses[idx].result, &narrowed, exclude);
        for (when_clauses, 0..) |wc, i| {
            if (i != idx) {
                const vn = if (wc.value.kind == .identifier) wc.value.kind.identifier.name else null;
                var ns = Scope.withParent(self.allocator, scope);
                if (scrutinee_name) |sn| {
                    ns.define(sn, getVariantDefault(tu.variants, vn)) catch {};
                }
                const other = self.evalNode(wc.result, &ns, exclude) catch |e| switch (e) {
                    error.UzonRuntime => continue,
                    else => return e,
                };
                if (!h.branchTypesCompatible(result, other))
                    return self.typeErrSpan("case named branches have incompatible types", span);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErrSpan("case named branches have incompatible types", span);
        return result;
    } else {
        const result = try self.evalNode(else_node, scope, exclude);
        for (when_clauses) |wc| {
            const vn = if (wc.value.kind == .identifier) wc.value.kind.identifier.name else null;
            var ns = Scope.withParent(self.allocator, scope);
            if (scrutinee_name) |sn| ns.define(sn, getVariantDefault(tu.variants, vn)) catch {};
            const other = self.evalNode(wc.result, &ns, exclude) catch |e| switch (e) {
                error.UzonRuntime => continue,
                else => return e,
            };
            if (!h.branchTypesCompatible(result, other))
                return self.typeErrSpan("case named branches have incompatible types", span);
        }
        return result;
    }
}

/// Evaluate case value branches with speculative checks.
fn evalCaseBranches(self: *Evaluator, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, matched_idx: ?usize, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (matched_idx) |idx| {
        const result = try self.evalNode(when_clauses[idx].result, scope, exclude);
        for (when_clauses, 0..) |wc, i| {
            if (i != idx) {
                const other = self.evalNode(wc.result, scope, exclude) catch |e| switch (e) {
                    error.UzonRuntime => continue,
                    else => return e,
                };
                if (!h.branchTypesCompatible(result, other))
                    return self.typeErrSpan("case branches have incompatible types", span);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErrSpan("case branches have incompatible types", span);
        return result;
    } else {
        const result = try self.evalNode(else_node, scope, exclude);
        for (when_clauses) |wc| {
            const other = self.evalNode(wc.result, scope, exclude) catch |e| switch (e) {
                error.UzonRuntime => continue,
                else => return e,
            };
            if (!h.branchTypesCompatible(result, other))
                return self.typeErrSpan("case branches have incompatible types", span);
        }
        return result;
    }
}

fn makeNarrowedScope(self: *Evaluator, parent: *Scope, scrutinee_name: ?[]const u8, inner_val: Value, type_name: ?[]const u8) Scope {
    if (scrutinee_name == null or type_name == null) return Scope.withParent(self.allocator, parent);
    var child = Scope.withParent(self.allocator, parent);
    const adopted = h.adoptToType(inner_val, type_name.?);
    const narrowed = if (h.valueMatchesType(adopted, type_name.?)) adopted else h.defaultValueForType(type_name.?);
    child.define(scrutinee_name.?, narrowed) catch {};
    return child;
}

fn getVariantDefault(variants: []const val.TaggedUnion.VariantInfo, variant_name: ?[]const u8) Value {
    const vn = variant_name orelse return .undefined;
    for (variants) |v| {
        if (std.mem.eql(u8, v.name, vn)) {
            if (v.type_name) |tn| return h.defaultValueForType(tn);
            return .null_val;
        }
    }
    return .undefined;
}

// ── Variant shorthand (§3.7 v0.10) ───────────────────────────

/// Evaluate `variant_name inner_primary`. Produces a sentinel tagged_union
/// (variants=empty, type_name=null) awaiting resolution via outer context
/// (stampNamedType, function arg/return adoption, list element adoption).
pub fn evalVariantShorthand(self: *Evaluator, variant: []const u8, inner_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    _ = span;
    // Try to evaluate inner. If it errors (e.g. bare variant name not in scope), defer to resolution.
    const inner: Value = self.evalNode(inner_node, scope, exclude) catch blk: {
        // swallow the error — resolveShorthandAgainstType will retry with type context
        self.last_error = null;
        break :blk .undefined;
    };
    const vp = try self.allocator.create(Value);
    vp.* = inner;
    // Record inner AST so resolution can re-interpret bare identifiers against the variant's type.
    self.shorthand_inner_ast.put(self.allocator, @intFromPtr(vp), inner_node) catch {};
    return Value{ .tagged_union = .{ .value = vp, .tag = variant, .variants = &.{}, .type_name = null } };
}

/// True if `v` is an unresolved variant-shorthand sentinel.
pub fn isShorthandSentinel(v: Value) bool {
    return v == .tagged_union and v.tagged_union.variants.len == 0 and v.tagged_union.type_name == null;
}

/// Resolve a shorthand sentinel against a known tagged-union TypeDef.
pub fn resolveShorthandAgainstType(self: *Evaluator, sentinel: Value, td: *const val.TypeDef, type_name: []const u8, scope: ?*Scope, span: Ast.Span) EvalError!Value {
    std.debug.assert(isShorthandSentinel(sentinel));
    const tut = switch (td.kind) {
        .tagged_union_type => |t| t,
        else => return self.typeErrSpan("variant shorthand target is not a tagged union", span),
    };
    const tag = sentinel.tagged_union.tag;
    const inner_val = sentinel.tagged_union.value.*;
    const inner_ast: ?*const Ast.Node = self.shorthand_inner_ast.get(@intFromPtr(sentinel.tagged_union.value));
    for (tut.variants) |vi| {
        if (std.mem.eql(u8, vi.name, tag)) {
            var adopted = inner_val;
            if (vi.type_name) |vtn| {
                // §3.5/§3.7: if inner is undefined (couldn't resolve at shorthand-eval time)
                // and AST is a bare identifier matching a variant of the variant's declared
                // enum/tagged-union type, resolve it now.
                if (adopted.isUndefined()) {
                    if (inner_ast) |an| if (an.kind == .identifier) {
                        const id_name = an.kind.identifier.name;
                        // Look up the variant's declared type in scope (via global eval state)
                        // The scope isn't available here — use the current top-level scope.
                        // We rely on the caller having a live scope; fall through if not resolvable.
                        if (scope) |sc| if (sc.getType(vtn)) |inner_td| switch (inner_td.kind) {
                            .enum_type => |et| for (et.variants) |ev| if (std.mem.eql(u8, ev, id_name)) {
                                adopted = Value{ .enum_val = .{ .value = id_name, .variants = et.variants, .type_name = vtn } };
                                break;
                            },
                            .tagged_union_type => |itut| for (itut.variants) |iv| if (std.mem.eql(u8, iv.name, id_name)) {
                                const inp = try self.allocator.create(Value);
                                inp.* = .null_val;
                                adopted = Value{ .tagged_union = .{ .value = inp, .tag = id_name, .variants = itut.variants, .type_name = vtn } };
                                break;
                            },
                            else => {},
                        };
                    };
                }
                // §3.7: nested shorthand — if inner value is itself a sentinel and the
                // variant's declared inner type is a named tagged union, recursively
                // resolve the nested sentinel against that type.
                if (isShorthandSentinel(adopted)) {
                    if (scope) |sc| if (sc.getType(vtn)) |inner_td| {
                        if (inner_td.kind == .tagged_union_type) {
                            adopted = try resolveShorthandAgainstType(self, adopted, inner_td, vtn, sc, span);
                        }
                    };
                }
                // §3.7: if inner is a struct_val and the variant's declared type is a
                // named struct, stamp the struct so its fields resolve against the
                // declared type (bare-variant identifiers, per-field `as T`, etc.).
                if (adopted == .struct_val and inner_ast != null and inner_ast.?.kind == .struct_literal) {
                    if (scope) |sc| if (sc.getType(vtn)) |inner_td| {
                        if (inner_td.kind == .struct_type) {
                            adopted = try eval_types.stampNamedTypePub(self, inner_ast.?, inner_td, vtn, adopted, sc, span);
                        }
                    };
                }
                if (!adopted.isNull() and !adopted.isUndefined()) {
                    adopted = h.adoptToType(adopted, vtn);
                    // Stamp struct/tagged type_name onto adopted if it's a compound
                    if (adopted == .struct_val and adopted.struct_val.type_name == null)
                        adopted = Value{ .struct_val = .{ .keys = adopted.struct_val.keys, .values = adopted.struct_val.values, .type_name = vtn } };
                    if (adopted == .function and adopted.function.type_name == null)
                        adopted = Value{ .function = .{ .params = adopted.function.params, .return_type = adopted.function.return_type, .body_bindings = adopted.function.body_bindings, .body_expr = adopted.function.body_expr, .captured_keys = adopted.function.captured_keys, .captured_values = adopted.function.captured_values, .captured_types = adopted.function.captured_types, .type_name = vtn } };
                    // For compound inner types (tuple "(...)", list "[...]"), accept by shape.
                    const is_compound_type = vtn.len > 0 and (vtn[0] == '(' or vtn[0] == '[');
                    const matches_compound = is_compound_type and switch (adopted) {
                        .tuple => vtn[0] == '(',
                        .list => vtn[0] == '[',
                        else => false,
                    };
                    if (!matches_compound and !h.valueMatchesType(adopted, vtn))
                        return self.typeErrSpan("variant shorthand inner value does not match variant's declared type", span);
                }
            }
            const vp = try self.allocator.create(Value);
            vp.* = adopted;
            return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = tut.variants, .type_name = type_name } };
        }
    }
    return self.typeErrSpan("variant shorthand name not found in tagged union", span);
}

// ── Enum/Union/TaggedUnion construction ──────────────────────

pub fn evalFromEnum(self: *Evaluator, value_node: *const Ast.Node, variants: []const []const u8, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    _ = scope;
    _ = exclude;
    if (variants.len < 2) return self.typeErrSpan("enum must have at least 2 variants", value_node.span);
    for (variants, 0..) |v, i| {
        for (variants[0..i]) |prev| if (std.mem.eql(u8, v, prev))
            return self.typeErrSpan("duplicate enum variant", value_node.span);
    }
    const value = switch (value_node.kind) {
        .identifier => |id| id.name,
        else => return .undefined,
    };
    for (variants) |v| if (std.mem.eql(u8, v, value))
        return Value{ .enum_val = .{ .value = value, .variants = variants } };
    return self.typeErrSpan("enum value is not a listed variant", value_node.span);
}

pub fn evalFromUnion(self: *Evaluator, value_node: *const Ast.Node, types: []const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    const value = try self.evalNode(value_node, scope, exclude);
    if (types.len < 2) return self.typeErrSpan("union must have at least 2 member types", value_node.span);

    const type_names = try self.allocator.alloc([]const u8, types.len);
    for (types, 0..) |t, i| type_names[i] = typeExprToString(self.allocator, t) catch "unknown";
    for (type_names, 0..) |tn, i| {
        for (type_names[0..i]) |prev| if (std.mem.eql(u8, tn, prev))
            return self.typeErrSpan("duplicate union member type", value_node.span);
    }

    var adopted = value;
    for (types, type_names) |te, tn| {
        if (te.data == .name) {
            const candidate = h.adoptToType(value, tn);
            if (h.valueMatchesType(candidate, tn)) {
                adopted = candidate;
                break;
            }
        } else {
            const candidate = adoptToTypeExpr(self.allocator, value, te);
            if (valueMatchesTypeExpr(candidate, te)) {
                adopted = candidate;
                break;
            }
        }
    } else return self.typeErrSpan("union value does not match any member type", value_node.span);

    const vp = try self.allocator.create(Value);
    vp.* = adopted;
    return Value{ .union_val = .{ .value = vp, .types = type_names } };
}

pub fn evalNamedVariant(self: *Evaluator, value_node: *const Ast.Node, tag: []const u8, variants: []const Ast.VariantDef, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    // §3.7.1: For `expr as T named Variant` where T is a named tagged union,
    // evaluate `expr` alone (don't stamp it as T — that would reject a tagged
    // union value whose type_name differs). Then wrap with T's variants.
    if (variants.len == 0 and value_node.kind == .type_annotation) {
        const ta = value_node.kind.type_annotation;
        if (ta.type_expr.data == .name) {
            const tn = ta.type_expr.data.name;
            if (scope.getType(tn)) |td| {
                if (td.kind == .tagged_union_type) {
                    const tut = td.kind.tagged_union_type;
                    if (!h.isValidVariantTag(tut.variants, tag))
                        return self.typeErrSpan("unknown variant name in tagged union type reuse", value_node.span);
                    var inner_value = try self.evalNode(ta.expr, scope, exclude);
                    // §3.7: if inner is undefined and `ta.expr` is a bare identifier,
                    // resolve it as a variant of the matched variant's declared type
                    // (another tagged union or enum).
                    if (inner_value.isUndefined() and ta.expr.kind == .identifier) {
                        const id_name = ta.expr.kind.identifier.name;
                        for (tut.variants) |vi| if (std.mem.eql(u8, vi.name, tag)) {
                            if (vi.type_name) |vtn| if (scope.getType(vtn)) |inner_td| switch (inner_td.kind) {
                                .enum_type => |et| for (et.variants) |ev| if (std.mem.eql(u8, ev, id_name)) {
                                    inner_value = Value{ .enum_val = .{ .value = id_name, .variants = et.variants, .type_name = vtn } };
                                    break;
                                },
                                .tagged_union_type => |itut| for (itut.variants) |iv| if (std.mem.eql(u8, iv.name, id_name)) {
                                    const inp = try self.allocator.create(Value);
                                    inp.* = .null_val;
                                    inner_value = Value{ .tagged_union = .{ .value = inp, .tag = id_name, .variants = itut.variants, .type_name = vtn } };
                                    break;
                                },
                                else => {},
                            };
                            break;
                        };
                    }
                    const vp = try self.allocator.create(Value);
                    vp.* = inner_value;
                    return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = tut.variants, .type_name = tn } };
                }
            }
        }
    }

    const value = try self.evalNode(value_node, scope, exclude);

    // Type reuse: empty variants list
    if (variants.len == 0) {
        switch (value) {
            .tagged_union => |tu| {
                if (!h.isValidVariantTag(tu.variants, tag))
                    return self.typeErrSpan("unknown variant name in tagged union type reuse", value_node.span);
                const vp = try self.allocator.create(Value);
                vp.* = tu.value.*;
                return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = tu.variants, .type_name = tu.type_name } };
            },
            else => {
                const tn_opt: ?[]const u8 = if (value_node.kind == .type_annotation)
                    (if (value_node.kind.type_annotation.type_expr.data == .name) value_node.kind.type_annotation.type_expr.data.name else null)
                else
                    null;
                if (tn_opt) |tn| {
                    if (scope.getType(tn)) |td| {
                        if (td.kind == .tagged_union_type) {
                            if (!h.isValidVariantTag(td.kind.tagged_union_type.variants, tag))
                                return self.typeErrSpan("unknown variant name in tagged union type reuse", value_node.span);
                            const vp = try self.allocator.create(Value);
                            vp.* = value;
                            return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = td.kind.tagged_union_type.variants, .type_name = tn } };
                        }
                    }
                }
                return self.typeErrSpan("tagged union type reuse requires known type", value_node.span);
            },
        }
    }

    if (variants.len < 2) return self.typeErrSpan("tagged union must have at least 2 variants", value_node.span);
    const variant_infos = try self.allocator.alloc(val.TaggedUnion.VariantInfo, variants.len);
    for (variants, 0..) |v, i| {
        for (variants[0..i]) |prev| if (std.mem.eql(u8, v.name, prev.name))
            return self.typeErrSpan("duplicate tagged union variant", value_node.span);
        variant_infos[i] = .{ .name = v.name, .type_name = try eval_types.typeExprToString(self, v.type_expr) };
    }
    const vp = try self.allocator.create(Value);
    vp.* = value;
    return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = variant_infos } };
}

// ── Struct override/extension ────────────────────────────────

pub fn evalStructOverride(self: *Evaluator, base_node: *const Ast.Node, overrides_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const base = try self.evalNode(base_node, scope, exclude);
    if (base.isUndefined()) return self.rtErrSpan("cannot override undefined", base_node.span);
    const bs = switch (base) {
        .struct_val => |s| s,
        else => return self.typeErrSpan("'with' requires struct base", span),
    };
    const overrides = try self.evalNode(overrides_node, scope, exclude);
    const os = switch (overrides) {
        .struct_val => |s| s,
        else => return self.typeErrSpan("'with' overrides must be a struct", span),
    };

    // All override keys must exist in base
    for (os.keys) |key| if (bs.get(key) == null)
        return self.typeErrSug("'with' cannot add new field", "use 'plus' to add new fields to a struct", span.line, span.col);

    return applyOverrides(self, bs, os, bs.type_name, span);
}

pub fn evalStructExtension(self: *Evaluator, base_node: *const Ast.Node, ext_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const base = try self.evalNode(base_node, scope, exclude);
    if (base.isUndefined()) return self.rtErrSpan("cannot extend undefined", base_node.span);
    const bs = switch (base) {
        .struct_val => |s| s,
        else => return self.typeErrSpan("'plus' requires struct base", span),
    };
    const extension = try self.evalNode(ext_node, scope, exclude);
    const es = switch (extension) {
        .struct_val => |s| s,
        else => return self.typeErrSpan("'plus' extension must be a struct", span),
    };

    var new_count: usize = 0;
    for (es.keys) |key| if (bs.get(key) == null) {
        new_count += 1;
    };
    if (new_count == 0)
        return self.typeErrSug("'plus' must add at least one new field", "use 'with' to override existing fields without adding new ones", span.line, span.col);

    // Apply overrides to existing fields
    const total = bs.keys.len + new_count;
    const new_keys = try self.allocator.alloc([]const u8, total);
    const new_values = try self.allocator.alloc(Value, total);

    // Copy base with overrides
    for (bs.keys, bs.values, 0..) |key, base_val, i| {
        new_keys[i] = key;
        if (es.get(key)) |ov| {
            if (ov.isUndefined()) return self.rtErrSpan("extension field evaluates to undefined", span);
            new_values[i] = try applyFieldOverride(self, base_val, ov, span);
        } else {
            new_values[i] = base_val;
        }
    }

    // Append new fields
    var wi = bs.keys.len;
    for (es.keys, es.values) |key, ext_val| {
        if (bs.get(key) == null) {
            if (ext_val.isUndefined()) return self.rtErrSpan("extension field evaluates to undefined", span);
            new_keys[wi] = key;
            new_values[wi] = ext_val;
            wi += 1;
        }
    }

    return Value{ .struct_val = .{ .keys = new_keys, .values = new_values } };
}

fn applyOverrides(self: *Evaluator, bs: val.Struct, os: val.Struct, preserve_type: ?[]const u8, span: Ast.Span) EvalError!Value {
    const new_keys = try self.allocator.alloc([]const u8, bs.keys.len);
    const new_values = try self.allocator.alloc(Value, bs.values.len);
    for (bs.keys, bs.values, 0..) |key, base_val, i| {
        new_keys[i] = key;
        if (os.get(key)) |ov| {
            if (ov.isUndefined()) return self.rtErrSpan("override field evaluates to undefined", span);
            new_values[i] = try applyFieldOverride(self, base_val, ov, span);
        } else {
            new_values[i] = base_val;
        }
    }
    return Value{ .struct_val = .{ .keys = new_keys, .values = new_values, .type_name = preserve_type } };
}

fn applyFieldOverride(self: *Evaluator, base_val: Value, ov: Value, span: Ast.Span) EvalError!Value {
    if (base_val.isNull() or ov.isNull()) return ov;
    const adopt_type_name = if (base_val == .integer and base_val.integer.explicit)
        h.intTypeNameAlloc(self.allocator, base_val.integer.type_ann) orelse base_val.typeName()
    else if (base_val == .float_val and base_val.float_val.explicit)
        h.floatTypeName(base_val.float_val.type_ann) orelse base_val.typeName()
    else
        base_val.typeName();
    const adopted = h.adoptToType(ov, adopt_type_name);
    if (!h.sameCategory(base_val, adopted))
        return self.typeErrSpan("override field type incompatible", span);
    if (base_val == .struct_val and adopted == .struct_val)
        try validateStructShape(self, base_val.struct_val, adopted.struct_val, span);
    if (base_val == .integer and adopted == .integer) {
        if (base_val.integer.explicit and adopted.integer.explicit and !std.meta.eql(base_val.integer.type_ann, adopted.integer.type_ann))
            return self.typeErrSpan("override integer type mismatch", span);
        if (base_val.integer.explicit and !h.intFitsType(adopted.integer.value, adopted.integer.type_ann))
            return self.rtErrSpan("override value out of range for field type", span);
    }
    if (base_val == .float_val and adopted == .float_val)
        if (base_val.float_val.explicit and adopted.float_val.explicit and base_val.float_val.type_ann != adopted.float_val.type_ann)
            return self.typeErrSpan("override float type mismatch", span);
    return adopted;
}

fn validateStructShape(self: *Evaluator, base: val.Struct, over: val.Struct, span: Ast.Span) EvalError!void {
    if (base.keys.len != over.keys.len) return self.typeErrSpan("override struct has different shape than base", span);
    for (base.keys, base.values) |bk, bv| {
        const ov = over.get(bk) orelse return self.typeErrSpan("override struct missing field from base", span);
        if (bv == .struct_val and ov == .struct_val) {
            try validateStructShape(self, bv.struct_val, ov.struct_val, span);
        } else if (!bv.isNull() and !ov.isNull() and !h.sameCategory(bv, ov)) {
            return self.typeErrSpan("override struct field type incompatible", span);
        }
    }
    if (base.type_name) |btn| if (over.type_name) |otn| if (!std.mem.eql(u8, btn, otn))
        return self.typeErrSpan("override struct named type mismatch", span);
}

// ── Field extraction (`of`) ─────────────────────────────────

pub fn evalFieldExtraction(self: *Evaluator, source_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const field_name = exclude orelse return self.typeErrSpan("field extraction requires binding context", span);
    const source = try self.evalNode(source_node, scope, exclude);
    if (source.isUndefined()) return .undefined;
    return switch (source) {
        .struct_val => |s| if (s.get(field_name)) |v| v else .undefined,
        .null_val => self.typeErrSpan("cannot extract field from null", span),
        else => self.typeErrSpan("'of' requires a struct value", span),
    };
}

// ── Function expressions ─────────────────────────────────────

fn defaultReferencesParam(node: *const Ast.Node, params: []const Ast.FunctionParam) bool {
    return switch (node.kind) {
        .identifier => |id| blk: {
            for (params) |p| if (std.mem.eql(u8, p.name, id.name)) break :blk true;
            break :blk false;
        },
        .member_access => |ma| defaultReferencesParam(ma.object, params),
        .type_annotation => |ta| defaultReferencesParam(ta.expr, params),
        .conversion => |c| defaultReferencesParam(c.expr, params),
        .binary_op => |bo| defaultReferencesParam(bo.left, params) or defaultReferencesParam(bo.right, params),
        .unary_op => |uo| defaultReferencesParam(uo.operand, params),
        .or_else => |oe| defaultReferencesParam(oe.left, params) or defaultReferencesParam(oe.right, params),
        .if_expr => |ie| defaultReferencesParam(ie.condition, params) or defaultReferencesParam(ie.then_branch, params) or defaultReferencesParam(ie.else_branch, params),
        .list_literal => |ll| blk: {
            for (ll.elements) |e| if (defaultReferencesParam(e, params)) break :blk true;
            break :blk false;
        },
        .tuple_literal => |tl| blk: {
            for (tl.elements) |e| if (defaultReferencesParam(e, params)) break :blk true;
            break :blk false;
        },
        .function_call => |fc| blk: {
            if (defaultReferencesParam(fc.callee, params)) break :blk true;
            for (fc.args) |a| if (defaultReferencesParam(a, params)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub fn evalFunctionExpr(self: *Evaluator, params: []const Ast.FunctionParam, return_type: Ast.TypeExpr, body_bindings: []const Ast.Binding, body_expr: *const Ast.Node, scope: *Scope) EvalError!Value {
    // §4.5: literal 'undefined' cannot be the function body's final expression.
    if (body_expr.kind == .undefined_literal)
        return self.typeErrSpan("literal 'undefined' not allowed as function body final expression", body_expr.span);
    // §3.8: validate default values at function-definition time.
    for (params) |p| if (p.default) |dn| {
        // Defaults must not reference any parameter of the same function.
        if (defaultReferencesParam(dn, params))
            return self.typeErrSpan("default value cannot reference another parameter", dn.span);
        const def_val = try self.evalNode(dn, scope, null);
        if (def_val.isUndefined())
            return self.typeErrSpan("default value is undefined", dn.span);
        if (p.type_expr.data == .name) {
            const tn = p.type_expr.data.name;
            const adopted = h.adoptToType(def_val, tn);
            if (!h.valueMatchesType(adopted, tn))
                return self.typeErrSpan("default value type does not match parameter type", dn.span);
        }
    };

    // Walk scope chain outermost-first, inner shadows outer
    var scope_chain = std.ArrayListUnmanaged(*const Scope){};
    var cur: ?*const Scope = scope;
    while (cur) |s| {
        scope_chain.append(self.allocator, s) catch {};
        cur = s.parent;
    }
    var binding_map = std.StringHashMapUnmanaged(Value){};
    var si: usize = scope_chain.items.len;
    while (si > 0) {
        si -= 1;
        var it = scope_chain.items[si].bindings.iterator();
        while (it.next()) |entry| binding_map.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*.*) catch {};
    }
    const captured_keys = try self.allocator.alloc([]const u8, binding_map.count());
    const captured_values = try self.allocator.alloc(Value, binding_map.count());
    var bind_it = binding_map.iterator();
    var i: usize = 0;
    while (bind_it.next()) |entry| : (i += 1) {
        captured_keys[i] = entry.key_ptr.*;
        captured_values[i] = entry.value_ptr.*;
    }

    var all_types = std.ArrayListUnmanaged(val.TypeDef){};
    cur = scope;
    while (cur) |s| {
        var type_it = s.types.iterator();
        while (type_it.next()) |entry| all_types.append(self.allocator, entry.value_ptr.*.*) catch {};
        cur = s.parent;
    }

    return Value{ .function = .{
        .params = params,
        .return_type = return_type,
        .body_bindings = body_bindings,
        .body_expr = body_expr,
        .captured_keys = captured_keys,
        .captured_values = captured_values,
        .captured_types = all_types.items,
    } };
}

// ── Function calls ───────────────────────────────────────────

pub fn evalFunctionCall(self: *Evaluator, callee_node: *const Ast.Node, arg_nodes: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    // stdlib: std.funcName(args)
    if (callee_node.kind == .member_access) {
        const ma = callee_node.kind.member_access;
        if (ma.object.kind == .identifier and std.mem.eql(u8, ma.object.kind.identifier.name, "std"))
            return @import("stdlib.zig").evalStdlibCall(self, ma.member, arg_nodes, scope, exclude, span);
    }

    // §3.7 v0.10: if the callee is an identifier that isn't a bound function but IS a
    // tagged-union variant name (in some scope-visible tagged union), reinterpret the
    // "call" as a variant_shorthand — the args tuple becomes the inner primary.
    if (callee_node.kind == .identifier) {
        const id_name = callee_node.kind.identifier.name;
        if (scope.get(id_name, null) == null) {
            // Search scope chain for tagged union types whose variants include this name.
            var s: ?*const Scope = scope;
            var match_found = false;
            while (s) |sc| {
                var it = sc.types.iterator();
                while (it.next()) |entry| {
                    const td = entry.value_ptr.*;
                    if (td.kind == .tagged_union_type) {
                        for (td.kind.tagged_union_type.variants) |v| if (std.mem.eql(u8, v.name, id_name)) {
                            match_found = true;
                            break;
                        };
                    }
                    if (match_found) break;
                }
                if (match_found) break;
                s = sc.parent;
            }
            if (match_found) {
                const inner_val: Value = if (arg_nodes.len == 1) blk: {
                    break :blk self.evalNode(arg_nodes[0], scope, exclude) catch blk2: {
                        self.last_error = null;
                        break :blk2 .undefined;
                    };
                } else blk: {
                    const vals = try self.allocator.alloc(Value, arg_nodes.len);
                    for (arg_nodes, 0..) |an, i| {
                        vals[i] = self.evalNode(an, scope, exclude) catch blk2: {
                            self.last_error = null;
                            break :blk2 .undefined;
                        };
                    }
                    break :blk Value{ .tuple = .{ .elements = vals } };
                };
                const vp = try self.allocator.create(Value);
                vp.* = inner_val;
                if (arg_nodes.len == 1) {
                    self.shorthand_inner_ast.put(self.allocator, @intFromPtr(vp), arg_nodes[0]) catch {};
                }
                return Value{ .tagged_union = .{ .value = vp, .tag = id_name, .variants = &.{}, .type_name = null } };
            }
        }
    }

    const callee = try self.evalNode(callee_node, scope, exclude);
    if (callee.isUndefined()) return self.rtErrSpan("calling undefined value", callee_node.span);
    const func = switch (callee) {
        .function => |f| f,
        else => return self.typeErrSpan("calling a non-function value", span),
    };

    const args = try self.allocator.alloc(Value, arg_nodes.len);
    var has_undefined = false;
    for (arg_nodes, 0..) |an, idx| {
        if (self.evalNode(an, scope, exclude)) |v| {
            args[idx] = v;
        } else |_| {
            if (self.last_error) |le| self.collected_errors.append(self.allocator, le) catch {};
            self.last_error = null;
            args[idx] = .undefined;
        }
        // §3.5/§3.7 v0.10: if arg is undefined (e.g. bare enum variant identifier),
        // try to resolve against the corresponding parameter type.
        if (args[idx].isUndefined() and idx < func.params.len) {
            const ptype = func.params[idx].type_expr;
            if (ptype.data == .name) {
                if (scope.getType(ptype.data.name)) |td| {
                    args[idx] = try eval_types.resolveContextualValue(self, .undefined, an, td, ptype.data.name, scope, an.span);
                }
            }
        }
        // Resolve shorthand sentinel against parameter type
        if (isShorthandSentinel(args[idx]) and idx < func.params.len) {
            const ptype = func.params[idx].type_expr;
            if (ptype.data == .name) {
                if (scope.getType(ptype.data.name)) |td| {
                    if (td.kind == .tagged_union_type)
                        args[idx] = try resolveShorthandAgainstType(self, args[idx], td, ptype.data.name, scope, an.span);
                }
            }
        }
        if (args[idx].isUndefined()) has_undefined = true;
    }
    if (has_undefined) {
        const ops = @import("eval_ops.zig");
        var last_undef_node: ?*const Ast.Node = null;
        for (args, arg_nodes) |arg, an| {
            if (arg.isUndefined() and ops.isDirectReference(an)) {
                if (last_undef_node) |prev| {
                    const err_mod = @import("error.zig");
                    self.collected_errors.append(self.allocator, err_mod.UzonError.init(
                        self.allocator, .runtime, "undefined argument in function call", prev.span.line, prev.span.col,
                    )) catch {};
                }
                last_undef_node = an;
            }
        }
        if (last_undef_node) |node|
            return self.rtErrSpan("undefined argument in function call", node.span);
        // All undefined from sub-expression errors — already collected
        self.last_error = null;
        return error.UzonRuntime;
    }

    // Recursion detection
    for (self.call_stack.items) |active| if (active == func.body_expr) return self.typeErrSpan("recursive function call detected", span);
    self.call_stack.append(self.allocator, func.body_expr) catch return error.OutOfMemory;
    defer _ = self.call_stack.pop();

    var required: usize = 0;
    for (func.params) |p| if (p.default == null) {
        required += 1;
    };
    if (args.len < required or args.len > func.params.len)
        return self.typeErrSpan("wrong number of arguments", span);

    var func_scope = Scope.init(self.allocator);
    for (func.captured_keys, func.captured_values) |key, v| try func_scope.define(key, v);
    for (func.captured_types) |td| try func_scope.defineType(td.name, td);

    for (func.params, 0..) |param, idx| {
        if (idx < args.len) {
            var arg = args[idx];
            const arg_span = arg_nodes[idx].span;
            if (param.type_expr.data == .tuple and arg == .tuple)
                if (arg.tuple.elements.len != param.type_expr.data.tuple.len)
                    return self.typeErrSpan("tuple arity mismatch in function argument", arg_span);
            if (param.type_expr.data == .name) {
                const tn = param.type_expr.data.name;
                if (!arg.isNull() and !arg.isUndefined()) {
                    arg = h.adoptToType(arg, tn);
                    if (!h.valueMatchesType(arg, tn))
                        return self.typeErrSpan("argument type mismatch", arg_span);
                }
            }
            try func_scope.define(param.name, arg);
        } else if (param.default) |default_node| {
            try func_scope.define(param.name, try self.evalNode(default_node, &func_scope, null));
        }
    }

    // §3.5 R4: bare enum/tagged variant name as the body's final expression is
    // resolved against the declared return type BEFORE evaluation (to avoid the
    // lexical-lookup failure path setting an error).
    if (func.body_expr.kind == .identifier and func.return_type.data == .name) {
        const rtn_name = func.return_type.data.name;
        if (func_scope.getType(rtn_name)) |td| {
            const id_name = func.body_expr.kind.identifier.name;
            if (func_scope.get(id_name, null) == null) {
                if (eval_types.variantLookup(td, rtn_name, id_name, self.allocator)) |v| {
                    try self.evalBindings(func.body_bindings, &func_scope, null);
                    return v;
                }
            }
        }
    }

    try self.evalBindings(func.body_bindings, &func_scope, null);
    var result = try self.evalNode(func.body_expr, &func_scope, null);

    // §3.7 v0.10: resolve shorthand sentinel against declared return type.
    if (func.return_type.data == .name) {
        const rtn_name = func.return_type.data.name;
        if (func_scope.getType(rtn_name)) |td| {
            if (isShorthandSentinel(result) and td.kind == .tagged_union_type) {
                result = try resolveShorthandAgainstType(self, result, td, rtn_name, &func_scope, func.body_expr.span);
            }
        }
    }

    if (func.return_type.data == .name) {
        const rtn = func.return_type.data.name;
        if (!result.isNull() and !result.isUndefined()) {
            result = h.adoptToType(result, rtn);
            if (!h.valueMatchesType(result, rtn)) {
                // §3.9: structural conformance for function types
                if (result == .function) {
                    if (func_scope.getType(rtn)) |td| {
                        if (td.kind == .function_type and functionMatchesType(result.function, td.kind.function_type)) {
                            result = Value{ .function = .{
                                .params = result.function.params,
                                .return_type = result.function.return_type,
                                .body_bindings = result.function.body_bindings,
                                .body_expr = result.function.body_expr,
                                .captured_keys = result.function.captured_keys,
                                .captured_values = result.function.captured_values,
                                .captured_types = result.function.captured_types,
                                .type_name = rtn,
                            } };
                            return result;
                        }
                    }
                }
                const body_span = func.body_expr.span;
                return self.typeErrSpan("function return type mismatch", body_span);
            }
        }
    }
    return result;
}

fn functionMatchesType(f: val.Function, ft: anytype) bool {
    if (f.params.len != ft.param_types.len) return false;
    for (f.params, ft.param_types) |p, expected| {
        const actual = switch (p.type_expr.data) {
            .name => |n| n,
            else => return false,
        };
        if (!std.mem.eql(u8, actual, expected)) return false;
    }
    const actual_ret = switch (f.return_type.data) {
        .name => |n| n,
        else => return false,
    };
    return std.mem.eql(u8, actual_ret, ft.return_type);
}

// ── File import ──────────────────────────────────────────────

pub fn evalStructImport(self: *Evaluator, path: []const u8, path_span: Ast.Span, span: Ast.Span) EvalError!Value {
    const base = self.base_dir orelse return self.rtErrSpan("file imports require a base directory", span);

    const last_component = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    const has_ext = std.mem.indexOfScalar(u8, last_component, '.') != null;
    const raw_path = if (has_ext)
        (std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, path }) catch return error.OutOfMemory)
    else
        (std.fmt.allocPrint(self.allocator, "{s}/{s}.uzon", .{ base, path }) catch return error.OutOfMemory);

    // Normalize path to detect circular imports regardless of relative path representation
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const import_file = self.allocator.dupe(u8, std.fs.cwd().realpath(raw_path, &real_buf) catch raw_path) catch return error.OutOfMemory;

    if (self.import_cache.get(import_file)) |cached| {
        if (self.import_type_cache.get(import_file)) |types| self.last_import_types = types;
        return cached;
    }
    for (self.import_stack.items) |active| if (std.mem.eql(u8, active, import_file))
        return self.circErr("circular file import detected", path_span.line, path_span.col);

    const source = std.fs.cwd().readFileAlloc(self.allocator, import_file, 4 * 1024 * 1024) catch
        return self.rtErrSpan("cannot read import file", path_span);

    self.import_stack.append(self.allocator, import_file) catch return error.OutOfMemory;

    const import_dir = if (std.mem.lastIndexOfScalar(u8, import_file, '/')) |sep| import_file[0..sep] else ".";

    const Lexer = @import("Lexer.zig");
    var lexer = Lexer.init(self.allocator, source);
    const tokens = lexer.tokenize() catch return self.rtErrSpan("syntax error in imported file", span);

    const Parser = @import("Parser.zig");
    var parser = Parser.init(self.allocator, tokens, lexer.comment_lines.items);
    const doc = parser.parse() catch {
        _ = self.import_stack.pop();
        if (parser.last_error) |pe| {
            var ie = pe;
            if (ie.location.filename == null) ie.location.filename = import_file;
            ie.import_trace.append(ie.allocator, .{ .line = span.line, .col = span.col, .filename = self.currentFilename() }) catch {};
            self.last_error = ie;
            return error.UzonType;
        }
        return self.rtErrSpan("parse error in imported file", span);
    };

    const saved_base = self.base_dir;
    const saved_error = self.last_error;
    const saved_collected = self.collected_errors;
    self.base_dir = import_dir;
    self.last_error = null;
    self.collected_errors = .{};

    var import_type_scope = Scope.init(self.allocator);
    const result = self.evalDocumentInScope(doc, &import_type_scope);

    self.base_dir = saved_base;
    _ = self.import_stack.pop();

    const val_result = result catch {
        // Don't propagate the imported file's internal errors (circular deps,
        // recursive functions) — they belong to that file, not the importer.
        // Only propagate a single import-level error.
        self.collected_errors = saved_collected;

        if (self.last_error) |*eval_err| {
            if (eval_err.location.filename == null) eval_err.location.filename = import_file;
            eval_err.import_trace.append(eval_err.allocator, .{ .line = span.line, .col = span.col, .filename = self.currentFilename() }) catch {};
            return error.UzonCircular;
        }
        self.last_error = saved_error;
        return self.rtErrSpan("evaluation error in imported file", span);
    };

    self.last_import_types = import_type_scope.types;
    self.import_cache.put(self.allocator, import_file, val_result) catch {};
    self.import_type_cache.put(self.allocator, import_file, import_type_scope.types) catch {};
    if (self.last_error == null) self.last_error = saved_error;
    self.collected_errors = saved_collected;
    return val_result;
}
