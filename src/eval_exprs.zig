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
    const cond = try self.evalNode(cond_node, scope, exclude);
    switch (cond) {
        .bool_val => |bv| {
            if (bv) {
                const result = try self.evalNode(then_node, scope, exclude);
                const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
                    error.UzonRuntime => return result,
                    else => return e,
                };
                if (!h.branchTypesCompatible(result, else_val))
                    return self.typeErr("if/else branches have incompatible types", span.line, span.col);
                return result;
            } else {
                const then_val = self.evalNode(then_node, scope, exclude) catch |e| switch (e) {
                    error.UzonRuntime => return try self.evalNode(else_node, scope, exclude),
                    else => return e,
                };
                const result = try self.evalNode(else_node, scope, exclude);
                if (!h.branchTypesCompatible(then_val, result))
                    return self.typeErr("if/else branches have incompatible types", span.line, span.col);
                return result;
            }
        },
        else => return self.typeErrSug("if condition must be bool", "compare explicitly, e.g. 'if x > 0 then ...'", span.line, span.col),
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
    if (scrutinee.isUndefined()) return self.rtErr("case scrutinee is undefined", span.line, span.col);
    if (scrutinee == .union_val) return self.typeErr("case value cannot be used with untagged unions; use case type", span.line, span.col);

    const match_scrutinee = scrutinee.unwrapTransparent();

    var matched_idx: ?usize = null;
    for (when_clauses, 0..) |wc, i| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErr("undefined cannot be used as a when value", span.line, span.col);
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
                return self.typeErr("case when value must be same type as scrutinee", span.line, span.col);
        if (h.runtimeEqual(match_scrutinee, when_val)) {
            matched_idx = i;
            break;
        }
    }

    return evalCaseBranches(self, when_clauses, else_node, matched_idx, scope, exclude, span);
}

fn evalCaseType(self: *Evaluator, scrutinee_node: *const Ast.Node, when_clauses: []const Ast.WhenClause, else_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const scrutinee = try self.evalNode(scrutinee_node, scope, exclude);
    if (scrutinee.isUndefined()) return self.rtErr("case scrutinee is undefined", span.line, span.col);

    const check_val = scrutinee.unwrapTransparent();
    const scrutinee_name: ?[]const u8 = if (scrutinee_node.kind == .identifier) scrutinee_node.kind.identifier.name else null;

    // Validate all when-clause types
    for (when_clauses) |wc| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErr("undefined cannot be used as a when value", span.line, span.col);
        const tn = whenClauseTypeString(self.allocator, wc) orelse continue;
        if (scrutinee == .union_val) {
            var valid = false;
            for (scrutinee.union_val.types) |t| if (std.mem.eql(u8, t, tn)) {
                valid = true;
                break;
            };
            if (!valid) return self.typeErr("when type is not a member of the union", span.line, span.col);
        } else if (scrutinee == .tagged_union) {
            var valid = false;
            for (scrutinee.tagged_union.variants) |v| if (v.type_name) |vtn| if (std.mem.eql(u8, vtn, tn)) {
                valid = true;
                break;
            };
            if (!valid) return self.typeErr("when type is not a variant type of the tagged union", span.line, span.col);
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
                    return self.typeErr("case type branches have incompatible types", span.line, span.col);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErr("case type branches have incompatible types", span.line, span.col);
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
                return self.typeErr("case type branches have incompatible types", span.line, span.col);
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
            break :blk Value{ .list = .{ .elements = new_elements, .element_type = l.element_type } };
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
    if (scrutinee.isUndefined()) return self.rtErr("case scrutinee is undefined", span.line, span.col);
    const tu = switch (scrutinee) {
        .tagged_union => |t| t,
        else => return self.typeErr("'case named' requires tagged union", span.line, span.col),
    };

    const scrutinee_name: ?[]const u8 = if (scrutinee_node.kind == .identifier) scrutinee_node.kind.identifier.name else null;

    var matched_idx: ?usize = null;
    for (when_clauses, 0..) |wc, i| {
        if (wc.value.kind == .undefined_literal)
            return self.typeErr("undefined cannot be used as a when value", span.line, span.col);
        const vn = if (wc.value.kind == .identifier) wc.value.kind.identifier.name else continue;
        if (!h.isValidVariantTag(tu.variants, vn))
            return self.typeErr("unknown variant name in 'case named'", span.line, span.col);
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
                    return self.typeErr("case named branches have incompatible types", span.line, span.col);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErr("case named branches have incompatible types", span.line, span.col);
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
                return self.typeErr("case named branches have incompatible types", span.line, span.col);
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
                    return self.typeErr("case branches have incompatible types", span.line, span.col);
            }
        }
        const else_val = self.evalNode(else_node, scope, exclude) catch |e| switch (e) {
            error.UzonRuntime => return result,
            else => return e,
        };
        if (!h.branchTypesCompatible(result, else_val))
            return self.typeErr("case branches have incompatible types", span.line, span.col);
        return result;
    } else {
        const result = try self.evalNode(else_node, scope, exclude);
        for (when_clauses) |wc| {
            const other = self.evalNode(wc.result, scope, exclude) catch |e| switch (e) {
                error.UzonRuntime => continue,
                else => return e,
            };
            if (!h.branchTypesCompatible(result, other))
                return self.typeErr("case branches have incompatible types", span.line, span.col);
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

// ── Enum/Union/TaggedUnion construction ──────────────────────

pub fn evalFromEnum(self: *Evaluator, value_node: *const Ast.Node, variants: []const []const u8, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    _ = scope;
    _ = exclude;
    if (variants.len < 2) return self.typeErr("enum must have at least 2 variants", value_node.span.line, value_node.span.col);
    for (variants, 0..) |v, i| {
        for (variants[0..i]) |prev| if (std.mem.eql(u8, v, prev))
            return self.typeErr("duplicate enum variant", value_node.span.line, value_node.span.col);
    }
    const value = switch (value_node.kind) {
        .identifier => |id| id.name,
        else => return .undefined,
    };
    for (variants) |v| if (std.mem.eql(u8, v, value))
        return Value{ .enum_val = .{ .value = value, .variants = variants } };
    return self.typeErr("enum value is not a listed variant", value_node.span.line, value_node.span.col);
}

pub fn evalFromUnion(self: *Evaluator, value_node: *const Ast.Node, types: []const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    const value = try self.evalNode(value_node, scope, exclude);
    if (types.len < 2) return self.typeErr("union must have at least 2 member types", value_node.span.line, value_node.span.col);

    const type_names = try self.allocator.alloc([]const u8, types.len);
    for (types, 0..) |t, i| type_names[i] = typeExprToString(self.allocator, t) catch "unknown";
    for (type_names, 0..) |tn, i| {
        for (type_names[0..i]) |prev| if (std.mem.eql(u8, tn, prev))
            return self.typeErr("duplicate union member type", value_node.span.line, value_node.span.col);
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
    } else return self.typeErr("union value does not match any member type", value_node.span.line, value_node.span.col);

    const vp = try self.allocator.create(Value);
    vp.* = adopted;
    return Value{ .union_val = .{ .value = vp, .types = type_names } };
}

pub fn evalNamedVariant(self: *Evaluator, value_node: *const Ast.Node, tag: []const u8, variants: []const Ast.VariantDef, scope: *Scope, exclude: ?[]const u8) EvalError!Value {
    const value = try self.evalNode(value_node, scope, exclude);

    // Type reuse: empty variants list
    if (variants.len == 0) {
        switch (value) {
            .tagged_union => |tu| {
                if (!h.isValidVariantTag(tu.variants, tag))
                    return self.typeErr("unknown variant name in tagged union type reuse", value_node.span.line, value_node.span.col);
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
                                return self.typeErr("unknown variant name in tagged union type reuse", value_node.span.line, value_node.span.col);
                            const vp = try self.allocator.create(Value);
                            vp.* = value;
                            return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = td.kind.tagged_union_type.variants, .type_name = tn } };
                        }
                    }
                }
                return self.typeErr("tagged union type reuse requires known type", value_node.span.line, value_node.span.col);
            },
        }
    }

    if (variants.len < 2) return self.typeErr("tagged union must have at least 2 variants", value_node.span.line, value_node.span.col);
    const variant_infos = try self.allocator.alloc(val.TaggedUnion.VariantInfo, variants.len);
    for (variants, 0..) |v, i| {
        for (variants[0..i]) |prev| if (std.mem.eql(u8, v.name, prev.name))
            return self.typeErr("duplicate tagged union variant", value_node.span.line, value_node.span.col);
        variant_infos[i] = .{ .name = v.name, .type_name = try eval_types.typeExprToString(self, v.type_expr) };
    }
    const vp = try self.allocator.create(Value);
    vp.* = value;
    return Value{ .tagged_union = .{ .value = vp, .tag = tag, .variants = variant_infos } };
}

// ── Struct override/extension ────────────────────────────────

pub fn evalStructOverride(self: *Evaluator, base_node: *const Ast.Node, overrides_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const base = try self.evalNode(base_node, scope, exclude);
    if (base.isUndefined()) return self.rtErr("cannot override undefined", span.line, span.col);
    const bs = switch (base) {
        .struct_val => |s| s,
        else => return self.typeErr("'with' requires struct base", span.line, span.col),
    };
    const overrides = try self.evalNode(overrides_node, scope, exclude);
    const os = switch (overrides) {
        .struct_val => |s| s,
        else => return self.typeErr("'with' overrides must be a struct", span.line, span.col),
    };

    // All override keys must exist in base
    for (os.keys) |key| if (bs.get(key) == null)
        return self.typeErrSug("'with' cannot add new field", "use 'plus' to add new fields to a struct", span.line, span.col);

    return applyOverrides(self, bs, os, bs.type_name, span);
}

pub fn evalStructExtension(self: *Evaluator, base_node: *const Ast.Node, ext_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const base = try self.evalNode(base_node, scope, exclude);
    if (base.isUndefined()) return self.rtErr("cannot extend undefined", span.line, span.col);
    const bs = switch (base) {
        .struct_val => |s| s,
        else => return self.typeErr("'plus' requires struct base", span.line, span.col),
    };
    const extension = try self.evalNode(ext_node, scope, exclude);
    const es = switch (extension) {
        .struct_val => |s| s,
        else => return self.typeErr("'plus' extension must be a struct", span.line, span.col),
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
            if (ov.isUndefined()) return self.rtErr("extension field evaluates to undefined", span.line, span.col);
            new_values[i] = try applyFieldOverride(self, base_val, ov, span);
        } else {
            new_values[i] = base_val;
        }
    }

    // Append new fields
    var wi = bs.keys.len;
    for (es.keys, es.values) |key, ext_val| {
        if (bs.get(key) == null) {
            if (ext_val.isUndefined()) return self.rtErr("extension field evaluates to undefined", span.line, span.col);
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
            if (ov.isUndefined()) return self.rtErr("override field evaluates to undefined", span.line, span.col);
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
        return self.typeErr("override field type incompatible", span.line, span.col);
    if (base_val == .struct_val and adopted == .struct_val)
        try validateStructShape(self, base_val.struct_val, adopted.struct_val, span);
    if (base_val == .integer and adopted == .integer) {
        if (base_val.integer.explicit and adopted.integer.explicit and !std.meta.eql(base_val.integer.type_ann, adopted.integer.type_ann))
            return self.typeErr("override integer type mismatch", span.line, span.col);
        if (base_val.integer.explicit and !h.intFitsType(adopted.integer.value, adopted.integer.type_ann))
            return self.rtErr("override value out of range for field type", span.line, span.col);
    }
    if (base_val == .float_val and adopted == .float_val)
        if (base_val.float_val.explicit and adopted.float_val.explicit and base_val.float_val.type_ann != adopted.float_val.type_ann)
            return self.typeErr("override float type mismatch", span.line, span.col);
    return adopted;
}

fn validateStructShape(self: *Evaluator, base: val.Struct, over: val.Struct, span: Ast.Span) EvalError!void {
    if (base.keys.len != over.keys.len) return self.typeErr("override struct has different shape than base", span.line, span.col);
    for (base.keys, base.values) |bk, bv| {
        const ov = over.get(bk) orelse return self.typeErr("override struct missing field from base", span.line, span.col);
        if (bv == .struct_val and ov == .struct_val) {
            try validateStructShape(self, bv.struct_val, ov.struct_val, span);
        } else if (!bv.isNull() and !ov.isNull() and !h.sameCategory(bv, ov)) {
            return self.typeErr("override struct field type incompatible", span.line, span.col);
        }
    }
    if (base.type_name) |btn| if (over.type_name) |otn| if (!std.mem.eql(u8, btn, otn))
        return self.typeErr("override struct named type mismatch", span.line, span.col);
}

// ── Field extraction (`of`) ─────────────────────────────────

pub fn evalFieldExtraction(self: *Evaluator, source_node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const field_name = exclude orelse return self.typeErr("field extraction requires binding context", span.line, span.col);
    const source = try self.evalNode(source_node, scope, exclude);
    if (source.isUndefined()) return .undefined;
    return switch (source) {
        .struct_val => |s| if (s.get(field_name)) |v| v else .undefined,
        .null_val => self.typeErr("cannot extract field from null", span.line, span.col),
        else => self.typeErr("'of' requires a struct value", span.line, span.col),
    };
}

// ── Function expressions ─────────────────────────────────────

pub fn evalFunctionExpr(self: *Evaluator, params: []const Ast.FunctionParam, return_type: Ast.TypeExpr, body_bindings: []const Ast.Binding, body_expr: *const Ast.Node, scope: *Scope) EvalError!Value {
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

    const callee = try self.evalNode(callee_node, scope, exclude);
    if (callee.isUndefined()) return self.rtErr("calling undefined value", span.line, span.col);
    const func = switch (callee) {
        .function => |f| f,
        else => return self.typeErr("calling a non-function value", span.line, span.col),
    };

    const args = try self.allocator.alloc(Value, arg_nodes.len);
    for (arg_nodes, 0..) |an, idx| args[idx] = try self.evalNode(an, scope, exclude);
    for (args) |arg| if (arg.isUndefined()) return self.rtErr("undefined argument in function call", span.line, span.col);

    // Recursion detection
    for (self.call_stack.items) |active| if (active == func.body_expr) return self.typeErr("recursive function call detected", span.line, span.col);
    self.call_stack.append(self.allocator, func.body_expr) catch return error.OutOfMemory;
    defer _ = self.call_stack.pop();

    var required: usize = 0;
    for (func.params) |p| if (p.default == null) {
        required += 1;
    };
    if (args.len < required or args.len > func.params.len)
        return self.typeErr("wrong number of arguments", span.line, span.col);

    var func_scope = Scope.init(self.allocator);
    for (func.captured_keys, func.captured_values) |key, v| try func_scope.define(key, v);
    for (func.captured_types) |td| try func_scope.defineType(td.name, td);

    for (func.params, 0..) |param, idx| {
        if (idx < args.len) {
            var arg = args[idx];
            if (param.type_expr.data == .tuple and arg == .tuple)
                if (arg.tuple.elements.len != param.type_expr.data.tuple.len)
                    return self.typeErr("tuple arity mismatch in function argument", span.line, span.col);
            if (param.type_expr.data == .name) {
                const tn = param.type_expr.data.name;
                if (!arg.isNull() and !arg.isUndefined()) {
                    arg = h.adoptToType(arg, tn);
                    if (!h.valueMatchesType(arg, tn))
                        return self.typeErr("argument type mismatch", span.line, span.col);
                }
            }
            try func_scope.define(param.name, arg);
        } else if (param.default) |default_node| {
            try func_scope.define(param.name, try self.evalNode(default_node, &func_scope, null));
        }
    }

    try self.evalBindings(func.body_bindings, &func_scope, null);
    var result = try self.evalNode(func.body_expr, &func_scope, null);

    if (func.return_type.data == .name) {
        const rtn = func.return_type.data.name;
        if (!result.isNull() and !result.isUndefined()) {
            result = h.adoptToType(result, rtn);
            if (!h.valueMatchesType(result, rtn))
                return self.typeErr("function return type mismatch", span.line, span.col);
        }
    }
    return result;
}

// ── File import ──────────────────────────────────────────────

pub fn evalStructImport(self: *Evaluator, path: []const u8, span: Ast.Span) EvalError!Value {
    const base = self.base_dir orelse return self.rtErr("file imports require a base directory", span.line, span.col);

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
        return self.circErr("circular file import detected", span.line, span.col);

    const source = std.fs.cwd().readFileAlloc(self.allocator, import_file, 4 * 1024 * 1024) catch
        return self.rtErr("cannot read import file", span.line, span.col);

    self.import_stack.append(self.allocator, import_file) catch return error.OutOfMemory;

    const import_dir = if (std.mem.lastIndexOfScalar(u8, import_file, '/')) |sep| import_file[0..sep] else ".";

    const Lexer = @import("Lexer.zig");
    var lexer = Lexer.init(self.allocator, source);
    const tokens = lexer.tokenize() catch return self.rtErr("syntax error in imported file", span.line, span.col);

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
        return self.rtErr("parse error in imported file", span.line, span.col);
    };

    const saved_base = self.base_dir;
    const saved_error = self.last_error;
    self.base_dir = import_dir;
    self.last_error = null;

    var import_type_scope = Scope.init(self.allocator);
    const result = self.evalDocumentInScope(doc, &import_type_scope);

    self.base_dir = saved_base;
    _ = self.import_stack.pop();

    const val_result = result catch {
        if (self.last_error) |*eval_err| {
            if (eval_err.location.filename == null) eval_err.location.filename = import_file;
            eval_err.import_trace.append(eval_err.allocator, .{ .line = span.line, .col = span.col, .filename = self.currentFilename() }) catch {};
            return error.UzonType;
        }
        self.last_error = saved_error;
        return self.rtErr("evaluation error in imported file", span.line, span.col);
    };

    self.last_import_types = import_type_scope.types;
    self.import_cache.put(self.allocator, import_file, val_result) catch {};
    self.import_type_cache.put(self.allocator, import_file, import_type_scope.types) catch {};
    if (self.last_error == null) self.last_error = saved_error;
    return val_result;
}
