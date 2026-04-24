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

// ── Eager binary operand evaluation ────────────────────���────
// Evaluates both operands even if the left side fails, so that
// errors from both sides are collected.

/// Whether a node is a direct name reference (identifier, member access, env).
/// Sub-expressions that evaluated to .undefined have already had their errors
/// collected; this distinguishes them from genuinely unresolved names.
pub fn isDirectReference(node: *const Ast.Node) bool {
    return switch (node.kind) {
        .identifier, .member_access, .env_ref => true,
        .grouping => |g| isDirectReference(g.expr),
        else => false,
    };
}

/// Evaluate both sides of a binary operation. If either side errors,
/// the error is collected and .undefined is returned in its place,
/// so the other side still gets evaluated.
fn evalBinaryOperands(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8) [2]Value {
    var left: Value = .undefined;
    if (self.evalNode(ln, scope, exclude)) |v| {
        left = v;
    } else |_| {
        if (self.last_error) |le| self.collected_errors.append(self.allocator, le) catch {};
        self.last_error = null;
    }
    var right: Value = .undefined;
    if (self.evalNode(rn, scope, exclude)) |v| {
        right = v;
    } else |_| {
        if (self.last_error) |le| self.collected_errors.append(self.allocator, le) catch {};
        self.last_error = null;
    }
    return .{ left, right };
}

// ── Keyword suggestion helpers ──────────────────────────────

fn keywordSuggestion(allocator: std.mem.Allocator, node: *const Ast.Node) ?[]const u8 {
    if (node.kind == .identifier) {
        if (Token.findCaseInsensitiveKeyword(node.kind.identifier.name)) |kw|
            return std.fmt.allocPrint(allocator, "did you mean '{s}'?", .{kw}) catch null;
    }
    return null;
}

/// Report undefined operand errors. Only reports for direct references;
/// sub-expression .undefined values have already been collected by evalBinaryOperands.
fn undefinedErr(self: *Evaluator, msg: []const u8, ln: *const Ast.Node, rn: *const Ast.Node, lv: Value, rv: Value, _: Ast.Span) EvalError {
    const err_mod = @import("error.zig");
    const l_report = lv.isUndefined() and isDirectReference(ln);
    const r_report = rv.isUndefined() and isDirectReference(rn);

    if (l_report and r_report) {
        self.collected_errors.append(self.allocator, if (keywordSuggestion(self.allocator, ln)) |s|
            err_mod.UzonError.initWithSuggestion(self.allocator, .runtime, msg, s, ln.span.line, ln.span.col)
        else
            err_mod.UzonError.init(self.allocator, .runtime, msg, ln.span.line, ln.span.col)) catch {};
        if (keywordSuggestion(self.allocator, rn)) |s| return self.rtErrSugSpan(msg, s, rn.span);
        return self.rtErrSpan(msg, rn.span);
    }
    if (l_report) {
        if (keywordSuggestion(self.allocator, ln)) |s| return self.rtErrSugSpan(msg, s, ln.span);
        return self.rtErrSpan(msg, ln.span);
    }
    if (r_report) {
        if (keywordSuggestion(self.allocator, rn)) |s| return self.rtErrSugSpan(msg, s, rn.span);
        return self.rtErrSpan(msg, rn.span);
    }
    // Both undefined from sub-expression errors — already collected, just propagate.
    self.last_error = null;
    return error.UzonRuntime;
}

fn undefinedErrSingle(self: *Evaluator, msg: []const u8, node: *const Ast.Node, _: Ast.Span) EvalError {
    if (keywordSuggestion(self.allocator, node)) |sug|
        return self.rtErrSugSpan(msg, sug, node.span);
    return self.rtErrSpan(msg, node.span);
}

// ── Binary operations ────────────────────────────────────────

// §5.4 chained comparison: evaluate each operand once, short-circuit via AND.
pub fn evalChainedCmp(self: *Evaluator, operands: []const *const Ast.Node, ops: []const Ast.BinaryOp, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    _ = span;
    std.debug.assert(operands.len == ops.len + 1);
    // Evaluate operands lazily with short-circuit; we still evaluate each
    // referenced operand only once.
    const values = try self.allocator.alloc(?Value, operands.len);
    for (values) |*v| v.* = null;
    // First two
    values[0] = try self.evalNode(operands[0], scope, exclude);
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        values[i + 1] = try self.evalNode(operands[i + 1], scope, exclude);
        // Reuse evalRelational logic: synthesize a binary_op AST evaluation path
        const partial = try evalRelationalValues(self, ops[i], values[i].?, values[i + 1].?, operands[i].span, operands[i + 1].span);
        if (!partial) return Value.boolean(false);
    }
    return Value.boolean(true);
}

fn evalRelationalValues(self: *Evaluator, op: Ast.BinaryOp, raw_l: Value, raw_r: Value, l_span: Ast.Span, r_span: Ast.Span) EvalError!bool {
    _ = l_span;
    _ = r_span;
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return self.rtErrSpan("undefined value in comparison", Ast.Span{ .line = 0, .col = 0 });
    const adopted = h.adoptNumericTypes(raw_l.unwrapTransparent(), raw_r.unwrapTransparent());
    const l = adopted[0];
    const r = adopted[1];
    return switch (l) {
        .integer => |li| switch (r) {
            .integer => |ri| blk: {
                if (li.explicit and ri.explicit and !h.intTypesMatch(li.type_ann, ri.type_ann))
                    return self.typeErrSpan("integer type mismatch in comparison", Ast.Span{ .line = 0, .col = 0 });
                break :blk cmp(i128, li.value, ri.value, op);
            },
            else => self.typeErrSpan("relational comparison requires same types", Ast.Span{ .line = 0, .col = 0 }),
        },
        .float_val => |lf| switch (r) {
            .float_val => |rf| blk: {
                if (lf.explicit and rf.explicit and lf.type_ann != rf.type_ann)
                    return self.typeErrSpan("float type mismatch in comparison", Ast.Span{ .line = 0, .col = 0 });
                break :blk cmp(f64, lf.value, rf.value, op);
            },
            else => self.typeErrSpan("relational comparison requires same types", Ast.Span{ .line = 0, .col = 0 }),
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
            else => self.typeErrSpan("relational comparison requires same types", Ast.Span{ .line = 0, .col = 0 }),
        },
        else => self.typeErrSpan("relational comparison not supported for this type", Ast.Span{ .line = 0, .col = 0 }),
    };
}

pub fn evalBinaryOp(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    return switch (op) {
        .add, .sub, .mul, .div, .mod_ => evalArithmetic(self, op, ln, rn, scope, exclude, span),
        .concat => evalConcat(self, ln, rn, scope, exclude, span),
        .lt, .le, .gt, .ge => evalRelational(self, op, ln, rn, scope, exclude, span),
        .eq, .neq => evalEquality(self, op, ln, rn, scope, exclude, span),
        .@"and", .@"or" => evalLogical(self, op, ln, rn, scope, exclude, span),
        .is_type, .is_not_type => evalIsType(self, op, ln, rn, scope, exclude, span),
        .is_named, .is_not_named => evalIsNamed(self, op, ln, rn, scope, exclude, span),
        .in_ => evalInOperator(self, ln, rn, scope, exclude, span),
        .bit_and, .bit_or, .bit_xor, .shl, .shr => evalBitwise(self, op, ln, rn, scope, exclude, span),
    };
}

fn evalBitwise(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_l = ops[0];
    const raw_r = ops[1];
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in bitwise operation", ln, rn, raw_l, raw_r, span);
    const l_t = raw_l.unwrapTransparent();
    const r_t = raw_r.unwrapTransparent();
    const li = switch (l_t) {
        .integer => |i| i,
        else => return self.typeErrSpan("bitwise operators require integer operands", span),
    };
    const ri = switch (r_t) {
        .integer => |i| i,
        else => return self.typeErrSpan("bitwise operators require integer operands", span),
    };
    if (li.explicit and ri.explicit and !h.intTypesMatch(li.type_ann, ri.type_ann))
        return self.typeErrSpan("bitwise requires matching integer types", span);
    const rt = h.adoptIntType(li, ri);
    const width: u32 = switch (rt) {
        .arbitrary => 64,
        .signed => |w| w,
        .unsigned => |w| w,
    };
    const is_signed = rt == .signed;
    var a = li.value;
    var b = ri.value;
    const result: i128 = switch (op) {
        .bit_and => a & b,
        .bit_or => a | b,
        .bit_xor => a ^ b,
        .shl => blk: {
            if (b < 0 or b >= @as(i128, width))
                return self.rtErrSpan("shift count out of range", span);
            const shifted = a << @intCast(b);
            // Mask to width
            const mask: i128 = (@as(i128, 1) << @intCast(width)) - 1;
            var masked = shifted & mask;
            if (is_signed and width < 128) {
                const sign_bit: i128 = @as(i128, 1) << @intCast(width - 1);
                if ((masked & sign_bit) != 0) masked = masked | ~mask;
            }
            break :blk masked;
        },
        .shr => blk: {
            if (b < 0 or b >= @as(i128, width))
                return self.rtErrSpan("shift count out of range", span);
            if (is_signed) {
                break :blk a >> @intCast(b);
            } else {
                const mask: i128 = (@as(i128, 1) << @intCast(width)) - 1;
                const u: u128 = @intCast(a & mask);
                break :blk @as(i128, @intCast(u >> @intCast(b)));
            }
        },
        else => unreachable,
    };
    _ = &a;
    _ = &b;
    return Value{ .integer = .{ .value = result, .type_ann = rt, .explicit = li.explicit or ri.explicit } };
}

fn evalArithmetic(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_l = ops[0];
    const raw_r = ops[1];
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in arithmetic operation", ln, rn, raw_l, raw_r, span);

    const adopted = h.adoptNumericTypes(raw_l.unwrapTransparent(), raw_r.unwrapTransparent());
    const l = adopted[0];
    const r = adopted[1];

    return switch (l) {
        .integer => |li| switch (r) {
            .integer => |ri| intArithmetic(self, op, li, ri, span),
            else => self.typeErrSpan("arithmetic requires same numeric types", span),
        },
        .float_val => |lf| switch (r) {
            .float_val => |rf| floatArithmetic(self, op, lf, rf, span),
            else => self.typeErrSpan("arithmetic requires same numeric types", span),
        },
        else => self.typeErrSpan("arithmetic requires numeric operands", span),
    };
}

fn intArithmetic(self: *Evaluator, op: Ast.BinaryOp, left: Integer, right: Integer, span: Ast.Span) EvalError!Value {
    if (left.explicit and right.explicit and !h.intTypesMatch(left.type_ann, right.type_ann))
        return self.typeErrSpan("integer type mismatch in arithmetic", span);

    const a = left.value;
    const b = right.value;
    const rt = h.adoptIntType(left, right);

    const result: i128 = switch (op) {
        .add => std.math.add(i128, a, b) catch return self.rtErrSpan("integer overflow", span),
        .sub => std.math.sub(i128, a, b) catch return self.rtErrSpan("integer overflow", span),
        .mul => std.math.mul(i128, a, b) catch return self.rtErrSpan("integer overflow", span),
        .div => blk: {
            if (b == 0) return self.rtErrSpan("division by zero", span);
            break :blk @divTrunc(a, b);
        },
        .mod_ => blk: {
            if (b == 0) return self.rtErrSpan("modulo by zero", span);
            break :blk @rem(a, b);
        },
        else => unreachable,
    };

    if ((left.explicit or right.explicit) and !h.intFitsType(result, rt))
        return self.rtErrSpan("integer overflow for type", span);

    return Value{ .integer = .{ .value = result, .type_ann = rt, .explicit = left.explicit or right.explicit } };
}

pub fn intPowPublic(self: *Evaluator, base: i128, exp: i128, span: Ast.Span) EvalError!i128 {
    return intPow(self, base, exp, span);
}

fn intPow(self: *Evaluator, base: i128, exp: i128, span: Ast.Span) EvalError!i128 {
    if (exp < 0) return self.rtErrSpan("negative exponent for integer exponentiation", span);
    if (exp == 0) return 1;
    if (base == 0) return 0;
    if (base == 1) return 1;
    if (base == -1) return if (@rem(exp, 2) == 0) @as(i128, 1) else @as(i128, -1);

    var result: i128 = 1;
    var b = base;
    var e = exp;
    while (e > 0) {
        if (@rem(e, 2) == 1)
            result = std.math.mul(i128, result, b) catch return self.rtErrSpan("integer overflow in exponentiation", span);
        e = @divTrunc(e, 2);
        if (e > 0)
            b = std.math.mul(i128, b, b) catch return self.rtErrSpan("integer overflow in exponentiation", span);
    }
    return result;
}

fn floatArithmetic(self: *Evaluator, op: Ast.BinaryOp, left: Float, right: Float, span: Ast.Span) EvalError!Value {
    if (left.explicit and right.explicit and left.type_ann != right.type_ann)
        return self.typeErrSpan("float type mismatch in arithmetic", span);

    const rt = h.adoptFloatType(left, right);
    const result: f64 = switch (op) {
        .add => left.value + right.value,
        .sub => left.value - right.value,
        .mul => left.value * right.value,
        .div => left.value / right.value,
        .mod_ => @rem(left.value, right.value),
        else => unreachable,
    };
    return Value{ .float_val = .{ .value = result, .type_ann = rt, .explicit = left.explicit or right.explicit } };
}

fn evalRepeat(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_l = ops[0];
    const raw_r = ops[1];
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in repetition", ln, rn, raw_l, raw_r, span);

    const left = raw_l.unwrapTransparent();
    const right = raw_r.unwrapTransparent();

    const count: usize = switch (right) {
        .integer => |ri| blk: {
            if (ri.value < 0) return self.rtErrSpan("repetition count must be non-negative", span);
            break :blk @intCast(ri.value);
        },
        else => return self.typeErrSpan("repetition count must be integer", span),
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
            // §3.4: preserve element type even when count=0 produces an empty
            // list. If the source list has no explicit element_type, infer it
            // from its elements so the result carries the correct type.
            const et = l.element_type orelse h.listElementTypeName(left);
            break :blk Value{ .list = .{ .elements = elements, .element_type = et } };
        },
        else => self.typeErrSpan("repetition requires string or list", span),
    };
}

fn evalConcat(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_l = ops[0];
    const raw_r = ops[1];
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
            else => self.typeErrSpan("concatenation requires same types", span),
        },
        .list => |ll| switch (right) {
            .list => |rl| blk: {
                if (ll.elements.len > 0 and rl.elements.len > 0) {
                    const l_first = firstNonNull(ll.elements);
                    const r_first = firstNonNull(rl.elements);
                    if (l_first != null and r_first != null)
                        if (!h.branchTypesCompatible(l_first.?, r_first.?))
                            return self.typeErrSpan("list concatenation requires matching element types", span);
                }
                const elements = try self.allocator.alloc(Value, ll.elements.len + rl.elements.len);
                @memcpy(elements[0..ll.elements.len], ll.elements);
                @memcpy(elements[ll.elements.len..], rl.elements);
                break :blk Value{ .list = .{ .elements = elements, .element_type = ll.element_type } };
            },
            else => self.typeErrSpan("concatenation requires same types", span),
        },
        else => self.typeErrSpan("concatenation requires strings or lists", span),
    };
}

fn evalRelational(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_l = ops[0];
    const raw_r = ops[1];
    if (raw_l.isUndefined() or raw_r.isUndefined())
        return undefinedErr(self, "undefined value in comparison", ln, rn, raw_l, raw_r, span);
    if (raw_l == .tagged_union and raw_r == .tagged_union)
        return self.typeErrSpan("ordered comparison between tagged unions is not defined", span);
    if (raw_l == .function or raw_r == .function)
        return self.typeErrSpan("ordered comparison on functions is not defined", span);
    if (raw_l == .union_val or raw_r == .union_val)
        return self.typeErrSpan("ordered comparison on untagged unions is not defined", span);

    const adopted = h.adoptNumericTypes(raw_l.unwrapTransparent(), raw_r.unwrapTransparent());
    const l = adopted[0];
    const r = adopted[1];

    const result: bool = switch (l) {
        .integer => |li| switch (r) {
            .integer => |ri| blk: {
                if (li.explicit and ri.explicit and !h.intTypesMatch(li.type_ann, ri.type_ann))
                    return self.typeErrSpan("integer type mismatch in comparison", span);
                break :blk cmp(i128, li.value, ri.value, op);
            },
            else => return self.typeErrSpan("relational comparison requires same types", span),
        },
        .float_val => |lf| switch (r) {
            .float_val => |rf| blk: {
                if (lf.explicit and rf.explicit and lf.type_ann != rf.type_ann)
                    return self.typeErrSpan("float type mismatch in comparison", span);
                break :blk cmp(f64, lf.value, rf.value, op);
            },
            else => return self.typeErrSpan("relational comparison requires same types", span),
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
            else => return self.typeErrSpan("relational comparison requires same types", span),
        },
        else => return self.typeErrSpan("relational comparison not supported for this type", span),
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
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const left = ops[0];
    const right = ops[1];

    if (left.isNull() or left.isUndefined() or right.isNull() or right.isUndefined()) {
        const eq = h.runtimeEqual(left, right);
        return Value.boolean(if (op == .eq) eq else !eq);
    }
    if (left == .function or right == .function)
        return self.typeErrSpan("cannot compare functions", span);
    if (left == .tagged_union and right == .tagged_union) {
        const eq = h.runtimeEqual(left, right);
        return Value.boolean(if (op == .eq) eq else !eq);
    }
    if (left == .tagged_union or right == .tagged_union)
        return self.typeErrSpan("cannot compare tagged union with non-tagged-union value", span);
    // Untagged union comparison (v0.8 §5.2)
    if (left == .union_val and right == .union_val) {
        // Different union types → type error; same type + different runtime type → false
        if (!h.unionTypesMatch(left.union_val, right.union_val))
            return self.typeErrSpan("cannot compare untagged unions of different types", span);
        if (!h.sameCategory(left.union_val.value.*, right.union_val.value.*)) {
            return Value.boolean(op == .neq);
        }
        const eq = h.runtimeEqual(left.union_val.value.*, right.union_val.value.*);
        return Value.boolean(if (op == .eq) eq else !eq);
    }
    if (left == .union_val or right == .union_val) {
        // Union vs non-union — transparent comparison
    }

    const adopted = h.adoptNumericTypes(left.unwrapUntagged(), right.unwrapUntagged());
    const l = adopted[0];
    const r = adopted[1];

    if (!h.sameCategory(l, r))
        return self.typeErrSpan("equality comparison requires same types", span);

    // Struct shape check
    if (l == .struct_val and r == .struct_val) {
        // §7.3 + §3.2.1 rule 5: nominal identity — structs with distinct named
        // types cannot be compared even if their shape matches. Anonymous structs
        // (type_name == null) fall through to structural comparison.
        if (l.struct_val.type_name) |ltn| if (r.struct_val.type_name) |rtn| {
            if (!std.mem.eql(u8, ltn, rtn))
                return self.typeErrSpan("cannot compare different nominal struct types", span);
        };
        if (l.struct_val.keys.len != r.struct_val.keys.len)
            return self.typeErrSpan("cannot compare structs with different shapes", span);
        for (l.struct_val.keys, l.struct_val.values) |k, lv| {
            var found = false;
            for (r.struct_val.keys, r.struct_val.values) |rk, rv| {
                if (std.mem.eql(u8, k, rk)) {
                    found = true;
                    if (!lv.isNull() and !rv.isNull() and !h.sameCategory(lv, rv))
                        return self.typeErrSpan("cannot compare structs with different field types", span);
                    break;
                }
            }
            if (!found) return self.typeErrSpan("cannot compare structs with different shapes", span);
        }
    }
    if (l == .tuple and r == .tuple) {
        if (l.tuple.elements.len != r.tuple.elements.len)
            return self.typeErrSpan("cannot compare tuples of different length", span);
        for (l.tuple.elements, r.tuple.elements) |le, re| {
            if (!le.isNull() and !re.isNull() and !h.sameCategory(le, re))
                return self.typeErrSpan("cannot compare tuples with different element types", span);
        }
    }
    if (l == .list and r == .list) {
        if (l.list.elements.len > 0 and r.list.elements.len > 0) {
            const lf = firstNonNull(l.list.elements);
            const rf = firstNonNull(r.list.elements);
            if (lf != null and rf != null and !h.sameCategory(lf.?, rf.?))
                return self.typeErrSpan("cannot compare lists with different element types", span);
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
                else => self.typeErrSpan("logical operators require bool operands", span),
            };
        },
        else => return self.typeErrSpan("logical operators require bool operands", span),
    }
}

// ── or else ──────────────────────────────────────────────────

pub fn evalOrElse(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (ln.kind == .undefined_literal)
        return self.typeErrSpan("literal 'undefined' not allowed as 'or else' operand", ln.span);
    if (rn.kind == .undefined_literal)
        return self.typeErrSpan("literal 'undefined' not allowed as 'or else' operand", rn.span);
    const left = try self.evalNode(ln, scope, exclude);
    if (left.isUndefined()) {
        const right = try self.evalNode(rn, scope, exclude);
        // §5.7: right operand must match left's static type category when left has one.
        if (!right.isUndefined()) {
            if (staticCategoryOf(ln)) |cat| {
                if (valueCategory(right)) |rcat| {
                    if (!std.mem.eql(u8, cat, rcat)) {
                        const numeric_mix = (std.mem.eql(u8, cat, "integer") and std.mem.eql(u8, rcat, "float")) or
                            (std.mem.eql(u8, cat, "float") and std.mem.eql(u8, rcat, "integer"));
                        if (!numeric_mix) return self.typeErrSpan("'or else' operands must be the same type", span);
                    }
                }
            }
        }
        return right;
    }
    const right = self.evalNode(rn, scope, exclude) catch |e| switch (e) {
        error.UzonRuntime => return left,
        else => return e,
    };
    if (!left.isNull() and !right.isNull() and !h.branchTypesCompatible(left, right))
        return self.typeErrSpan("'or else' operands must be the same type", span);
    return left;
}

fn staticCategoryOf(node: *const Ast.Node) ?[]const u8 {
    return switch (node.kind) {
        .conversion => |cv| typeExprCategory(&cv.type_expr),
        .type_annotation => |ta| typeExprCategory(&ta.type_expr),
        .string_literal => "string",
        .integer_literal => "integer",
        .float_literal, .inf_literal, .nan_literal => "float",
        .bool_literal => "bool",
        .or_else => |oe| staticCategoryOf(oe.left) orelse staticCategoryOf(oe.right),
        .binary_op => |bo| staticCategoryOf(bo.left) orelse staticCategoryOf(bo.right),
        else => null,
    };
}

fn typeExprCategory(te: *const Ast.TypeExpr) ?[]const u8 {
    return switch (te.data) {
        .name => |n| blk: {
            if (h.parseIntegerTypeName(n) != null) break :blk "integer";
            if (h.parseFloatTypeName(n) != null) break :blk "float";
            if (std.mem.eql(u8, n, "string")) break :blk "string";
            if (std.mem.eql(u8, n, "bool")) break :blk "bool";
            break :blk null;
        },
        .list => "list",
        .tuple => "tuple",
        else => null,
    };
}

fn valueCategory(v: Value) ?[]const u8 {
    return switch (v) {
        .integer => "integer",
        .float_val => "float",
        .string => "string",
        .bool_val => "bool",
        .list => "list",
        .tuple => "tuple",
        .struct_val => "struct",
        .enum_val => "enum",
        else => null,
    };
}

// ── Unary operations ─────────────────────────────────────────

pub fn evalUnaryOp(self: *Evaluator, op: Ast.UnaryOp, node: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const operand = try self.evalNode(node, scope, exclude);

    switch (op) {
        .negate => {
            if (operand.isUndefined()) return undefinedErrSingle(self, "cannot negate undefined", node, span);
            return switch (operand) {
                .integer => |i| Value{ .integer = .{
                    .value = std.math.negate(i.value) catch return self.rtErrSpan("integer overflow in negation", span),
                    .type_ann = i.type_ann,
                    .explicit = i.explicit,
                } },
                .float_val => |f| Value{ .float_val = .{ .value = -f.value, .type_ann = f.type_ann, .explicit = f.explicit } },
                else => self.typeErrSpan("negation requires numeric operand", span),
            };
        },
        .not => {
            if (operand.isUndefined()) return undefinedErrSingle(self, "undefined value in 'not' operation", node, span);
            return switch (operand) {
                .bool_val => |bv| Value.boolean(!bv),
                else => self.typeErrSpan("'not' requires bool operand", span),
            };
        },
        .bit_not => {
            if (operand.isUndefined()) return undefinedErrSingle(self, "undefined value in '~' operation", node, span);
            const unwrapped = operand.unwrapTransparent();
            return switch (unwrapped) {
                .integer => |i| blk: {
                    const width: u32 = switch (i.type_ann) {
                        .arbitrary => 64,
                        .signed => |w| w,
                        .unsigned => |w| w,
                    };
                    const mask: i128 = if (width >= 128) -1 else (@as(i128, 1) << @intCast(width)) - 1;
                    var result: i128 = (~i.value) & mask;
                    const is_signed = i.type_ann == .signed;
                    if (is_signed and width < 128) {
                        const sign_bit: i128 = @as(i128, 1) << @intCast(width - 1);
                        if ((result & sign_bit) != 0) result = result | ~mask;
                    }
                    break :blk Value{ .integer = .{ .value = result, .type_ann = i.type_ann, .explicit = i.explicit } };
                },
                else => self.typeErrSpan("'~' requires integer operand", span),
            };
        },
    }
}

// ── is type / is named / in ─────────────────────────────────

fn evalIsType(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(ln, scope, exclude);
    if (value.isUndefined()) return self.rtErrSpan("undefined value in 'is type' check", ln.span);
    const unwrapped = value.unwrapTransparent();
    var matches: bool = undefined;
    // §3.9 is type RefinedType: structural match on base AND predicate.
    if (rn.kind == .identifier) {
        const id = rn.kind.identifier.name;
        if (scope.getType(id)) |td| {
            if (td.refinement) |rf| {
                matches = h.valueMatchesType(unwrapped, rf.base_type_name);
                if (matches) {
                    const et = @import("eval_types.zig");
                    et.checkRefinement(self, rf, unwrapped, scope, span) catch {
                        self.last_error = null;
                        matches = false;
                    };
                }
                return Value.boolean(if (op == .is_type) matches else !matches);
            }
        }
    }
    matches = switch (rn.kind) {
        .identifier => |id| h.valueMatchesType(unwrapped, id.name),
        .type_pattern => |tp| @import("eval_exprs.zig").valueMatchesTypeExpr(unwrapped, tp.type_expr),
        else => return self.typeErrSpan("'is type' requires type name", span),
    };
    return Value.boolean(if (op == .is_type) matches else !matches);
}

fn evalIsNamed(self: *Evaluator, op: Ast.BinaryOp, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(ln, scope, exclude);
    if (value.isUndefined()) return self.rtErrSpan("undefined value in 'is named' check", ln.span);
    const tu = switch (value) {
        .tagged_union => |t| t,
        else => return self.typeErrSpan("'is named' requires tagged union", span),
    };
    const variant_name = switch (rn.kind) {
        .identifier => |id| id.name,
        else => return self.typeErrSpan("'is named' requires variant name", span),
    };
    if (!h.isValidVariantTag(tu.variants, variant_name))
        return self.typeErrSpan("unknown variant name in 'is named'", span);
    const matches = std.mem.eql(u8, tu.tag, variant_name);
    return Value.boolean(if (op == .is_named) matches else !matches);
}

fn evalInOperator(self: *Evaluator, ln: *const Ast.Node, rn: *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const ops = evalBinaryOperands(self, ln, rn, scope, exclude);
    const raw_needle = ops[0];
    const raw_haystack = ops[1];
    if (raw_needle.isUndefined() or raw_haystack.isUndefined())
        return undefinedErr(self, "undefined value in 'in' operation", ln, rn, raw_needle, raw_haystack, span);

    const needle = raw_needle.unwrapTransparent();
    const haystack = raw_haystack.unwrapTransparent();

    return switch (haystack) {
        .list => |l| blk: {
            if (l.elements.len > 0 and !needle.isNull()) {
                if (firstNonNull(l.elements)) |fnn| {
                    if (!h.sameCategory(needle, fnn))
                        return self.typeErrSpan("'in' value and list element types must match", span);
                    if (needle == .integer and fnn == .integer)
                        if (needle.integer.explicit or fnn.integer.explicit)
                            if (!h.intTypesMatch(needle.integer.type_ann, fnn.integer.type_ann))
                                return self.typeErrSpan("'in' integer type mismatch", span);
                    if (needle == .enum_val and fnn == .enum_val) {
                        const n_tn = needle.enum_val.type_name;
                        const e_tn = fnn.enum_val.type_name;
                        if (n_tn != null and e_tn != null)
                            if (!std.mem.eql(u8, n_tn.?, e_tn.?))
                                return self.typeErrSpan("'in' enum type mismatch", span);
                    }
                }
            }
            for (l.elements) |e| {
                if (e.isUndefined()) continue;
                if (h.runtimeEqual(needle, e)) break :blk Value.boolean(true);
            }
            break :blk Value.boolean(false);
        },
        .tuple => |t| blk: {
            // Tuple: heterogeneous — type mismatch elements are skipped, no error
            for (t.elements) |e| {
                if (e.isUndefined()) continue;
                if (!h.sameCategory(needle, e)) continue;
                if (h.runtimeEqual(needle, e)) break :blk Value.boolean(true);
            }
            break :blk Value.boolean(false);
        },
        .struct_val => |s| blk: {
            // Struct: value membership (not key)
            for (s.values) |v| {
                if (v.isUndefined()) continue;
                if (!h.sameCategory(needle, v)) continue;
                if (h.runtimeEqual(needle, v)) break :blk Value.boolean(true);
            }
            break :blk Value.boolean(false);
        },
        else => self.typeErrSpan("'in' operator requires list, tuple, or struct", span),
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
