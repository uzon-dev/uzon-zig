const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const IntegerType = val.IntegerType;
const Scope = @import("Scope.zig");
const h = @import("eval_helpers.zig");

// ── Helper: construct AST node on arena ───────────────────

fn node(a: std.mem.Allocator, kind: Ast.Node.Kind) !*const Ast.Node {
    const n = try a.create(Ast.Node);
    n.* = .{ .kind = kind, .span = .{ .line = 1, .col = 1 } };
    return n;
}

fn intLit(a: std.mem.Allocator, text: []const u8) !*const Ast.Node {
    return node(a, .{ .integer_literal = .{ .value = text } });
}

fn floatLit(a: std.mem.Allocator, text: []const u8) !*const Ast.Node {
    return node(a, .{ .float_literal = .{ .value = text } });
}

fn strLit(a: std.mem.Allocator, text: []const u8) !*const Ast.Node {
    const parts = try a.alloc(Ast.StringPart, 1);
    parts[0] = .{ .literal = text };
    return node(a, .{ .string_literal = .{ .parts = parts } });
}

fn binOp(a: std.mem.Allocator, op: Ast.BinaryOp, left: *const Ast.Node, right: *const Ast.Node) !*const Ast.Node {
    return node(a, .{ .binary_op = .{ .op = op, .left = left, .right = right } });
}

fn binding(name: []const u8, value: *const Ast.Node) Ast.Binding {
    return .{ .name = name, .value = value, .called = null, .is_are = false, .list_type_annotation = null, .span = .{ .line = 1, .col = 1 } };
}

fn eval(a: std.mem.Allocator, n: *const Ast.Node) !Value {
    var ev = Evaluator.init(a);
    var scope = Scope.init(a);
    return ev.evalNode(n, &scope, null);
}

fn evalDoc(a: std.mem.Allocator, bindings: []const Ast.Binding) !Value {
    var ev = Evaluator.init(a);
    return ev.evalDocument(.{ .bindings = bindings, .span = .{ .line = 1, .col = 1 } });
}

// ── Tests ──────────────────────────────────────────────────

test "parse integer literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(@as(i256, 42), try h.parseIntegerText(a, "42"));
    try std.testing.expectEqual(@as(i256, -42), try h.parseIntegerText(a, "-42"));
    try std.testing.expectEqual(@as(i256, 255), try h.parseIntegerText(a, "0xFF"));
    try std.testing.expectEqual(@as(i256, 255), try h.parseIntegerText(a, "0xff"));
    try std.testing.expectEqual(@as(i256, -255), try h.parseIntegerText(a, "-0xff"));
    try std.testing.expectEqual(@as(i256, 63), try h.parseIntegerText(a, "0o77"));
    try std.testing.expectEqual(@as(i256, 10), try h.parseIntegerText(a, "0b1010"));
    try std.testing.expectEqual(@as(i256, 1000000), try h.parseIntegerText(a, "1_000_000"));
    try std.testing.expectEqual(@as(i256, 0), try h.parseIntegerText(a, "0"));
}

test "parse float literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectApproxEqAbs(@as(f64, 3.14), try h.parseFloatText(a, "3.14"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -3.14), try h.parseFloatText(a, "-3.14"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e10), try h.parseFloatText(a, "1.0e10"), 1.0);
}

test "eval simple integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try eval(a, try binOp(a, .add, try intLit(a, "2"), try intLit(a, "3")));
    try std.testing.expectEqual(@as(i256, 5), result.integer.value);
}

test "eval integer division truncates toward zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try eval(a, try binOp(a, .div, try intLit(a, "-10"), try intLit(a, "3")));
    try std.testing.expectEqual(@as(i256, -3), result.integer.value);
}

test "eval modulo follows dividend sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try eval(a, try binOp(a, .mod_, try intLit(a, "-10"), try intLit(a, "3")));
    try std.testing.expectEqual(@as(i256, -1), result.integer.value);
}

test "eval division by zero is runtime error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.UzonRuntime, eval(a, try binOp(a, .div, try intLit(a, "1"), try intLit(a, "0"))));
}

test "eval or_else with undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // §4.5: literal undefined is not allowed as an or_else operand.
    const n = try node(a, .{ .or_else = .{ .left = try node(a, .undefined_literal), .right = try intLit(a, "42") } });
    try std.testing.expectError(error.UzonType, eval(a, n));
}

test "eval or_else with null passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = try node(a, .{ .or_else = .{ .left = try node(a, .null_literal), .right = try intLit(a, "42") } });
    const result = try eval(a, n);
    try std.testing.expect(result.isNull());
}

test "eval null member access is type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = try node(a, .{ .member_access = .{ .object = try node(a, .null_literal), .member = "x" } });
    try std.testing.expectError(error.UzonType, eval(a, n));
}

test "eval undefined member access propagates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = try node(a, .{ .member_access = .{ .object = try node(a, .undefined_literal), .member = "x" } });
    const result = try eval(a, n);
    try std.testing.expect(result.isUndefined());
}

test "eval negate undefined is runtime error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = try node(a, .{ .unary_op = .{ .op = .negate, .operand = try node(a, .undefined_literal) } });
    try std.testing.expectError(error.UzonRuntime, eval(a, n));
}

test "eval if expression with speculative eval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // if true then 1 else (1 / 0) → 1 (div by zero suppressed)
    const n = try node(a, .{ .if_expr = .{
        .condition = try node(a, .{ .bool_literal = .{ .value = true } }),
        .then_branch = try intLit(a, "1"),
        .else_branch = try binOp(a, .div, try intLit(a, "1"), try intLit(a, "0")),
    } });
    const result = try eval(a, n);
    try std.testing.expectEqual(@as(i256, 1), result.integer.value);
}

test "eval struct literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = try a.alloc(Ast.Binding, 2);
    fields[0] = binding("x", try intLit(a, "1"));
    fields[1] = binding("y", try intLit(a, "2"));

    const result = try eval(a, try node(a, .{ .struct_literal = .{ .fields = fields } }));
    try std.testing.expectEqual(@as(i256, 1), result.struct_val.get("x").?.integer.value);
    try std.testing.expectEqual(@as(i256, 2), result.struct_val.get("y").?.integer.value);
}

test "eval forward references in bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const b_ref = try node(a, .{ .identifier = .{ .name = "b" } });
    const bindings = try a.alloc(Ast.Binding, 2);
    bindings[0] = binding("a", try binOp(a, .add, b_ref, try intLit(a, "1")));
    bindings[1] = binding("b", try intLit(a, "10"));

    const result = try evalDoc(a, bindings);
    try std.testing.expectEqual(@as(i256, 11), result.struct_val.get("a").?.integer.value);
    try std.testing.expectEqual(@as(i256, 10), result.struct_val.get("b").?.integer.value);
}

test "eval self-exclusion rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const x_ref = try node(a, .{ .identifier = .{ .name = "x" } });
    const or_else = try node(a, .{ .or_else = .{ .left = x_ref, .right = try intLit(a, "42") } });
    const bindings = try a.alloc(Ast.Binding, 1);
    bindings[0] = binding("x", or_else);

    const result = try evalDoc(a, bindings);
    try std.testing.expectEqual(@as(i256, 42), result.struct_val.get("x").?.integer.value);
}

test "eval deep equality" {
    const a_val = Value{ .struct_val = .{
        .keys = &.{ "x", "y" },
        .values = &.{ Value.int(1), Value.int(2) },
    } };
    const b_val = Value{ .struct_val = .{
        .keys = &.{ "y", "x" },
        .values = &.{ Value.int(2), Value.int(1) },
    } };
    try std.testing.expect(h.valuesEqual(a_val, b_val));

    // NaN: structural equality vs runtime equality
    const nan_val = Value{ .float_val = .{ .value = std.math.nan(f64) } };
    try std.testing.expect(h.valuesEqual(nan_val, nan_val));
    try std.testing.expect(!h.runtimeEqual(nan_val, nan_val));
}

test "eval cross-category int to float adoption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 3.14 + 2 → 5.14
    const result = try eval(a, try binOp(a, .add, try floatLit(a, "3.14"), try intLit(a, "2")));
    try std.testing.expectApproxEqAbs(@as(f64, 5.14), result.float_val.value, 0.001);
}

test "eval string concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try eval(a, try binOp(a, .concat, try strLit(a, "hello "), try strLit(a, "world")));
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "eval logical short-circuit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try eval(a, try binOp(a, .@"or", try node(a, .{ .bool_literal = .{ .value = true } }), try node(a, .{ .bool_literal = .{ .value = false } })));
    try std.testing.expectEqual(true, result.bool_val);
}

test "eval type annotation as i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "i32" }, .span = .{ .line = 1, .col = 6 } };
    const result = try eval(a, try node(a, .{ .type_annotation = .{ .expr = try intLit(a, "42"), .type_expr = te } }));
    try std.testing.expectEqual(@as(i256, 42), result.integer.value);
    try std.testing.expect(result.integer.explicit);
    try std.testing.expectEqual(IntegerType{ .signed = 32 }, result.integer.type_ann);
}

test "eval type annotation overflow is type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "u8" }, .span = .{ .line = 1, .col = 5 } };
    try std.testing.expectError(error.UzonType, eval(a, try node(a, .{ .type_annotation = .{ .expr = try intLit(a, "256"), .type_expr = te } })));
}

test "eval to string conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "string" }, .span = .{ .line = 1, .col = 6 } };
    const result = try eval(a, try node(a, .{ .conversion = .{ .expr = try intLit(a, "42"), .type_expr = te } }));
    try std.testing.expectEqualStrings("42", result.string);
}

test "eval to integer from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "u8" }, .span = .{ .line = 1, .col = 7 } };
    const result = try eval(a, try node(a, .{ .conversion = .{ .expr = try strLit(a, "255"), .type_expr = te } }));
    try std.testing.expectEqual(@as(i256, 255), result.integer.value);
    try std.testing.expectEqual(IntegerType{ .unsigned = 8 }, result.integer.type_ann);
}

test "eval to integer from hex string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "i32" }, .span = .{ .line = 1, .col = 9 } };
    const result = try eval(a, try node(a, .{ .conversion = .{ .expr = try strLit(a, "-0xff"), .type_expr = te } }));
    try std.testing.expectEqual(@as(i256, -255), result.integer.value);
}

test "eval struct with override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base_fields = try a.alloc(Ast.Binding, 2);
    base_fields[0] = binding("x", try intLit(a, "1"));
    base_fields[1] = binding("y", try intLit(a, "2"));

    const over_fields = try a.alloc(Ast.Binding, 1);
    over_fields[0] = binding("x", try intLit(a, "10"));

    const result = try eval(a, try node(a, .{ .struct_override = .{
        .base = try node(a, .{ .struct_literal = .{ .fields = base_fields } }),
        .overrides = try node(a, .{ .struct_literal = .{ .fields = over_fields } }),
    } }));
    try std.testing.expectEqual(@as(i256, 10), result.struct_val.get("x").?.integer.value);
    try std.testing.expectEqual(@as(i256, 2), result.struct_val.get("y").?.integer.value);
}

test "eval struct with cannot add new field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base_fields = try a.alloc(Ast.Binding, 1);
    base_fields[0] = binding("x", try intLit(a, "1"));

    const over_fields = try a.alloc(Ast.Binding, 1);
    over_fields[0] = binding("z", try intLit(a, "3"));

    try std.testing.expectError(error.UzonType, eval(a, try node(a, .{ .struct_override = .{
        .base = try node(a, .{ .struct_literal = .{ .fields = base_fields } }),
        .overrides = try node(a, .{ .struct_literal = .{ .fields = over_fields } }),
    } })));
}

test "eval struct plus extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base_fields = try a.alloc(Ast.Binding, 1);
    base_fields[0] = binding("x", try intLit(a, "1"));

    const ext_fields = try a.alloc(Ast.Binding, 1);
    ext_fields[0] = binding("y", try intLit(a, "2"));

    const result = try eval(a, try node(a, .{ .struct_extension = .{
        .base = try node(a, .{ .struct_literal = .{ .fields = base_fields } }),
        .extension = try node(a, .{ .struct_literal = .{ .fields = ext_fields } }),
    } }));
    try std.testing.expectEqual(@as(i256, 1), result.struct_val.get("x").?.integer.value);
    try std.testing.expectEqual(@as(i256, 2), result.struct_val.get("y").?.integer.value);
}

test "eval undefined propagates through to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const te = Ast.TypeExpr{ .data = .{ .name = "i32" }, .span = .{ .line = 1, .col = 15 } };
    const result = try eval(a, try node(a, .{ .conversion = .{ .expr = try node(a, .undefined_literal), .type_expr = te } }));
    try std.testing.expect(result.isUndefined());
}

test "eval compound to string is type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_fields = try a.alloc(Ast.Binding, 0);
    const te = Ast.TypeExpr{ .data = .{ .name = "string" }, .span = .{ .line = 1, .col = 5 } };
    try std.testing.expectError(error.UzonType, eval(a, try node(a, .{ .conversion = .{
        .expr = try node(a, .{ .struct_literal = .{ .fields = empty_fields } }),
        .type_expr = te,
    } })));
}

test "eval in operator for lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const elements = try a.alloc(*const Ast.Node, 3);
    elements[0] = try intLit(a, "1");
    elements[1] = try intLit(a, "2");
    elements[2] = try intLit(a, "3");
    const list = try node(a, .{ .list_literal = .{ .elements = elements } });

    const result = try eval(a, try binOp(a, .in_, try intLit(a, "2"), list));
    try std.testing.expectEqual(true, result.bool_val);
}

test "eval list member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const elements = try a.alloc(*const Ast.Node, 3);
    elements[0] = try intLit(a, "10");
    elements[1] = try intLit(a, "20");
    elements[2] = try intLit(a, "30");
    const list = try node(a, .{ .list_literal = .{ .elements = elements } });
    const n = try node(a, .{ .member_access = .{ .object = list, .member = "second" } });

    const result = try eval(a, n);
    try std.testing.expectEqual(@as(i256, 20), result.integer.value);
}

// ── Multi-error collection tests (via parse API) ────────

const root = @import("root.zig");

test "multi-error: chained concat reports both undefined names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = root.parse(a, "label is first_name ++ \" \" ++ last_name");
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 2);
            try std.testing.expectEqual(@as(u32, 10), errs[0].location.col); // first_name
            try std.testing.expectEqual(@as(u32, 31), errs[1].location.col); // last_name
        },
    }
}

test "multi-error: both undefined in arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = root.parse(a, "result is aaa + bbb");
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 2);
            var found_aaa = false;
            var found_bbb = false;
            for (errs) |e| {
                if (e.location.col == 11) found_aaa = true; // aaa
                if (e.location.col == 17) found_bbb = true; // bbb
            }
            try std.testing.expect(found_aaa);
            try std.testing.expect(found_bbb);
        },
    }
}

test "multi-error: function call with multiple undefined args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\greet is function a as string, b as string, c as string returns string { a ++ " " ++ b ++ " " ++ c }
        \\result is greet(xxx, "hello", yyy)
    ;
    const result = root.parse(a, src);
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 2);
            // Both xxx and yyy should be reported at their locations
            try std.testing.expectEqual(@as(u32, 17), errs[0].location.col); // xxx
            try std.testing.expectEqual(@as(u32, 31), errs[1].location.col); // yyy
        },
    }
}

test "multi-error: stdlib call with undefined arg points to arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "evens is std.filter(numbers, function n as i64 returns bool { n % 2 is 0 })";
    const result = root.parse(a, src);
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            // Error should point to 'numbers' (col 21), not the opening paren
            try std.testing.expectEqual(@as(u32, 21), errs[0].location.col);
        },
    }
}

test "error location: return type mismatch points to body expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\f1 is function t as (i32, string) returns i32 {
        \\    t.second ** t.first
        \\}
        \\
        \\f1_result is f1((2, "hello"))
    ;
    const result = root.parse(a, src);
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            // Error should point to body expression (line 2), not call site (line 5)
            try std.testing.expectEqual(@as(u32, 2), errs[0].location.line);
        },
    }
}

test "multi-error: function body error points inside body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Direct call: body references 'unknown' — error should point inside body
    const src1 = "double is function n as i64 returns i64 { n + unknown }\nresult is double(1 as i64)";
    const r1 = root.parse(a, src1);
    switch (r1) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            try std.testing.expectEqual(@as(u32, 47), errs[0].location.col); // 'unknown' inside body
        },
    }

    // HOF: same function body error via std.map
    const src2 =
        \\nums is [1 as i64, 2 as i64]
        \\result is std.map(nums, function n as i64 returns i64 { n + unknown })
    ;
    const r2 = root.parse(a, src2);
    switch (r2) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            try std.testing.expectEqual(@as(u32, 61), errs[0].location.col); // 'unknown' inside body
        },
    }
}

test "error location: type error spans entire expression range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // true + 42 — type error should span from true (col 11) to 42 (col 18+2=20)
    const result = root.parse(a, "result is true + 42");
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            try std.testing.expectEqual(@as(u32, 11), errs[0].location.col); // start: true
            try std.testing.expectEqual(@as(u32, 1), errs[0].location.line);
            try std.testing.expectEqual(@as(u32, 1), errs[0].location.end_line); // same line
            try std.testing.expectEqual(@as(u32, 20), errs[0].location.end_col); // end: col(18) + len("42")
        },
    }
}

test "error location: concat type error spans full expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // true ++ 42 — should span from true to 42
    const result = root.parse(a, "result is true ++ 42");
    switch (result) {
        .value => return error.TestUnexpectedResult,
        .errors => |errs| {
            try std.testing.expect(errs.len >= 1);
            try std.testing.expectEqual(@as(u32, 11), errs[0].location.col); // start: true
            try std.testing.expectEqual(@as(u32, 1), errs[0].location.end_line);
            try std.testing.expect(errs[0].location.end_col > 11); // end extends past start
        },
    }
}
