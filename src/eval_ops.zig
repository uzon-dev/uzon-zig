const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Integer = val.Integer;
const Float = val.Float;
const Scope = @import("Scope.zig");
const h = @import("eval_helpers.zig");
const Token = @import("Token.zig");

const EvalError = Evaluator.EvalError;

// ── Keyword suggestion helpers ──────────────────────────────

fn keywordSuggestion(allocator: std.mem.Allocator, node: *const Ast.Node) ?[]const u8 {
    if (node.kind == .identifier) {
        if (Token.findCaseInsensitiveKeyword(node.kind.identifier.name)) |kw|
            return std.fmt.allocPrint(allocator, "did you mean '{s}'?", .{kw}) catch null;
    }
    return null;
}

fn undefinedSuggestion(allocator: std.mem.Allocator, ln: *const Ast.Node, rn: *const Ast.Node, lv: Value, rv: Value) ?[]const u8 {
    if (lv.isUndefined()) if (keywordSuggestion(allocator, ln)) |s| return s;
    if (rv.isUndefined()) if (keywordSuggestion(allocator, rn)) |s| return s;
    return null;
}

fn undefinedErr(self: *Evaluator, msg: []const u8, ln: *const Ast.Node, rn: *const Ast.Node, lv: Value, rv: Value, span: Ast.Span) EvalError {
    if (undefinedSuggestion(self.allocator, ln, rn, lv, rv)) |sug|
        return self.rtErrSug(msg, sug, span.line, span.col);
    return self.rtErr(msg, span.line, span.col);
}

fn undefinedErrSingle(self: *Evaluator, msg: []const u8, node: *const Ast.Node, span: Ast.Span) EvalError {
    if (keywordSuggestion(self.allocator, node)) |sug|
        return self.rtErrSug(msg, sug, span.line, span.col);
    return self.rtErr(msg, span.line, span.col);
}

// ── Binary operations ────────────────────────────────────────

pub fn evalBinaryOp(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    return switch (op) {
        .add, .sub, .mul, .div, .mod_, .pow => evalArithmetic(self, op, ln, rn, scope, exclude, span),
        .concat => evalConcat(self, ln, rn, scope, exclude, span),
        .repeat => evalRepeat(self, ln, rn, scope, exclude, span),
        .lt, .le, .gt, .ge => evalRelational(self, op, ln, rn, scope, exclude, span),
        .eq, .neq => evalEquality(self, op, ln, rn, scope, exclude, span),
        .@"and", .@"or" => evalLogical(self, op, ln, rn, scope, exclude, span),
        .is_type, .is_not_type => evalIsType(self, op, ln, rn, scope, exclude, span),
        .is_named, .is_not_named => evalIsNamed(self, op, ln, rn, scope, exclude, span),
        .in_ => evalInOperator(self, ln, rn, scope, exclude, span),
    };
}

fn evalArithmetic(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const raw_l = try self.evalNode(ln, scope, exclude);
    const raw_r = try self.evalNode(rn, scope, exclude);
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in arithmetic operation", ln, rn, raw_l, raw_r, span);

    const adopted = h.adoptNumericTypes(raw_l.unwrapTransparent(), raw_r.unwrapTransparent());
    const l = adopted[0];
    const r = adopted[1];

    return switch (l) {
        .integer => |li| switch (r) {
            .integer => |ri| intArithmetic(self, op, li, ri, span),
            else => self.typeErr("arithmetic requires same numeric types", span.line, span.col),
        },
        .float_val => |lf| switch (r) {
            .float_val => |rf| floatArithmetic(self, op, lf, rf, span),
            else => self.typeErr("arithmetic requires same numeric types", span.line, span.col),
        },
        else => self.typeErr("arithmetic requires numeric operands", span.line, span.col),
    };
}

fn intArithmetic(self: *Evaluator, op: Ast.BinaryOp, left: Integer, right: Integer, span: Ast.Span) EvalError!Value {
    if (left.explicit and right.explicit and !h.intTypesMatch(left.type_ann, right.type_ann))
        return self.typeErr("integer type mismatch in arithmetic", span.line, span.col);

    const a = left.value;
    const b = right.value;
    const rt = h.adoptIntType(left, right);

    const result: i128 = switch (op) {
        .add => std.math.add(i128, a, b) catch return self.rtErr("integer overflow", span.line, span.col),
        .sub => std.math.sub(i128, a, b) catch return self.rtErr("integer overflow", span.line, span.col),
        .mul => std.math.mul(i128, a, b) catch return self.rtErr("integer overflow", span.line, span.col),
        .div => blk: {
            if (b == 0) return self.rtErr("division by zero", span.line, span.col);
            break :blk @divTrunc(a, b);
        },
        .mod_ => blk: {
            if (b == 0) return self.rtErr("modulo by zero", span.line, span.col);
            break :blk @rem(a, b);
        },
        .pow => try intPow(self, a, b, span),
        else => unreachable,
    };

    if ((left.explicit or right.explicit) and !h.intFitsType(result, rt))
        return self.rtErr("integer overflow for type", span.line, span.col);

    return Value{ .integer = .{ .value = result, .type_ann = rt, .explicit = left.explicit or right.explicit } };
}

fn intPow(self: *Evaluator, base: i128, exp: i128, span: Ast.Span) EvalError!i128 {
    if (exp < 0) return self.rtErr("negative exponent for integer exponentiation", span.line, span.col);
    if (exp == 0) return 1;
    if (base == 0) return 0;
    if (base == 1) return 1;
    if (base == -1) return if (@rem(exp, 2) == 0) @as(i128, 1) else @as(i128, -1);

    var result: i128 = 1;
    var b = base;
    var e = exp;
    while (e > 0) {
        if (@rem(e, 2) == 1)
            result = std.math.mul(i128, result, b) catch return self.rtErr("integer overflow in exponentiation", span.line, span.col);
        e = @divTrunc(e, 2);
        if (e > 0)
            b = std.math.mul(i128, b, b) catch return self.rtErr("integer overflow in exponentiation", span.line, span.col);
    }
    return result;
}

fn floatArithmetic(self: *Evaluator, op: Ast.BinaryOp, left: Float, right: Float, span: Ast.Span) EvalError!Value {
    if (left.explicit and right.explicit and left.type_ann != right.type_ann)
        return self.typeErr("float type mismatch in arithmetic", span.line, span.col);

    const rt = h.adoptFloatType(left, right);
    const result: f64 = switch (op) {
        .add => left.value + right.value,
        .sub => left.value - right.value,
        .mul => left.value * right.value,
        .div => left.value / right.value,
        .mod_ => @rem(left.value, right.value),
        .pow => std.math.pow(f64, left.value, right.value),
        else => unreachable,
    };
    return Value{ .float_val = .{ .value = result, .type_ann = rt, .explicit = left.explicit or right.explicit } };
}

fn evalRepeat(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const raw_l = try self.evalNode(ln, scope, exclude);
    const raw_r = try self.evalNode(rn, scope, exclude);
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in repetition", ln, rn, raw_l, raw_r, span);

    const left = raw_l.unwrapTransparent();
    const right = raw_r.unwrapTransparent();

    const count: usize = switch (right) {
        .integer => |ri| blk: {
            if (ri.value < 0) return self.rtErr("repetition count must be non-negative", span.line, span.col);
            break :blk @intCast(ri.value);
        },
        else => return self.typeErr("repetition count must be integer", span.line, span.col),
    };

    return switch (left) {
        .string => |s| blk: {
            if (count == 0) break :blk Value.str("");
            var buf = std.ArrayListUnmanaged(u8){};
            for (0..count) |_| buf.appendSlice(self.allocator, s) catch return error.OutOfMemory;
            break :blk Value.str(buf.items);
        },
        .list => |l| blk: {
            const elements = try self.allocator.alloc(Value, l.elements.len * count);
            for (0..count) |rep| @memcpy(elements[rep * l.elements.len .. (rep + 1) * l.elements.len], l.elements);
            break :blk Value{ .list = .{ .elements = elements, .element_type = l.element_type } };
        },
        else => self.typeErr("repetition requires string or list", span.line, span.col),
    };
}

fn evalConcat(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const raw_l = try self.evalNode(ln, scope, exclude);
    const raw_r = try self.evalNode(rn, scope, exclude);
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in concatenation", ln, rn, raw_l, raw_r, span);

    const left = raw_l.unwrapTransparent();
    const right = raw_r.unwrapTransparent();

    return switch (left) {
        .string => |ls| switch (right) {
            .string => |rs| blk: {
                var buf = std.ArrayListUnmanaged(u8){};
                buf.appendSlice(self.allocator, ls) catch return error.OutOfMemory;
                buf.appendSlice(self.allocator, rs) catch return error.OutOfMemory;
                break :blk Value.str(buf.items);
            },
            else => self.typeErr("concatenation requires same types", span.line, span.col),
        },
        .list => |ll| switch (right) {
            .list => |rl| blk: {
                if (ll.elements.len > 0 and rl.elements.len > 0) {
                    const l_first = firstNonNull(ll.elements);
                    const r_first = firstNonNull(rl.elements);
                    if (l_first != null and r_first != null)
                        if (!h.branchTypesCompatible(l_first.?, r_first.?))
                            return self.typeErr("list concatenation requires matching element types", span.line, span.col);
                }
                const elements = try self.allocator.alloc(Value, ll.elements.len + rl.elements.len);
                @memcpy(elements[0..ll.elements.len], ll.elements);
                @memcpy(elements[ll.elements.len..], rl.elements);
                break :blk Value{ .list = .{ .elements = elements, .element_type = ll.element_type } };
            },
            else => self.typeErr("concatenation requires same types", span.line, span.col),
        },
        else => self.typeErr("concatenation requires strings or lists", span.line, span.col),
    };
}

fn evalRelational(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const raw_l = try self.evalNode(ln, scope, exclude);
    const raw_r = try self.evalNode(rn, scope, exclude);
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in comparison", ln, rn, raw_l, raw_r, span);
    if (raw_l == .tagged_union and raw_r == .tagged_union)
        return self.typeErr("ordered comparison between tagged unions is not defined", span.line, span.col);

    const adopted = h.adoptNumericTypes(raw_l.unwrapTransparent(), raw_r.unwrapTransparent());
    const l = adopted[0];
    const r = adopted[1];

    const result: bool = switch (l) {
        .integer => |li| switch (r) {
            .integer => |ri| blk: {
                if (li.explicit and ri.explicit and !h.intTypesMatch(li.type_ann, ri.type_ann))
                    return self.typeErr("integer type mismatch in comparison", span.line, span.col);
                break :blk cmp(i128, li.value, ri.value, op);
            },
            else => return self.typeErr("relational comparison requires same types", span.line, span.col),
        },
        .float_val => |lf| switch (r) {
            .float_val => |rf| blk: {
                if (lf.explicit and rf.explicit and lf.type_ann != rf.type_ann)
                    return self.typeErr("float type mismatch in comparison", span.line, span.col);
                break :blk cmp(f64, lf.value, rf.value, op);
            },
            else => return self.typeErr("relational comparison requires same types", span.line, span.col),
        },
        .string => |ls| switch (r) {
            .string => |rs| blk: {
                const ord = std.mem.order(u8, ls, rs);
                break :blk switch (op) {
                    .lt => ord == .lt,
                    .le => ord != .gt,
                    .gt => ord == .gt,
                    .ge => ord != .lt,
                    else => unreachable,
                };
            },
            else => return self.typeErr("relational comparison requires same types", span.line, span.col),
        },
        else => return self.typeErr("relational comparison not supported for this type", span.line, span.col),
    };
    return Value.boolean(result);
}

fn cmp(comptime T: type, a: T, b: T, op: Ast.BinaryOp) bool {
    return switch (op) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        else => unreachable,
    };
}

fn evalEquality(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const left = try self.evalNode(ln, scope, exclude);
    const right = try self.evalNode(rn, scope, exclude);

    if (left.isNull() or left.isUndefined() or right.isNull() or right.isUndefined()) {
        const eq = h.runtimeEqual(left, right);
        return Value.boolean(if (op == .eq) eq else !eq);
    }
    if (left == .function or right == .function)
        return self.typeErr("cannot compare functions", span.line, span.col);
    if (left == .tagged_union and right == .tagged_union) {
        const eq = h.runtimeEqual(left, right);
        return Value.boolean(if (op == .eq) eq else !eq);
    }
    if (left == .tagged_union or right == .tagged_union)
        return self.typeErr("cannot compare tagged union with non-tagged-union value", span.line, span.col);

    const adopted = h.adoptNumericTypes(left.unwrapUntagged(), right.unwrapUntagged());
    const l = adopted[0];
    const r = adopted[1];

    if (!h.sameCategory(l, r))
        return self.typeErr("equality comparison requires same types", span.line, span.col);

    // Struct shape check
    if (l == .struct_val and r == .struct_val) {
        if (l.struct_val.keys.len != r.struct_val.keys.len)
            return self.typeErr("cannot compare structs with different shapes", span.line, span.col);
        for (l.struct_val.keys, l.struct_val.values) |k, lv| {
            var found = false;
            for (r.struct_val.keys, r.struct_val.values) |rk, rv| {
                if (std.mem.eql(u8, k, rk)) {
                    found = true;
                    if (!lv.isNull() and !rv.isNull() and !h.sameCategory(lv, rv))
                        return self.typeErr("cannot compare structs with different field types", span.line, span.col);
                    break;
                }
            }
            if (!found) return self.typeErr("cannot compare structs with different shapes", span.line, span.col);
        }
    }
    if (l == .tuple and r == .tuple) {
        if (l.tuple.elements.len != r.tuple.elements.len)
            return self.typeErr("cannot compare tuples of different length", span.line, span.col);
        for (l.tuple.elements, r.tuple.elements) |le, re| {
            if (!le.isNull() and !re.isNull() and !h.sameCategory(le, re))
                return self.typeErr("cannot compare tuples with different element types", span.line, span.col);
        }
    }
    if (l == .list and r == .list) {
        if (l.list.elements.len > 0 and r.list.elements.len > 0) {
            const lf = firstNonNull(l.list.elements);
            const rf = firstNonNull(r.list.elements);
            if (lf != null and rf != null and !h.sameCategory(lf.?, rf.?))
                return self.typeErr("cannot compare lists with different element types", span.line, span.col);
        }
    }

    const eq = h.runtimeEqual(l, r);
    return Value.boolean(if (op == .eq) eq else !eq);
}

fn evalLogical(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const left = try self.evalNode(ln, scope, exclude);
    if (left.isUndefined()) return undefinedErrSingle(self, "undefined value in logical operation", ln, span);

    switch (left) {
        .bool_val => |lv| {
            if (op == .@"or" and lv) {
                try speculativeEval(self, rn, scope, exclude);
                return Value.boolean(true);
            }
            if (op == .@"and" and !lv) {
                try speculativeEval(self, rn, scope, exclude);
                return Value.boolean(false);
            }
            const right = try self.evalNode(rn, scope, exclude);
            if (right.isUndefined()) return undefinedErrSingle(self, "undefined value in logical operation", rn, span);
            return switch (right) {
                .bool_val => |rv| Value.boolean(rv),
                else => self.typeErr("logical operators require bool operands", span.line, span.col),
            };
        },
        else => return self.typeErr("logical operators require bool operands", span.line, span.col),
    }
}

// ── or else ──────────────────────────────────────────────────

pub fn evalOrElse(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const left = try self.evalNode(ln, scope, exclude);
    if (left.isUndefined()) return try self.evalNode(rn, scope, exclude);
    const right = self.evalNode(rn, scope, exclude) catch |e| switch (e) {
        error.UzonRuntime => return left,
        else => return e,
    };
    if (!left.isNull() and !right.isNull() and !h.branchTypesCompatible(left, right))
        return self.typeErr("'or else' operands must be the same type", span.line, span.col);
    return left;
}

// ── Unary operations ─────────────────────────────────────────

pub fn evalUnaryOp(self: *Evaluator, op: Ast.UnaryOp, node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const operand = try self.evalNode(node, scope, exclude);

    switch (op) {
        .negate => {
            if (operand.isUndefined()) return undefinedErrSingle(self, "cannot negate undefined", node, span);
            return switch (operand) {
                .integer => |i| Value{ .integer = .{
                    .value = std.math.negate(i.value) catch return self.rtErr("integer overflow in negation", span.line, span.col),
                    .type_ann = i.type_ann,
                    .explicit = i.explicit,
                } },
                .float_val => |f| Value{ .float_val = .{ .value = -f.value, .type_ann = f.type_ann, .explicit = f.explicit } },
                else => self.typeErr("negation requires numeric operand", span.line, span.col),
            };
        },
        .not => {
            if (operand.isUndefined()) return undefinedErrSingle(self, "undefined value in 'not' operation", node, span);
            return switch (operand) {
                .bool_val => |bv| Value.boolean(!bv),
                else => self.typeErr("'not' requires bool operand", span.line, span.col),
            };
        },
    }
}

// ── is type / is named / in ─────────────────────────────────

fn evalIsType(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(ln, scope, exclude);
    if (value.isUndefined()) return self.rtErr("undefined value in 'is type' check", span.line, span.col);
    const type_name = switch (rn.kind) {
        .identifier => |id| id.name,
        else => return self.typeErr("'is type' requires type name", span.line, span.col),
    };
    const matches = h.valueMatchesType(value.unwrapTransparent(), type_name);
    return Value.boolean(if (op == .is_type) matches else !matches);
}

fn evalIsNamed(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(ln, scope, exclude);
    if (value.isUndefined()) return self.rtErr("undefined value in 'is named' check", span.line, span.col);
    const tu = switch (value) {
        .tagged_union => |t| t,
        else => return self.typeErr("'is named' requires tagged union", span.line, span.col),
    };
    const variant_name = switch (rn.kind) {
        .identifier => |id| id.name,
        else => return self.typeErr("'is named' requires variant name", span.line, span.col),
    };
    if (!h.isValidVariantTag(tu.variants, variant_name))
        return self.typeErr("unknown variant name in 'is named'", span.line, span.col);
    const matches = std.mem.eql(u8, tu.tag, variant_name);
    return Value.boolean(if (op == .is_named) matches else !matches);
}

fn evalInOperator(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const raw_needle = try self.evalNode(ln, scope, exclude);
    const raw_haystack = try self.evalNode(rn, scope, exclude);
    if (raw_needle.isUndefined() or raw_haystack.isUndefined())
        return self.rtErr("undefined value in 'in' operation", span.line, span.col);

    const needle = raw_needle.unwrapTransparent();
    const haystack = raw_haystack.unwrapTransparent();

    return switch (haystack) {
        .list => |l| blk: {
            if (l.elements.len > 0 and !needle.isNull()) {
                if (firstNonNull(l.elements)) |fnn| {
                    if (!h.sameCategory(needle, fnn))
                        return self.typeErr("'in' value and list element types must match", span.line, span.col);
                    if (needle == .integer and fnn == .integer)
                        if (needle.integer.explicit or fnn.integer.explicit)
                            if (!h.intTypesMatch(needle.integer.type_ann, fnn.integer.type_ann))
                                return self.typeErr("'in' integer type mismatch", span.line, span.col);
                    if (needle == .enum_val and fnn == .enum_val) {
                        const n_tn = needle.enum_val.type_name;
                        const e_tn = fnn.enum_val.type_name;
                        if (n_tn != null and e_tn != null)
                            if (!std.mem.eql(u8, n_tn.?, e_tn.?))
                                return self.typeErr("'in' enum type mismatch", span.line, span.col);
                    }
                }
            }
            for (l.elements) |e| {
                if (h.runtimeEqual(needle, e)) break :blk Value.boolean(true);
            }
            break :blk Value.boolean(false);
        },
        .tuple => self.typeErr("'in' operator only applies to lists, not tuples", span.line, span.col),
        else => self.typeErr("'in' operator only applies to lists", span.line, span.col),
    };
}

// ── Speculative evaluation ──────────────────────────────────

pub fn speculativeEval(self: *Evaluator, node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8) EvalError!void {
    _ = self.evalNode(node, scope, exclude) catch |e| switch (e) {
        error.UzonRuntime => return,
        else => return e,
    };
}

// ── Helpers ─────────────────────────────────────────────────

fn firstNonNull(elements: []const Value) ?Value {
    for (elements) |e| {
        if (e != .null_val) return e;
    }
    return null;
}
