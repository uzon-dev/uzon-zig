const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");
const h = @import("eval_helpers.zig");

const EvalError = Evaluator.EvalError;

pub fn isBuiltinTypeName(name: []const u8) bool {
    const builtins = [_][]const u8{ "bool", "string", "null", "integer", "float", "list", "tuple", "struct", "function" };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    if (h.parseIntegerTypeName(name) != null) return true;
    if (h.parseFloatTypeName(name) != null) return true;
    return false;
}

/// §3.6 default table: resolve a parser-synthesized `type_default` placeholder
/// to the default value of its type expression.
pub fn evalTypeDefault(self: *Evaluator, type_expr: *const Ast.TypeExpr, scope: *Scope, span: Ast.Span) EvalError!Value {
    return switch (type_expr.data) {
        .name => |n| computeNamedDefault(self, n, scope, span),
        .path => |segments| {
            const resolved = resolvePathTypeName(self, segments, type_expr.*, scope) orelse
                return self.typeErrSpan("unknown type in default computation", span);
            return computeNamedDefault(self, resolved, scope, span);
        },
        .null_type => .null_val,
        .list => |inner| Value{ .list = .{ .elements = &.{}, .element_type = try typeExprToString(self, inner.*) } },
        .tuple => |elems| blk: {
            const out = try self.allocator.alloc(Value, elems.len);
            for (elems, 0..) |*et, i| out[i] = try evalTypeDefault(self, et, scope, span);
            break :blk Value{ .tuple = .{ .elements = out } };
        },
    };
}

/// §3.6 default table: compute the default value of a named type. Used when the
/// parser emits a `type_default` placeholder that must resolve to T's default.
pub fn computeNamedDefault(self: *Evaluator, type_name: []const u8, scope: *Scope, span: Ast.Span) EvalError!Value {
    if (h.parseIntegerTypeName(type_name)) |t| return Value{ .integer = .{ .value = 0, .type_ann = t, .explicit = true } };
    if (h.parseFloatTypeName(type_name)) |t| return Value{ .float_val = .{ .value = 0.0, .type_ann = t, .explicit = true } };
    if (std.mem.eql(u8, type_name, "string")) return Value.str("");
    if (std.mem.eql(u8, type_name, "bool")) return Value.boolean(false);
    if (std.mem.eql(u8, type_name, "null")) return .null_val;
    if (scope.getType(type_name)) |td| {
        switch (td.kind) {
            .enum_type => |et| {
                if (et.variants.len == 0) return self.typeErrSpan("enum has no variants", span);
                return Value{ .enum_val = .{ .value = et.variants[0], .variants = et.variants, .type_name = type_name } };
            },
            .union_type => |ut| {
                if (ut.types.len == 0) return self.typeErrSpan("union has no member types", span);
                var has_null = false;
                for (ut.types) |m| if (std.mem.eql(u8, m, "null")) {
                    has_null = true;
                    break;
                };
                const inner: Value = if (has_null) .null_val else try computeNamedDefault(self, ut.types[0], scope, span);
                const vp = try self.allocator.create(Value);
                vp.* = inner;
                return Value{ .union_val = .{ .value = vp, .types = ut.types, .type_name = type_name } };
            },
            .tagged_union_type => |tut| {
                if (tut.variants.len == 0) return self.typeErrSpan("tagged union has no variants", span);
                const first = tut.variants[0];
                const inner_val: Value = if (first.type_name) |tn| try computeNamedDefault(self, tn, scope, span) else .null_val;
                const vp = try self.allocator.create(Value);
                vp.* = inner_val;
                return Value{ .tagged_union = .{ .value = vp, .tag = first.name, .variants = tut.variants, .type_name = type_name } };
            },
            .struct_type => |st| {
                const keys = try self.allocator.alloc([]const u8, st.fields.len);
                const values = try self.allocator.alloc(Value, st.fields.len);
                for (st.fields, 0..) |f, i| {
                    keys[i] = f.name;
                    values[i] = f.default;
                }
                return Value{ .struct_val = .{ .keys = keys, .values = values, .type_name = type_name } };
            },
            .list_type => |lt| return Value{ .list = .{ .elements = &.{}, .element_type = lt.element_type, .type_name = type_name } },
            .function_type => return self.typeErrSpan("cannot default-construct function type", span),
            .refinement_primitive => |rp| return computeNamedDefault(self, rp.base, scope, span),
        }
    }
    return self.typeErrSpan("unknown type in default computation", span);
}

// ── Type annotation (`as`) ───────────────────────────────────

pub fn evalTypeAnnotation(self: *Evaluator, expr_node: *const Ast.Node, type_expr: *const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    // §3.2 v0.10: list literal `[...] as [NamedStruct]` — evaluate elements raw (no homogeneity)
    // so struct defaults per type-def can fill in missing fields before the final shape check.
    if (type_expr.data == .list and expr_node.kind == .list_literal) {
        const inner_type = type_expr.data.list;
        const inner_name: ?[]const u8 = switch (inner_type.data) {
            .name => |n| n,
            .path => |segs| resolvePathTypeName(self, segs, inner_type.*, scope),
            else => null,
        };
        if (inner_name) |n| if (scope.getType(n) != null) {
            const elements = expr_node.kind.list_literal.elements;
            const raw = try self.allocator.alloc(Value, elements.len);
            for (elements, 0..) |e, i| raw[i] = try self.evalNode(e, scope, exclude);
            const list_val = Value{ .list = .{ .elements = raw } };
            return annotateList(self, expr_node, inner_type, list_val, scope, span);
        };
    }
    const value = try self.evalNode(expr_node, scope, exclude);

    const type_name = switch (type_expr.data) {
        .name => |n| n,
        .list => |inner_type| return annotateList(self, expr_node, inner_type, value, scope, span),
        .path => |segments| return annotatePath(self, expr_node, segments, type_expr, value, scope, exclude, span),
        .tuple => {
            if (value.isUndefined()) return .undefined;
            // §6.1: null does not conform to a tuple type.
            if (value == .null_val) return self.typeErrSpan("cannot annotate null as tuple type", span);
            return value;
        },
        else => {
            if (value.isUndefined()) return .undefined;
            return value;
        },
    };

    // Enum variant resolution for undefined identifiers
    if (value.isUndefined()) {
        if (scope.getType(type_name)) |td| {
            switch (td.kind) {
                .enum_type => |et| {
                    if (expr_node.kind == .identifier) {
                        const name = expr_node.kind.identifier.name;
                        for (et.variants) |v| {
                            if (std.mem.eql(u8, v, name))
                                return Value{ .enum_val = .{ .value = name, .variants = et.variants, .type_name = type_name } };
                        }
                        return self.typeErr("not a variant of the enum type", span.line, span.col);
                    }
                },
                .tagged_union_type => |tut| {
                    if (expr_node.kind == .identifier) {
                        const name = expr_node.kind.identifier.name;
                        for (tut.variants) |v| {
                            if (std.mem.eql(u8, v.name, name)) {
                                const inner = try self.allocator.create(Value);
                                inner.* = .null_val;
                                return Value{ .tagged_union = .{ .value = inner, .tag = name, .variants = tut.variants, .type_name = type_name } };
                            }
                        }
                        return self.typeErr("not a variant of the tagged union type", span.line, span.col);
                    }
                },
                .union_type => |ut| {
                    // §3.5 L866: bare identifier against union whose members include
                    // enums/tagged unions — 0 matches falls through to undefined, exactly 1
                    // resolves to that member's variant wrapped as a union_val, >1 is a
                    // type error (ambiguous).
                    if (expr_node.kind == .identifier) {
                        const name = expr_node.kind.identifier.name;
                        var matched_inner: ?Value = null;
                        var match_count: usize = 0;
                        for (ut.types) |member_name| {
                            const mtd = scope.getType(member_name) orelse continue;
                            switch (mtd.kind) {
                                .enum_type => |et| {
                                    for (et.variants) |v| if (std.mem.eql(u8, v, name)) {
                                        match_count += 1;
                                        matched_inner = Value{ .enum_val = .{ .value = name, .variants = et.variants, .type_name = member_name } };
                                        break;
                                    };
                                },
                                .tagged_union_type => |tut| {
                                    for (tut.variants) |v| if (std.mem.eql(u8, v.name, name)) {
                                        match_count += 1;
                                        const inner_tu = try self.allocator.create(Value);
                                        inner_tu.* = .null_val;
                                        matched_inner = Value{ .tagged_union = .{ .value = inner_tu, .tag = name, .variants = tut.variants, .type_name = member_name } };
                                        break;
                                    };
                                },
                                else => {},
                            }
                        }
                        if (match_count > 1)
                            return self.typeErrSpan("ambiguous bare variant: matches multiple members of union type", span);
                        if (matched_inner) |mi| {
                            const vp = try self.allocator.create(Value);
                            vp.* = mi;
                            return Value{ .union_val = .{ .value = vp, .types = ut.types, .type_name = type_name } };
                        }
                    }
                },
                else => {},
            }
            return .undefined;
        }
        if (!isBuiltinTypeName(type_name))
            return self.typeErr("unknown type name in annotation", span.line, span.col);
        return .undefined;
    }

    // Numeric type annotations
    if (h.parseIntegerTypeName(type_name)) |int_type| {
        return switch (value) {
            .integer => |iv| blk: {
                if (!h.intFitsType(iv.value, int_type))
                    return self.typeErr("integer value out of range for type annotation", span.line, span.col);
                break :blk Value{ .integer = .{ .value = iv.value, .type_ann = int_type, .explicit = true } };
            },
            // §6.1: `null as <primitive>` is a type error in general expressions.
            // The struct-field-declaration exception (§3.2.1 typed-null) is handled
            // in evalStructLiteral — those fields never reach this code path.
            else => self.typeErr("cannot annotate non-integer as integer type", span.line, span.col),
        };
    }
    if (h.parseFloatTypeName(type_name)) |float_type| {
        return switch (value) {
            .float_val => |fv| Value{ .float_val = .{ .value = fv.value, .type_ann = float_type, .explicit = true } },
            .integer => |iv| blk: {
                if (!iv.explicit)
                    break :blk Value{ .float_val = .{ .value = @floatFromInt(iv.value), .type_ann = float_type, .explicit = true } };
                return self.typeErr("cannot annotate explicitly-typed integer as float", span.line, span.col);
            },
            else => self.typeErr("cannot annotate non-numeric as float type", span.line, span.col),
        };
    }

    // Built-in type names
    if (std.mem.eql(u8, type_name, "bool")) {
        if (value != .bool_val) return self.typeErr("value is not bool", span.line, span.col);
        return value;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        if (value != .string) return self.typeErr("value is not string", span.line, span.col);
        return value;
    }
    if (std.mem.eql(u8, type_name, "null")) {
        if (value != .null_val) return self.typeErr("value is not null", span.line, span.col);
        return value;
    }

    // Named type annotation (from `called` registry)
    if (scope.getType(type_name)) |td| {
        // §3.9: refinement type — check base type, then evaluate predicate.
        // When the value is null (universal nullability §3.1), skip the base
        // type check — the predicate's behavior on null decides membership.
        if (td.refinement) |rf| {
            if (value == .null_val) {
                try checkRefinement(self, rf, value, scope, span);
                return value;
            }
            const base_te = Ast.TypeExpr{ .data = .{ .name = rf.base_type_name }, .span = span };
            const adopted = try evalTypeAnnotation(self, expr_node, &base_te, scope, exclude, span);
            try checkRefinement(self, rf, adopted, scope, span);
            return adopted;
        }
        // §6.1: `null as T` is valid only when T admits null. Named enums and
        // named structs never admit null. Untagged unions must include `null` as
        // a member type. (Tagged unions are handled by evalNamedVariant when the
        // value is null and the target variant's inner type is null.)
        if (value == .null_val) {
            switch (td.kind) {
                .enum_type => return self.typeErr("cannot annotate null as named enum type", span.line, span.col),
                .struct_type => return self.typeErr("cannot annotate null as named struct type", span.line, span.col),
                .union_type => |ut| {
                    var has_null = false;
                    for (ut.types) |m| if (std.mem.eql(u8, m, "null")) {
                        has_null = true;
                        break;
                    };
                    if (!has_null) return self.typeErr("cannot annotate null as union type without null member", span.line, span.col);
                },
                .function_type, .list_type => return self.typeErr("cannot annotate null as this type", span.line, span.col),
                .tagged_union_type, .refinement_primitive => {},
            }
        }
        return stampNamedType(self, expr_node, td, type_name, value, scope, span);
    }

    return self.typeErr("unknown type name in annotation", span.line, span.col);
}

/// §3.9 evaluate a refinement predicate with `self` bound to the candidate.
pub fn checkRefinement(self_ev: *Evaluator, rf: val.TypeDef.Refinement, value: Value, scope: *Scope, span: Ast.Span) EvalError!void {
    var inner = Scope.init(self_ev.allocator);
    inner.parent = scope;
    try inner.define("self", value);
    const result = try self_ev.evalNode(rf.predicate, &inner, null);
    const ok = switch (result) {
        .bool_val => |b| b,
        else => return self_ev.typeErrSpan("refinement predicate must evaluate to bool", span),
    };
    if (!ok) return self_ev.typeErrSpan("value does not satisfy refinement predicate", span);
}

fn annotateList(self: *Evaluator, expr_node: *const Ast.Node, inner_type: *const Ast.TypeExpr, value: Value, scope: *Scope, span: Ast.Span) EvalError!Value {
    if (value.isUndefined()) return .undefined;
    // §6.1: null is not a list value — `null as [T]` is a type error.
    if (value == .null_val) return self.typeErrSpan("cannot annotate null as list type", span);
    if (value != .list) return value;

    const et = try typeExprToString(self, inner_type.*);

    const inner_type_name: ?[]const u8 = switch (inner_type.data) {
        .name => |n| n,
        .path => |segments| resolvePathTypeName(self, segments, inner_type.*, scope),
        else => null,
    };

    // §3.5/§3.7 v0.10: context-aware resolution for list elements (enum/tagged/struct)
    var resolved_elements: []const Value = value.list.elements;
    if (inner_type_name) |itn| {
        if (scope.getType(itn)) |td| {
            if (expr_node.kind == .list_literal) {
                const ast_elems = expr_node.kind.list_literal.elements;
                const new_elems = try self.allocator.alloc(Value, ast_elems.len);
                for (ast_elems, value.list.elements, 0..) |ast_e, val_e, j| {
                    var v = try resolveContextualValue(self, val_e, ast_e, td, itn, scope, span);
                    if (td.kind == .struct_type and v == .struct_val and ast_e.kind == .struct_literal) {
                        v = try stampNamedType(self, ast_e, td, itn, v, scope, span);
                    }
                    new_elems[j] = v;
                }
                resolved_elements = new_elems;
                // Short-circuit for enum: preserve original semantics (skip adoption path below).
                if (td.kind == .enum_type) {
                    for (new_elems, 0..) |ev, j| {
                        if (ev == .enum_val) {
                            new_elems[j] = Value{ .enum_val = .{ .value = ev.enum_val.value, .variants = td.kind.enum_type.variants, .type_name = itn } };
                        }
                    }
                    return Value{ .list = .{ .elements = new_elems, .element_type = et } };
                }
            }
        }
    }

    // Validate and adopt list elements
    if (inner_type_name) |itn| {
        const adopted = try self.allocator.alloc(Value, resolved_elements.len);
        if (scope.getType(itn)) |td| {
            // §3.9: refinement element type — check base match + predicate.
            const check_name = if (td.refinement) |rf| rf.base_type_name else itn;
            for (resolved_elements, 0..) |elem, j| {
                if (elem.isUndefined() or elem.isNull()) {
                    adopted[j] = elem;
                } else {
                    var a = h.adoptToType(elem, check_name);
                    if (a == .struct_val and a.struct_val.type_name == null)
                        a = Value{ .struct_val = .{ .keys = a.struct_val.keys, .values = a.struct_val.values, .type_name = itn } };
                    if (!h.valueMatchesType(a, check_name))
                        return self.typeErr("list element does not match declared element type", span.line, span.col);
                    if (td.refinement) |rf| try checkRefinement(self, rf, a, scope, span);
                    adopted[j] = a;
                }
            }
        } else {
            for (resolved_elements, 0..) |elem, j| adopted[j] = h.adoptToType(elem, itn);
        }
        return Value{ .list = .{ .elements = adopted, .element_type = et } };
    }

    return Value{ .list = .{ .elements = resolved_elements, .element_type = et } };
}

fn annotatePath(self: *Evaluator, expr_node: *const Ast.Node, segments: []const []const u8, type_expr: *const Ast.TypeExpr, value: Value, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (resolvePathTypeName(self, segments, type_expr.*, scope)) |rn| {
        const name_te = Ast.TypeExpr{ .data = .{ .name = rn }, .span = span };
        return evalTypeAnnotation(self, expr_node, &name_te, scope, exclude, span);
    }
    if (value.isUndefined()) return .undefined;
    return value;
}

fn resolvePathTypeName(self: *Evaluator, segments: []const []const u8, te: Ast.TypeExpr, scope: *Scope) ?[]const u8 {
    if (typeExprToString(self, te) catch null) |pn|
        if (scope.getType(pn) != null) return pn;
    const final_seg = segments[segments.len - 1];
    var i: usize = 0;
    while (i < segments.len - 1) : (i += 1) {
        const prefix = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ segments[i], final_seg }) catch continue;
        if (scope.getType(prefix) != null) return prefix;
    }
    if (scope.getType(final_seg) != null) return final_seg;
    return null;
}

pub const stampNamedTypePub = stampNamedType;

fn stampNamedType(self: *Evaluator, expr_node: *const Ast.Node, td: *const val.TypeDef, type_name: []const u8, value: Value, scope: *Scope, span: Ast.Span) EvalError!Value {
    // Enum variant resolution: identifier shadowed by variant name
    if (td.kind == .enum_type) {
        if (expr_node.kind == .identifier) {
            const name = expr_node.kind.identifier.name;
            for (td.kind.enum_type.variants) |v| {
                if (std.mem.eql(u8, v, name))
                    return Value{ .enum_val = .{ .value = name, .variants = td.kind.enum_type.variants, .type_name = type_name } };
            }
        }
    }

    // §3.7 v0.10: variant shorthand sentinel resolves against tagged union target.
    if (td.kind == .tagged_union_type and @import("eval_exprs.zig").isShorthandSentinel(value)) {
        return @import("eval_exprs.zig").resolveShorthandAgainstType(self, value, td, type_name, scope, span);
    }

    // §6.3 R7: literal adoption into named union — integer/float/string/bool
    // literals pick the first member whose category exactly matches; integer
    // literals may fall back to a float member via promotion. Float literals
    // never adopt integer types.
    if (td.kind == .union_type and value != .union_val and value != .null_val and !value.isUndefined()) {
        const ut = td.kind.union_type;
        const lit_cat: ?[]const u8 = switch (value) {
            .integer => |iv| if (!iv.explicit) "integer" else null,
            .float_val => |fv| if (!fv.explicit) "float" else null,
            .string => "string",
            .bool_val => "bool",
            else => null,
        };
        if (lit_cat) |cat| {
            var chosen_idx: ?usize = null;
            for (ut.types, 0..) |mt, i| {
                const mc: ?[]const u8 = blk: {
                    if (h.parseIntegerTypeName(mt) != null) break :blk "integer";
                    if (h.parseFloatTypeName(mt) != null) break :blk "float";
                    if (std.mem.eql(u8, mt, "string")) break :blk "string";
                    if (std.mem.eql(u8, mt, "bool")) break :blk "bool";
                    break :blk null;
                };
                if (mc) |m| if (std.mem.eql(u8, m, cat)) {
                    chosen_idx = i;
                    break;
                };
            }
            // Integer → float promotion fallback (never float → integer).
            if (chosen_idx == null and std.mem.eql(u8, cat, "integer")) {
                for (ut.types, 0..) |mt, i| {
                    if (h.parseFloatTypeName(mt) != null) {
                        chosen_idx = i;
                        break;
                    }
                }
            }
            if (chosen_idx) |ci| {
                const mt = ut.types[ci];
                const adopted = h.adoptToType(value, mt);
                if (!h.valueMatchesType(adopted, mt))
                    return self.typeErr("union value does not match chosen member type", span.line, span.col);
                const vp = try self.allocator.create(Value);
                vp.* = adopted;
                return Value{ .union_val = .{ .value = vp, .types = ut.types, .type_name = type_name } };
            }
            return self.typeErr("union value does not match any member type", span.line, span.col);
        }
    }

    var result = value;
    switch (result) {
        .enum_val => |e| {
            // §3.2: nominal identity — already-named enum cannot be re-cast to a different named type.
            if (e.type_name) |existing| if (!std.mem.eql(u8, existing, type_name))
                return self.typeErr("nominal type mismatch: value has a different named type", span.line, span.col);
            if (td.kind == .enum_type) {
                const et = td.kind.enum_type;
                var found = false;
                for (et.variants) |v| if (std.mem.eql(u8, v, e.value)) {
                    found = true;
                    break;
                };
                if (!found) return self.typeErr("not a variant of the named enum type", span.line, span.col);
                result = Value{ .enum_val = .{ .value = e.value, .variants = et.variants, .type_name = type_name } };
            }
        },
        .tagged_union => |tu| {
            if (tu.type_name) |existing| if (!std.mem.eql(u8, existing, type_name))
                return self.typeErr("nominal type mismatch: value has a different named type", span.line, span.col);
            result = Value{ .tagged_union = .{ .value = tu.value, .tag = tu.tag, .variants = tu.variants, .type_name = type_name } };
        },
        .union_val => |u| {
            if (u.type_name) |existing| if (!std.mem.eql(u8, existing, type_name))
                return self.typeErr("nominal type mismatch: value has a different named type", span.line, span.col);
            result = Value{ .union_val = .{ .value = u.value, .types = u.types, .type_name = type_name } };
        },
        .struct_val => |s| {
            if (s.type_name) |existing| if (!std.mem.eql(u8, existing, type_name))
                return self.typeErr("nominal type mismatch: value has a different named type", span.line, span.col);
            var final_keys = s.keys;
            var final_values = s.values;
            if (td.kind == .struct_type) {
                const st = td.kind.struct_type;
                // Reject unknown fields (§3.2: no extras allowed)
                for (s.keys) |k| {
                    var known = false;
                    for (st.fields) |f| if (std.mem.eql(u8, k, f.name)) {
                        known = true;
                        break;
                    };
                    if (!known) return self.typeErr("struct field not declared in named type", span.line, span.col);
                }
                const binding_asts: []const Ast.Binding = if (expr_node.kind == .struct_literal) expr_node.kind.struct_literal.fields else &.{};
                const new_keys = try self.allocator.alloc([]const u8, st.fields.len);
                const new_values = try self.allocator.alloc(Value, st.fields.len);
                for (st.fields, 0..) |f, ti| {
                    new_keys[ti] = f.name;
                    const found_idx: ?usize = for (s.keys, 0..) |k, ki| {
                        if (std.mem.eql(u8, k, f.name)) break ki;
                    } else null;
                    if (found_idx) |fi| {
                        var fval = s.values[fi];
                        const field_ast = findBindingAst(binding_asts, f.name);
                        // §3.5/§3.7: resolve bare variant / shorthand sentinel against field's declared named type.
                        if (f.type_annotation) |ta| {
                            if (scope.getType(ta)) |ftd| {
                                fval = try resolveContextualValue(self, fval, field_ast, ftd, ta, scope, span);
                                // §3.2: recursively stamp nested struct values so declared-type
                                // defaults fill in missing fields and inner annotations apply.
                                if (ftd.kind == .struct_type and fval == .struct_val and fval.struct_val.type_name == null) {
                                    const inner_ast = field_ast orelse expr_node;
                                    fval = try stampNamedType(self, inner_ast, ftd, ta, fval, scope, span);
                                }
                            }
                        }
                        new_values[ti] = fval;
                        if (!fval.isNull() and !fval.isUndefined()) {
                            // §3.2.1: deferred-null (`x is null`) accepts any type per instance.
                            // Typed-null (`x is null as T`) fixes the underlying type to T —
                            // the overriding value must match T, not the "null" category.
                            const is_null_category = std.mem.eql(u8, f.type_category, "null");
                            const deferred_null = is_null_category and f.type_annotation == null;
                            const typed_null = is_null_category and f.type_annotation != null;
                            if (!deferred_null and !typed_null and !std.mem.eql(u8, fval.typeName(), f.type_category))
                                return self.typeErr("struct field type does not match named type definition", span.line, span.col);
                            if (typed_null) {
                                const adopted = h.adoptToType(fval, f.type_annotation.?);
                                if (!h.valueMatchesType(adopted, f.type_annotation.?))
                                    return self.typeErr("struct field type does not match typed-null declaration", span.line, span.col);
                                new_values[ti] = adopted;
                            }
                            if (f.type_annotation) |ta| try validateFieldTypeAnnotation(self, fval, ta, ti, new_values, span);
                        }
                    } else {
                        // §3.2: missing field — fill from declared default
                        new_values[ti] = f.default;
                    }
                }
                final_keys = new_keys;
                final_values = new_values;
            }
            result = Value{ .struct_val = .{ .keys = final_keys, .values = final_values, .type_name = type_name } };
        },
        .function => |f| result = Value{ .function = .{ .params = f.params, .return_type = f.return_type, .body_bindings = f.body_bindings, .body_expr = f.body_expr, .captured_keys = f.captured_keys, .captured_values = f.captured_values, .captured_types = f.captured_types, .type_name = type_name } },
        .list => |l| {
            if (td.kind != .list_type)
                return self.typeErrSpan("cannot annotate list as non-list named type", span);
            const lt = td.kind.list_type;
            const new_elems: []const Value = if (lt.element_type) |et_name| blk: {
                const adopted = try self.allocator.alloc(Value, l.elements.len);
                for (l.elements, 0..) |elem, j| {
                    if (elem.isUndefined() or elem.isNull()) {
                        adopted[j] = elem;
                    } else {
                        const a = h.adoptToType(elem, et_name);
                        if (!h.valueMatchesType(a, et_name))
                            return self.typeErrSpan("list element does not match named list's element type", span);
                        adopted[j] = a;
                    }
                }
                break :blk adopted;
            } else l.elements;
            const elem_type: ?[]const u8 = lt.element_type orelse l.element_type;
            result = Value{ .list = .{ .elements = new_elems, .element_type = elem_type, .type_name = type_name } };
        },
        else => {},
    }
    return result;
}

fn findBindingAst(bindings: []const Ast.Binding, name: []const u8) ?*const Ast.Node {
    for (bindings) |b| if (std.mem.eql(u8, b.name, name)) return b.value;
    return null;
}

/// §3.5 R4: look up a bare identifier as a variant of the given named type.
/// Returns the resolved Value, or null if the name is not a variant.
pub fn variantLookup(td: *const val.TypeDef, type_name: []const u8, id_name: []const u8, allocator: std.mem.Allocator) ?Value {
    switch (td.kind) {
        .enum_type => |et| {
            for (et.variants) |v| if (std.mem.eql(u8, v, id_name))
                return Value{ .enum_val = .{ .value = id_name, .variants = et.variants, .type_name = type_name } };
        },
        .tagged_union_type => |tut| {
            for (tut.variants) |v| if (std.mem.eql(u8, v.name, id_name)) {
                const inner = allocator.create(Value) catch return null;
                inner.* = .null_val;
                return Value{ .tagged_union = .{ .value = inner, .tag = id_name, .variants = tut.variants, .type_name = type_name } };
            };
        },
        else => {},
    }
    return null;
}

/// §3.5/§3.7: resolve a value against a known named type context.
/// - If shorthand sentinel and target is tagged union → resolve.
/// - If value is undefined and AST node is bare identifier matching a variant → resolve.
pub fn resolveContextualValue(self: *Evaluator, value: Value, ast_node: ?*const Ast.Node, td: *const val.TypeDef, type_name: []const u8, scope: ?*Scope, span: Ast.Span) EvalError!Value {
    const eval_exprs = @import("eval_exprs.zig");
    if (eval_exprs.isShorthandSentinel(value)) {
        if (td.kind == .tagged_union_type)
            return eval_exprs.resolveShorthandAgainstType(self, value, td, type_name, scope, span);
        return self.typeErrSpan("variant shorthand used where non-tagged-union type is expected", span);
    }
    if (value.isUndefined()) {
        if (ast_node) |an| {
            if (an.kind == .identifier) {
                const id_name = an.kind.identifier.name;
                switch (td.kind) {
                    .enum_type => |et| {
                        for (et.variants) |v| if (std.mem.eql(u8, v, id_name))
                            return Value{ .enum_val = .{ .value = id_name, .variants = et.variants, .type_name = type_name } };
                    },
                    .tagged_union_type => |tut| {
                        for (tut.variants) |v| if (std.mem.eql(u8, v.name, id_name)) {
                            const inner = try self.allocator.create(Value);
                            inner.* = .null_val;
                            return Value{ .tagged_union = .{ .value = inner, .tag = id_name, .variants = tut.variants, .type_name = type_name } };
                        };
                    },
                    .union_type => |ut| {
                        // §3.5 L866: bare identifier against a union whose members include
                        // enums/tagged unions — collect matches across all members. Zero
                        // matches falls through as undefined; multiple matches is a type error.
                        var matched: ?Value = null;
                        var match_count: usize = 0;
                        if (scope) |sc| {
                            for (ut.types) |member_name| {
                                const mtd = sc.getType(member_name) orelse continue;
                                switch (mtd.kind) {
                                    .enum_type => |et| {
                                        for (et.variants) |v| if (std.mem.eql(u8, v, id_name)) {
                                            match_count += 1;
                                            matched = Value{ .enum_val = .{ .value = id_name, .variants = et.variants, .type_name = member_name } };
                                            break;
                                        };
                                    },
                                    .tagged_union_type => |tut| {
                                        for (tut.variants) |v| if (std.mem.eql(u8, v.name, id_name)) {
                                            match_count += 1;
                                            const inner = try self.allocator.create(Value);
                                            inner.* = .null_val;
                                            matched = Value{ .tagged_union = .{ .value = inner, .tag = id_name, .variants = tut.variants, .type_name = member_name } };
                                            break;
                                        };
                                    },
                                    else => {},
                                }
                            }
                        }
                        if (match_count > 1)
                            return self.typeErrSpan("ambiguous bare variant: matches multiple members of union type", span);
                        if (matched) |m| return m;
                    },
                    else => {},
                }
            }
        }
    }
    return value;
}

fn validateFieldTypeAnnotation(self: *Evaluator, fval: Value, ta: []const u8, fi: usize, new_values: []Value, span: Ast.Span) EvalError!void {
    if (fval == .integer and !fval.integer.explicit) {
        if (h.parseIntegerTypeName(ta)) |it| {
            if (!h.intFitsType(fval.integer.value, it))
                return self.rtErr("struct field value out of range for named type", span.line, span.col);
            new_values[fi] = Value{ .integer = .{ .value = fval.integer.value, .type_ann = it, .explicit = true } };
        }
    } else if (fval == .float_val and !fval.float_val.explicit) {
        if (h.parseFloatTypeName(ta)) |ft|
            new_values[fi] = Value{ .float_val = .{ .value = fval.float_val.value, .type_ann = ft, .explicit = true } };
    } else if (fval == .integer and fval.integer.explicit) {
        if (h.intTypeNameAlloc(self.allocator, fval.integer.type_ann)) |ftn|
            if (!std.mem.eql(u8, ftn, ta))
                return self.typeErr("struct field numeric type does not match named type definition", span.line, span.col);
    } else if (fval == .float_val and fval.float_val.explicit) {
        if (h.floatTypeName(fval.float_val.type_ann)) |ftn|
            if (!std.mem.eql(u8, ftn, ta))
                return self.typeErr("struct field numeric type does not match named type definition", span.line, span.col);
    }
}

// ── Type conversion (`to`) ───────────────────────────────────

pub fn evalConversion(self: *Evaluator, expr_node: *const Ast.Node, type_expr: *const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(expr_node, scope, exclude);

    const type_name = switch (type_expr.data) {
        .name => |n| n,
        .path => |segments| resolvePathTypeName(self, segments, type_expr.*, scope) orelse
            return self.typeErr("unknown type in conversion", span.line, span.col),
        .list => |inner| return convertList(self, value, inner, scope, span),
        else => return self.typeErr("complex type conversions not yet supported", span.line, span.col),
    };

    if (std.mem.eql(u8, type_name, "bool")) {
        if (value == .bool_val) return value;
        // §5.11.2: `"true"` / `"false"` convert to bool; other strings are a
        // runtime error.
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "true")) return Value.boolean(true);
            if (std.mem.eql(u8, value.string, "false")) return Value.boolean(false);
            return self.rtErr("string is not \"true\" or \"false\"", span.line, span.col);
        }
        return self.typeErr("cannot convert to bool", span.line, span.col);
    }
    if (std.mem.eql(u8, type_name, "null"))
        return if (value == .null_val) value else self.typeErr("cannot convert to null", span.line, span.col);
    if (value.isUndefined()) return .undefined;

    if (h.parseIntegerTypeName(type_name)) |it| return convertToInteger(self, value, it, span);
    if (h.parseFloatTypeName(type_name)) |ft| return convertToFloat(self, value, ft, span);
    if (std.mem.eql(u8, type_name, "string")) return convertToString(self, value, span);

    // Named enum / refinement: dispatch by kind
    if (scope.getType(type_name)) |td| {
        if (td.refinement) |rf| {
            const base_te = Ast.TypeExpr{ .data = .{ .name = rf.base_type_name }, .span = span };
            const converted = try evalConversion(self, expr_node, &base_te, scope, exclude, span);
            try checkRefinement(self, rf, converted, scope, span);
            return converted;
        }
        return switch (td.kind) {
            .enum_type => |et| switch (value) {
                .string => |s| blk: {
                    for (et.variants) |v| if (std.mem.eql(u8, s, v))
                        break :blk Value{ .enum_val = .{ .value = s, .variants = et.variants, .type_name = type_name } };
                    return self.rtErr("string does not match any enum variant", span.line, span.col);
                },
                else => self.typeErr("cannot convert to enum type", span.line, span.col),
            },
            else => self.typeErr("cannot convert to this named type", span.line, span.col),
        };
    }
    return self.typeErr("unknown conversion target type", span.line, span.col);
}

fn convertList(self: *Evaluator, value: Value, inner: *const Ast.TypeExpr, scope: *Scope, span: Ast.Span) EvalError!Value {
    if (value.isUndefined()) return .undefined;
    if (value != .list) return self.typeErr("cannot convert non-list to list type", span.line, span.col);

    const inner_name = switch (inner.data) {
        .name => |n| n,
        .path => |segments| resolvePathTypeName(self, segments, inner.*, scope) orelse
            return self.typeErr("unknown type in list conversion", span.line, span.col),
        else => return self.typeErr("complex list element conversions not yet supported", span.line, span.col),
    };

    const new_elems = try self.allocator.alloc(Value, value.list.elements.len);
    for (value.list.elements, 0..) |elem, i| {
        if (elem.isUndefined()) {
            new_elems[i] = elem;
            continue;
        }
        if (h.parseIntegerTypeName(inner_name)) |it| {
            new_elems[i] = try convertToInteger(self, elem, it, span);
        } else if (h.parseFloatTypeName(inner_name)) |ft| {
            new_elems[i] = try convertToFloat(self, elem, ft, span);
        } else if (std.mem.eql(u8, inner_name, "string")) {
            new_elems[i] = try convertToString(self, elem, span);
        } else {
            return self.typeErr("unsupported element type in list conversion", span.line, span.col);
        }
    }
    return Value{ .list = .{ .elements = new_elems, .element_type = inner_name } };
}

fn convertToInteger(self: *Evaluator, value: Value, int_type: val.IntegerType, span: Ast.Span) EvalError!Value {
    const result: i128 = switch (value) {
        .integer => |iv| iv.value,
        .float_val => |fv| blk: {
            if (std.math.isNan(fv.value) or std.math.isInf(fv.value))
                return self.rtErr("cannot convert inf/nan to integer", span.line, span.col);
            const max_i128: f64 = @floatFromInt(@as(i128, std.math.maxInt(i128)));
            const min_i128: f64 = @floatFromInt(@as(i128, std.math.minInt(i128)));
            if (fv.value > max_i128 or fv.value < min_i128)
                return self.rtErr("float value out of range for integer conversion", span.line, span.col);
            break :blk @intFromFloat(fv.value);
        },
        .string => |s| h.parseIntegerText(self.allocator, s) catch return self.rtErr("string is not a valid integer", span.line, span.col),
        .union_val, .tagged_union => return self.typeErr("union can only convert to string", span.line, span.col),
        .struct_val, .tuple, .list, .function => return self.typeErr("cannot convert compound type to integer", span.line, span.col),
        else => return self.typeErr("cannot convert to integer", span.line, span.col),
    };
    if (!h.intFitsType(result, int_type))
        return self.rtErr("value out of range for target integer type", span.line, span.col);
    return Value{ .integer = .{ .value = result, .type_ann = int_type, .explicit = true } };
}

fn convertToFloat(self: *Evaluator, value: Value, float_type: val.FloatType, span: Ast.Span) EvalError!Value {
    const result: f64 = switch (value) {
        .integer => |iv| @floatFromInt(iv.value),
        .float_val => |fv| fv.value,
        .string => |s| h.parseFloatText(self.allocator, s) catch return self.rtErr("string is not a valid float", span.line, span.col),
        .union_val, .tagged_union => return self.typeErr("union can only convert to string", span.line, span.col),
        .struct_val, .tuple, .list, .function => return self.typeErr("cannot convert compound type to float", span.line, span.col),
        else => return self.typeErr("cannot convert to float", span.line, span.col),
    };
    if (!std.math.isNan(result) and !std.math.isInf(result)) {
        switch (float_type) {
            .f16 => if (result != 0.0 and @abs(result) > 65504.0)
                return self.rtErr("value out of range for f16", span.line, span.col),
            .f32 => if (result != 0.0 and @abs(result) > 3.4028235e+38)
                return self.rtErr("value out of range for f32", span.line, span.col),
            else => {},
        }
    }
    return Value{ .float_val = .{ .value = result, .type_ann = float_type, .explicit = true } };
}

fn convertToString(self: *Evaluator, value: Value, span: Ast.Span) EvalError!Value {
    return switch (value) {
        .string => value,
        .bool_val => |b| Value.str(if (b) "true" else "false"),
        .null_val => Value.str("null"),
        .integer => |i| blk: {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i.value}) catch return error.OutOfMemory;
            break :blk Value.str(try self.allocator.dupe(u8, s));
        },
        .float_val => |f| Value.str(try h.formatFloat(self.allocator, f.value)),
        .enum_val => |e| Value.str(e.value),
        .union_val => |u| convertToString(self, u.value.*, span),
        .tagged_union => |tu| convertToString(self, tu.value.*, span),
        .struct_val, .tuple, .list => self.typeErrSug("cannot convert compound type to string", "use string interpolation instead", span.line, span.col),
        .function => self.typeErr("cannot convert function to string", span.line, span.col),
        .undefined => .undefined,
    };
}

// ── Type expression → string ────────────────────────────────

pub fn typeExprToString(self: *Evaluator, te: Ast.TypeExpr) !?[]const u8 {
    return switch (te.data) {
        .name => |n| n,
        .null_type => "null",
        .path => |segments| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            for (segments, 0..) |seg, i| {
                if (i > 0) try buf.append(self.allocator, '.');
                try buf.appendSlice(self.allocator, seg);
            }
            break :blk try buf.toOwnedSlice(self.allocator);
        },
        .list => |inner| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.append(self.allocator, '[');
            if (try typeExprToString(self, inner.*)) |inner_str| try buf.appendSlice(self.allocator, inner_str);
            try buf.append(self.allocator, ']');
            break :blk try buf.toOwnedSlice(self.allocator);
        },
        .tuple => |elems| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.append(self.allocator, '(');
            for (elems, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                if (try typeExprToString(self, elem)) |es| try buf.appendSlice(self.allocator, es);
            }
            if (elems.len == 1) try buf.append(self.allocator, ',');
            try buf.append(self.allocator, ')');
            break :blk try buf.toOwnedSlice(self.allocator);
        },
    };
}

/// Build a TypeDef from a value and its `called` name.
pub fn typeDefsEquivalent(a: *const val.TypeDef, b: *const val.TypeDef) bool {
    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    return switch (a.kind) {
        .enum_type => |ae| blk: {
            const be = b.kind.enum_type;
            if (ae.variants.len != be.variants.len) break :blk false;
            for (ae.variants, be.variants) |av, bv|
                if (!std.mem.eql(u8, av, bv)) break :blk false;
            break :blk true;
        },
        .union_type => |au| blk: {
            const bu = b.kind.union_type;
            if (au.types.len != bu.types.len) break :blk false;
            for (au.types, bu.types) |at, bt|
                if (!std.mem.eql(u8, at, bt)) break :blk false;
            break :blk true;
        },
        .tagged_union_type => |atu| blk: {
            const btu = b.kind.tagged_union_type;
            if (atu.variants.len != btu.variants.len) break :blk false;
            for (atu.variants, btu.variants) |av, bv| {
                if (!std.mem.eql(u8, av.name, bv.name)) break :blk false;
                const aname = av.type_name orelse "";
                const bname = bv.type_name orelse "";
                if (!std.mem.eql(u8, aname, bname)) break :blk false;
            }
            break :blk true;
        },
        .struct_type => |as_| blk: {
            const bs = b.kind.struct_type;
            if (as_.fields.len != bs.fields.len) break :blk false;
            for (as_.fields, bs.fields) |af, bf| {
                if (!std.mem.eql(u8, af.name, bf.name)) break :blk false;
                if (!std.mem.eql(u8, af.type_category, bf.type_category)) break :blk false;
            }
            break :blk true;
        },
        .function_type => |af| blk: {
            const bf = b.kind.function_type;
            if (af.param_types.len != bf.param_types.len) break :blk false;
            for (af.param_types, bf.param_types) |at, bt|
                if (!std.mem.eql(u8, at, bt)) break :blk false;
            if (!std.mem.eql(u8, af.return_type, bf.return_type)) break :blk false;
            break :blk true;
        },
        .list_type => |al| blk: {
            const bl = b.kind.list_type;
            const a_et = al.element_type orelse "";
            const b_et = bl.element_type orelse "";
            break :blk std.mem.eql(u8, a_et, b_et);
        },
        .refinement_primitive => |ar| std.mem.eql(u8, ar.base, b.kind.refinement_primitive.base),
    };
}

/// Extract `T` from a field AST of the form `name is null as T`.
/// Returns null if the binding is not a typed-null declaration.
fn typedNullAnnotation(binding: Ast.Binding) ?[]const u8 {
    const v = binding.value;
    if (v.kind != .type_annotation) return null;
    const ta = v.kind.type_annotation;
    if (ta.expr.kind != .null_literal) return null;
    return switch (ta.type_expr.data) {
        .name => |n| n,
        else => null,
    };
}

pub fn buildTypeDef(self: *Evaluator, name: []const u8, value: Value, ast: ?*const Ast.Node) ?val.TypeDef {
    return switch (value) {
        .enum_val => |e| val.TypeDef{ .name = name, .kind = .{ .enum_type = .{ .variants = e.variants } } },
        .union_val => |u| val.TypeDef{ .name = name, .kind = .{ .union_type = .{ .types = u.types } } },
        .tagged_union => |tu| val.TypeDef{ .name = name, .kind = .{ .tagged_union_type = .{ .variants = tu.variants } } },
        .struct_val => |s| blk: {
            const fields = self.allocator.alloc(val.TypeDef.FieldInfo, s.keys.len) catch break :blk val.TypeDef{ .name = name, .kind = .{ .struct_type = .{ .fields = &.{} } } };
            // If the declaration AST is a struct_literal, we can recover typed-null
            // annotations (`field is null as T`) that collapse to a bare null value.
            const field_asts: []const Ast.Binding = if (ast) |a| (if (a.kind == .struct_literal) a.kind.struct_literal.fields else &.{}) else &.{};
            for (s.keys, s.values, 0..) |key, fv, fi| {
                const typed_null_ann: ?[]const u8 = if (fv == .null_val) blk2: {
                    for (field_asts) |fb| if (std.mem.eql(u8, fb.name, key)) {
                        break :blk2 typedNullAnnotation(fb);
                    };
                    break :blk2 null;
                } else null;
                fields[fi] = .{
                    .name = key,
                    .type_category = fv.typeName(),
                    .type_annotation = if (typed_null_ann) |tn| tn else switch (fv) {
                        .integer => |iv| if (iv.explicit) h.intTypeNameAlloc(self.allocator, iv.type_ann) else null,
                        .float_val => |fvv| if (fvv.explicit) h.floatTypeName(fvv.type_ann) else null,
                        .struct_val => |sv| sv.type_name,
                        .enum_val => |ev| ev.type_name,
                        .union_val => |uv| uv.type_name,
                        .tagged_union => |tu| tu.type_name,
                        .list => |lv| lv.element_type,
                        else => null,
                    },
                    .default = fv,
                };
            }
            break :blk val.TypeDef{ .name = name, .kind = .{ .struct_type = .{ .fields = fields } } };
        },
        .list => |l| val.TypeDef{ .name = name, .kind = .{ .list_type = .{ .element_type = l.element_type } } },
        .function => |f| blk: {
            const ptypes = self.allocator.alloc([]const u8, f.params.len) catch break :blk val.TypeDef{ .name = name, .kind = .{ .function_type = .{ .param_types = &.{}, .return_type = "unknown" } } };
            for (f.params, 0..) |p, pi| {
                ptypes[pi] = switch (p.type_expr.data) {
                    .name => |n| n,
                    else => "unknown",
                };
            }
            const rtype: []const u8 = switch (f.return_type.data) {
                .name => |n| n,
                else => "unknown",
            };
            break :blk val.TypeDef{ .name = name, .kind = .{ .function_type = .{ .param_types = ptypes, .return_type = rtype } } };
        },
        else => null,
    };
}
