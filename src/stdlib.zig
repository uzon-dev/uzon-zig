const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");

const EvalError = Evaluator.EvalError;

/// Dispatch a standard library call (§8).
pub fn evalStdlibCall(self: *Evaluator, func_name: []const u8, arg_nodes: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    // Evaluate arguments
    const args = self.allocator.alloc(Value, arg_nodes.len) catch return error.OutOfMemory;
    for (arg_nodes, 0..) |an, i| args[i] = try self.evalNode(an, scope, exclude);

    if (std.mem.eql(u8, func_name, "length")) return stdLength(self, args, span);
    if (std.mem.eql(u8, func_name, "keys")) return stdKeys(self, args, span);
    if (std.mem.eql(u8, func_name, "values")) return stdValues(self, args, span);
    if (std.mem.eql(u8, func_name, "contains")) return stdContains(self, args, span);
    if (std.mem.eql(u8, func_name, "unique")) return stdUnique(self, args, span);
    if (std.mem.eql(u8, func_name, "reverse")) return stdReverse(self, args, span);
    if (std.mem.eql(u8, func_name, "flatten")) return stdFlatten(self, args, span);
    if (std.mem.eql(u8, func_name, "range")) return stdRange(self, args, span);
    if (std.mem.eql(u8, func_name, "enumerate")) return stdEnumerate(self, args, span);
    if (std.mem.eql(u8, func_name, "zip")) return stdZip(self, args, span);
    if (std.mem.eql(u8, func_name, "map")) return stdMap(self, args, scope, exclude, arg_nodes, span);
    if (std.mem.eql(u8, func_name, "filter")) return stdFilter(self, args, scope, exclude, arg_nodes, span);
    if (std.mem.eql(u8, func_name, "fold")) return stdFold(self, args, scope, exclude, arg_nodes, span);
    if (std.mem.eql(u8, func_name, "sort")) return stdSort(self, args, span);
    if (std.mem.eql(u8, func_name, "min")) return stdMin(self, args, span);
    if (std.mem.eql(u8, func_name, "max")) return stdMax(self, args, span);
    if (std.mem.eql(u8, func_name, "sum")) return stdSum(self, args, span);
    if (std.mem.eql(u8, func_name, "abs")) return stdAbs(self, args, span);

    return self.typeErr("unknown standard library function", span.line, span.col);
}

fn expectArgs(self: *Evaluator, args: []const Value, expected: usize, span: Ast.Span) EvalError!void {
    if (args.len != expected) return self.typeErr("wrong number of arguments to stdlib function", span.line, span.col);
}

fn stdLength(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .string => |s| Value.int(@intCast(s.len)),
        .list => |l| Value.int(@intCast(l.elements.len)),
        .tuple => |t| Value.int(@intCast(t.elements.len)),
        .struct_val => |sv| Value.int(@intCast(sv.keys.len)),
        else => self.typeErr("std.length requires string, list, tuple, or struct", span.line, span.col),
    };
}

fn stdKeys(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const s = switch (args[0]) {
        .struct_val => |sv| sv,
        else => return self.typeErr("std.keys requires struct", span.line, span.col),
    };
    const elems = try self.allocator.alloc(Value, s.keys.len);
    for (s.keys, 0..) |k, i| elems[i] = Value.str(k);
    return Value{ .list = .{ .elements = elems, .element_type = "string" } };
}

fn stdValues(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const s = switch (args[0]) {
        .struct_val => |sv| sv,
        else => return self.typeErr("std.values requires struct", span.line, span.col),
    };
    const elems = try self.allocator.alloc(Value, s.values.len);
    @memcpy(elems, s.values);
    return Value{ .list = .{ .elements = elems } };
}

fn stdContains(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    return switch (args[0]) {
        .string => |haystack| switch (args[1]) {
            .string => |needle| Value.boolean(std.mem.indexOf(u8, haystack, needle) != null),
            else => self.typeErr("std.contains: string requires string argument", span.line, span.col),
        },
        .list => |l| blk: {
            const h_ = @import("eval_helpers.zig");
            for (l.elements) |e| if (h_.runtimeEqual(e, args[1])) break :blk Value.boolean(true);
            break :blk Value.boolean(false);
        },
        else => self.typeErr("std.contains requires string or list", span.line, span.col),
    };
}

fn stdUnique(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.unique requires list", span.line, span.col),
    };
    const h_ = @import("eval_helpers.zig");
    var result = std.ArrayListUnmanaged(Value){};
    for (l.elements) |elem| {
        var found = false;
        for (result.items) |existing| if (h_.runtimeEqual(elem, existing)) {
            found = true;
            break;
        };
        if (!found) result.append(self.allocator, elem) catch return error.OutOfMemory;
    }
    return Value{ .list = .{ .elements = result.items, .element_type = l.element_type } };
}

fn stdReverse(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .list => |l| blk: {
            const elems = try self.allocator.alloc(Value, l.elements.len);
            for (l.elements, 0..) |_, i| elems[i] = l.elements[l.elements.len - 1 - i];
            break :blk Value{ .list = .{ .elements = elems, .element_type = l.element_type } };
        },
        .string => |s| blk: {
            const buf = try self.allocator.alloc(u8, s.len);
            for (s, 0..) |_, i| buf[i] = s[s.len - 1 - i];
            break :blk Value.str(buf);
        },
        else => self.typeErr("std.reverse requires list or string", span.line, span.col),
    };
}

fn stdFlatten(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.flatten requires list", span.line, span.col),
    };
    var result = std.ArrayListUnmanaged(Value){};
    for (l.elements) |elem| {
        switch (elem) {
            .list => |inner| for (inner.elements) |e| result.append(self.allocator, e) catch return error.OutOfMemory,
            else => result.append(self.allocator, elem) catch return error.OutOfMemory,
        }
    }
    return Value{ .list = .{ .elements = result.items } };
}

fn stdRange(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    if (args.len < 1 or args.len > 3) return self.typeErr("std.range requires 1-3 arguments", span.line, span.col);
    var start: i128 = 0;
    var end: i128 = undefined;
    var step: i128 = 1;
    if (args.len == 1) {
        end = switch (args[0]) {
            .integer => |i| i.value,
            else => return self.typeErr("std.range requires integer arguments", span.line, span.col),
        };
    } else {
        start = switch (args[0]) {
            .integer => |i| i.value,
            else => return self.typeErr("std.range requires integer arguments", span.line, span.col),
        };
        end = switch (args[1]) {
            .integer => |i| i.value,
            else => return self.typeErr("std.range requires integer arguments", span.line, span.col),
        };
        if (args.len == 3) {
            step = switch (args[2]) {
                .integer => |i| i.value,
                else => return self.typeErr("std.range requires integer arguments", span.line, span.col),
            };
        }
    }
    if (step == 0) return self.rtErr("std.range step cannot be zero", span.line, span.col);
    var result = std.ArrayListUnmanaged(Value){};
    var i = start;
    if (step > 0) {
        while (i < end) : (i += step)
            result.append(self.allocator, Value.int(i)) catch return error.OutOfMemory;
    } else {
        while (i > end) : (i += step)
            result.append(self.allocator, Value.int(i)) catch return error.OutOfMemory;
    }
    return Value{ .list = .{ .elements = result.items } };
}

fn stdEnumerate(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.enumerate requires list", span.line, span.col),
    };
    const elems = try self.allocator.alloc(Value, l.elements.len);
    for (l.elements, 0..) |elem, i| {
        const pair = try self.allocator.alloc(Value, 2);
        pair[0] = Value.int(@intCast(i));
        pair[1] = elem;
        elems[i] = Value{ .tuple = .{ .elements = pair } };
    }
    return Value{ .list = .{ .elements = elems } };
}

fn stdZip(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const a = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.zip requires list arguments", span.line, span.col),
    };
    const b = switch (args[1]) {
        .list => |ll| ll,
        else => return self.typeErr("std.zip requires list arguments", span.line, span.col),
    };
    const len = @min(a.elements.len, b.elements.len);
    const elems = try self.allocator.alloc(Value, len);
    for (0..len) |i| {
        const pair = try self.allocator.alloc(Value, 2);
        pair[0] = a.elements[i];
        pair[1] = b.elements[i];
        elems[i] = Value{ .tuple = .{ .elements = pair } };
    }
    return Value{ .list = .{ .elements = elems } };
}

fn stdMap(self: *Evaluator, args: []const Value, scope: *Scope, exclude: ?[]const u8, arg_nodes: []const *const Ast.Node, span: Ast.Span) EvalError!Value {
    _ = scope;
    _ = exclude;
    _ = arg_nodes;
    try expectArgs(self, args, 2, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.map requires list as first argument", span.line, span.col),
    };
    const func = switch (args[1]) {
        .function => |f| f,
        else => return self.typeErr("std.map requires function as second argument", span.line, span.col),
    };
    const elems = try self.allocator.alloc(Value, l.elements.len);
    for (l.elements, 0..) |elem, i| {
        elems[i] = try callFunction(self, func, &.{elem}, span);
    }
    return Value{ .list = .{ .elements = elems } };
}

fn stdFilter(self: *Evaluator, args: []const Value, scope: *Scope, exclude: ?[]const u8, arg_nodes: []const *const Ast.Node, span: Ast.Span) EvalError!Value {
    _ = scope;
    _ = exclude;
    _ = arg_nodes;
    try expectArgs(self, args, 2, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.filter requires list as first argument", span.line, span.col),
    };
    const func = switch (args[1]) {
        .function => |f| f,
        else => return self.typeErr("std.filter requires function as second argument", span.line, span.col),
    };
    var result = std.ArrayListUnmanaged(Value){};
    for (l.elements) |elem| {
        const r = try callFunction(self, func, &.{elem}, span);
        switch (r) {
            .bool_val => |bv| {
                if (bv) result.append(self.allocator, elem) catch return error.OutOfMemory;
            },
            else => return self.typeErr("std.filter predicate must return bool", span.line, span.col),
        }
    }
    return Value{ .list = .{ .elements = result.items, .element_type = l.element_type } };
}

fn stdFold(self: *Evaluator, args: []const Value, scope: *Scope, exclude: ?[]const u8, arg_nodes: []const *const Ast.Node, span: Ast.Span) EvalError!Value {
    _ = scope;
    _ = exclude;
    _ = arg_nodes;
    if (args.len != 3) return self.typeErr("std.fold requires 3 arguments", span.line, span.col);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.fold requires list as first argument", span.line, span.col),
    };
    var acc = args[1];
    const func = switch (args[2]) {
        .function => |f| f,
        else => return self.typeErr("std.fold requires function as third argument", span.line, span.col),
    };
    for (l.elements) |elem| {
        acc = try callFunction(self, func, &.{ acc, elem }, span);
    }
    return acc;
}

fn stdSort(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.sort requires list", span.line, span.col),
    };
    if (l.elements.len <= 1) return args[0];
    const elems = try self.allocator.alloc(Value, l.elements.len);
    @memcpy(elems, l.elements);

    // Sort by value — integers, floats, strings
    const first = l.elements[0];
    switch (first) {
        .integer => std.mem.sort(Value, elems, {}, struct {
            fn lessThan(_: void, a: Value, b: Value) bool {
                return a.integer.value < b.integer.value;
            }
        }.lessThan),
        .float_val => std.mem.sort(Value, elems, {}, struct {
            fn lessThan(_: void, a: Value, b: Value) bool {
                return a.float_val.value < b.float_val.value;
            }
        }.lessThan),
        .string => std.mem.sort(Value, elems, {}, struct {
            fn lessThan(_: void, a: Value, b: Value) bool {
                return std.mem.order(u8, a.string, b.string) == .lt;
            }
        }.lessThan),
        else => return self.typeErr("std.sort requires list of comparable values", span.line, span.col),
    }
    return Value{ .list = .{ .elements = elems, .element_type = l.element_type } };
}

fn stdMin(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.min requires list", span.line, span.col),
    };
    if (l.elements.len == 0) return self.rtErr("std.min on empty list", span.line, span.col);
    var result = l.elements[0];
    for (l.elements[1..]) |e| {
        switch (result) {
            .integer => |ri| if (e == .integer and e.integer.value < ri.value) {
                result = e;
            },
            .float_val => |rf| if (e == .float_val and e.float_val.value < rf.value) {
                result = e;
            },
            else => return self.typeErr("std.min requires list of numbers", span.line, span.col),
        }
    }
    return result;
}

fn stdMax(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.max requires list", span.line, span.col),
    };
    if (l.elements.len == 0) return self.rtErr("std.max on empty list", span.line, span.col);
    var result = l.elements[0];
    for (l.elements[1..]) |e| {
        switch (result) {
            .integer => |ri| if (e == .integer and e.integer.value > ri.value) {
                result = e;
            },
            .float_val => |rf| if (e == .float_val and e.float_val.value > rf.value) {
                result = e;
            },
            else => return self.typeErr("std.max requires list of numbers", span.line, span.col),
        }
    }
    return result;
}

fn stdSum(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.sum requires list", span.line, span.col),
    };
    if (l.elements.len == 0) return Value.int(0);
    return switch (l.elements[0]) {
        .integer => blk: {
            var sum: i128 = 0;
            for (l.elements) |e| {
                if (e != .integer) return self.typeErr("std.sum requires homogeneous numeric list", span.line, span.col);
                sum = std.math.add(i128, sum, e.integer.value) catch return self.rtErr("integer overflow in std.sum", span.line, span.col);
            }
            break :blk Value.int(sum);
        },
        .float_val => blk: {
            var sum: f64 = 0;
            for (l.elements) |e| {
                if (e != .float_val) return self.typeErr("std.sum requires homogeneous numeric list", span.line, span.col);
                sum += e.float_val.value;
            }
            break :blk Value.float(sum);
        },
        else => self.typeErr("std.sum requires list of numbers", span.line, span.col),
    };
}

fn stdAbs(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .integer => |i| Value{ .integer = .{ .value = @max(i.value, -i.value), .type_ann = i.type_ann, .explicit = i.explicit } },
        .float_val => |f| Value{ .float_val = .{ .value = @abs(f.value), .type_ann = f.type_ann, .explicit = f.explicit } },
        else => self.typeErr("std.abs requires numeric argument", span.line, span.col),
    };
}

// ── Function call helper ────────────────────────────────────

fn callFunction(self: *Evaluator, func: val.Function, args: []const Value, span: Ast.Span) EvalError!Value {
    const h_ = @import("eval_helpers.zig");

    // Recursion detection
    for (self.call_stack.items) |active| if (active == func.body_expr) return self.typeErr("recursive function call detected", span.line, span.col);
    self.call_stack.append(self.allocator, func.body_expr) catch return error.OutOfMemory;
    defer _ = self.call_stack.pop();

    var func_scope = @import("Scope.zig").init(self.allocator);
    for (func.captured_keys, func.captured_values) |key, v| try func_scope.define(key, v);
    for (func.captured_types) |td| try func_scope.defineType(td.name, td);

    for (func.params, 0..) |param, idx| {
        if (idx < args.len) {
            var arg = args[idx];
            if (param.type_expr.data == .name) {
                const tn = param.type_expr.data.name;
                if (!arg.isNull() and !arg.isUndefined()) {
                    arg = h_.adoptToType(arg, tn);
                    if (!h_.valueMatchesType(arg, tn))
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
            result = h_.adoptToType(result, rtn);
            if (!h_.valueMatchesType(result, rtn))
                return self.typeErr("function return type mismatch", span.line, span.col);
        }
    }
    return result;
}
