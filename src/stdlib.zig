const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");

const h_ = @import("eval_helpers.zig");
const EvalError = Evaluator.EvalError;

/// Dispatch a standard library call (§8).
pub fn evalStdlibCall(self: *Evaluator, func_name: []const u8, arg_nodes: []const *const Ast.Node, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    // Evaluate arguments
    const args = self.allocator.alloc(Value, arg_nodes.len) catch return error.OutOfMemory;
    for (arg_nodes, 0..) |an, i| args[i] = try self.evalNode(an, scope, exclude);

    // Validate no undefined args (§8 bug pattern #6)
    for (args) |a| {
        if (a.isUndefined()) return self.rtErr("undefined argument to stdlib function", span.line, span.col);
    }

    if (std.mem.eql(u8, func_name, "len")) return stdLen(self, args, span);
    if (std.mem.eql(u8, func_name, "get")) return stdGet(self, args, span);
    if (std.mem.eql(u8, func_name, "hasKey")) return stdHasKey(self, args, span);
    if (std.mem.eql(u8, func_name, "keys")) return stdKeys(self, args, span);
    if (std.mem.eql(u8, func_name, "values")) return stdValues(self, args, span);
    if (std.mem.eql(u8, func_name, "join")) return stdJoin(self, args, span);
    if (std.mem.eql(u8, func_name, "split")) return stdSplit(self, args, span);
    if (std.mem.eql(u8, func_name, "trim")) return stdTrim(self, args, span);
    if (std.mem.eql(u8, func_name, "upper")) return stdUpper(self, args, span);
    if (std.mem.eql(u8, func_name, "lower")) return stdLower(self, args, span);
    if (std.mem.eql(u8, func_name, "replace")) return stdReplace(self, args, span);
    if (std.mem.eql(u8, func_name, "isNan")) return stdIsNan(self, args, span);
    if (std.mem.eql(u8, func_name, "isInf")) return stdIsInf(self, args, span);
    if (std.mem.eql(u8, func_name, "isFinite")) return stdIsFinite(self, args, span);
    if (std.mem.eql(u8, func_name, "contains")) return stdContains(self, args, span);
    if (std.mem.eql(u8, func_name, "startsWith")) return stdStartsWith(self, args, span);
    if (std.mem.eql(u8, func_name, "endsWith")) return stdEndsWith(self, args, span);
    if (std.mem.eql(u8, func_name, "reverse")) return stdReverse(self, args, span);
    if (std.mem.eql(u8, func_name, "all")) return stdAll(self, args, span);
    if (std.mem.eql(u8, func_name, "any")) return stdAny(self, args, span);
    if (std.mem.eql(u8, func_name, "map")) return stdMap(self, args, span);
    if (std.mem.eql(u8, func_name, "filter")) return stdFilter(self, args, span);
    if (std.mem.eql(u8, func_name, "reduce")) return stdReduce(self, args, span);
    if (std.mem.eql(u8, func_name, "sort")) return stdSort(self, args, span);

    return self.typeErr("unknown standard library function", span.line, span.col);
}

fn expectArgs(self: *Evaluator, args: []const Value, expected: usize, span: Ast.Span) EvalError!void {
    if (args.len != expected) return self.typeErr("wrong number of arguments to stdlib function", span.line, span.col);
}

fn stdLen(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const len: i128 = switch (args[0]) {
        .string => |s| blk: {
            // Count Unicode scalar values (codepoints), not bytes (§8)
            var count: i128 = 0;
            var view = std.unicode.Utf8View.initUnchecked(s);
            var it = view.iterator();
            while (it.nextCodepoint() != null) count += 1;
            break :blk count;
        },
        .list => |l| @intCast(l.elements.len),
        .tuple => |t| @intCast(t.elements.len),
        .struct_val => |sv| @intCast(sv.keys.len),
        else => return self.typeErr("std.len requires string, list, tuple, or struct", span.line, span.col),
    };
    return Value{ .integer = .{ .value = len, .type_ann = .{ .signed = 64 }, .explicit = true } };
}

fn stdGet(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    return switch (args[0]) {
        .list => |l| switch (args[1]) {
            .integer => |idx| blk: {
                if (idx.value < 0 or idx.value >= @as(i128, @intCast(l.elements.len))) break :blk .undefined;
                break :blk l.elements[@intCast(idx.value)];
            },
            else => self.typeErr("list index must be integer", span.line, span.col),
        },
        .tuple => |t| switch (args[1]) {
            .integer => |idx| blk: {
                if (idx.value < 0 or idx.value >= @as(i128, @intCast(t.elements.len))) break :blk .undefined;
                break :blk t.elements[@intCast(idx.value)];
            },
            else => self.typeErr("tuple index must be integer", span.line, span.col),
        },
        .struct_val => |s| switch (args[1]) {
            .string => |key| if (s.get(key)) |v| v else .undefined,
            else => self.typeErr("struct key must be string", span.line, span.col),
        },
        else => self.typeErr("std.get requires list, tuple, or struct", span.line, span.col),
    };
}

fn stdHasKey(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const s = switch (args[0]) {
        .struct_val => |sv| sv,
        else => return self.typeErr("std.hasKey requires struct as first argument", span.line, span.col),
    };
    const key = switch (args[1]) {
        .string => |k| k,
        else => return self.typeErr("std.hasKey key must be string", span.line, span.col),
    };
    for (s.keys) |k| {
        if (std.mem.eql(u8, key, k)) return Value.boolean(true);
    }
    return Value.boolean(false);
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
    return Value{ .tuple = .{ .elements = elems } };
}

fn stdJoin(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const list = switch (args[0]) {
        .list => |l| l,
        else => return self.typeErr("std.join first argument must be list", span.line, span.col),
    };
    const sep = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.join separator must be string", span.line, span.col),
    };
    if (list.elements.len == 0) return Value.str("");
    var buf = std.ArrayListUnmanaged(u8){};
    for (list.elements, 0..) |e, i| {
        if (i > 0) buf.appendSlice(self.allocator, sep) catch return error.OutOfMemory;
        switch (e) {
            .string => |s| buf.appendSlice(self.allocator, s) catch return error.OutOfMemory,
            else => return self.typeErr("std.join list elements must be strings", span.line, span.col),
        }
    }
    return Value.str(buf.items);
}

fn stdSplit(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.split first argument must be string", span.line, span.col),
    };
    const delim = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.split delimiter must be string", span.line, span.col),
    };

    // Empty input → [""] (bug pattern #4)
    if (str.len == 0) {
        const elems = try self.allocator.alloc(Value, 1);
        elems[0] = Value.str("");
        return Value{ .list = .{ .elements = elems, .element_type = "string" } };
    }

    // Empty delimiter → split into individual codepoints
    if (delim.len == 0) {
        var parts = std.ArrayListUnmanaged(Value){};
        var view = std.unicode.Utf8View.initUnchecked(str);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_slice| {
            const s = try self.allocator.dupe(u8, cp_slice);
            parts.append(self.allocator, Value.str(s)) catch return error.OutOfMemory;
        }
        return Value{ .list = .{ .elements = parts.items, .element_type = "string" } };
    }

    // Normal split
    var parts = std.ArrayListUnmanaged(Value){};
    var rest: []const u8 = str;
    while (std.mem.indexOf(u8, rest, delim)) |idx| {
        const part = try self.allocator.dupe(u8, rest[0..idx]);
        parts.append(self.allocator, Value.str(part)) catch return error.OutOfMemory;
        rest = rest[idx + delim.len ..];
    }
    const last = try self.allocator.dupe(u8, rest);
    parts.append(self.allocator, Value.str(last)) catch return error.OutOfMemory;
    return Value{ .list = .{ .elements = parts.items, .element_type = "string" } };
}

fn stdTrim(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.trim requires string", span.line, span.col),
    };
    return Value.str(std.mem.trim(u8, str, " \t\n\r"));
}

fn stdUpper(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.upper requires string", span.line, span.col),
    };
    var buf = std.ArrayListUnmanaged(u8){};
    var view = std.unicode.Utf8View.initUnchecked(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const mapped = unicodeToUpper(cp);
        var enc: [4]u8 = undefined;
        for (0..mapped.len) |j| {
            const n = std.unicode.utf8Encode(mapped.cps[j], &enc) catch continue;
            buf.appendSlice(self.allocator, enc[0..n]) catch return error.OutOfMemory;
        }
    }
    return Value.str(try buf.toOwnedSlice(self.allocator));
}

fn stdLower(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.lower requires string", span.line, span.col),
    };
    var buf = std.ArrayListUnmanaged(u8){};
    var view = std.unicode.Utf8View.initUnchecked(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const mapped = unicodeToLower(cp);
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(mapped, &enc) catch continue;
        buf.appendSlice(self.allocator, enc[0..n]) catch return error.OutOfMemory;
    }
    return Value.str(try buf.toOwnedSlice(self.allocator));
}

fn stdReplace(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    if (args.len != 3) return self.typeErr("std.replace requires 3 arguments", span.line, span.col);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.replace first argument must be string", span.line, span.col),
    };
    const target = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.replace target must be string", span.line, span.col),
    };
    const replacement = switch (args[2]) {
        .string => |s| s,
        else => return self.typeErr("std.replace replacement must be string", span.line, span.col),
    };
    if (target.len == 0) return Value.str(str);
    var buf = std.ArrayListUnmanaged(u8){};
    var rest: []const u8 = str;
    while (std.mem.indexOf(u8, rest, target)) |idx| {
        buf.appendSlice(self.allocator, rest[0..idx]) catch return error.OutOfMemory;
        buf.appendSlice(self.allocator, replacement) catch return error.OutOfMemory;
        rest = rest[idx + target.len ..];
    }
    buf.appendSlice(self.allocator, rest) catch return error.OutOfMemory;
    return Value.str(buf.items);
}

fn stdIsNan(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .float_val => |f| Value.boolean(std.math.isNan(f.value)),
        else => self.typeErr("std.isNan requires float", span.line, span.col),
    };
}

fn stdIsInf(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .float_val => |f| Value.boolean(std.math.isInf(f.value)),
        else => self.typeErr("std.isInf requires float", span.line, span.col),
    };
}

fn stdIsFinite(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 1, span);
    return switch (args[0]) {
        .float_val => |f| Value.boolean(std.math.isFinite(f.value)),
        else => self.typeErr("std.isFinite requires float", span.line, span.col),
    };
}

fn stdContains(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.contains requires string as first argument", span.line, span.col),
    };
    const needle = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.contains substring must be string", span.line, span.col),
    };
    if (needle.len == 0) return Value.boolean(true);
    return Value.boolean(std.mem.indexOf(u8, haystack, needle) != null);
}

fn stdStartsWith(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.startsWith requires string as first argument", span.line, span.col),
    };
    const prefix = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.startsWith prefix must be string", span.line, span.col),
    };
    if (prefix.len == 0) return Value.boolean(true);
    return Value.boolean(std.mem.startsWith(u8, str, prefix));
}

fn stdEndsWith(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const str = switch (args[0]) {
        .string => |s| s,
        else => return self.typeErr("std.endsWith requires string as first argument", span.line, span.col),
    };
    const suffix = switch (args[1]) {
        .string => |s| s,
        else => return self.typeErr("std.endsWith suffix must be string", span.line, span.col),
    };
    if (suffix.len == 0) return Value.boolean(true);
    return Value.boolean(std.mem.endsWith(u8, str, suffix));
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
            // Reverse at codepoint level, not byte level
            var cps = std.ArrayListUnmanaged([]const u8){};
            var view = std.unicode.Utf8View.initUnchecked(s);
            var it = view.iterator();
            while (it.nextCodepointSlice()) |cp_slice| {
                cps.append(self.allocator, cp_slice) catch return error.OutOfMemory;
            }
            var buf = std.ArrayListUnmanaged(u8){};
            var i: usize = cps.items.len;
            while (i > 0) {
                i -= 1;
                buf.appendSlice(self.allocator, cps.items[i]) catch return error.OutOfMemory;
            }
            break :blk Value.str(buf.items);
        },
        else => self.typeErr("std.reverse requires list or string", span.line, span.col),
    };
}

fn stdAll(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.all requires list as first argument", span.line, span.col),
    };
    const func = switch (args[1]) {
        .function => |f| f,
        else => return self.typeErr("std.all requires function as second argument", span.line, span.col),
    };
    if (l.elements.len == 0) return Value.boolean(true);
    for (l.elements) |elem| {
        const r = try callFunction(self, func, &.{elem}, span);
        switch (r) {
            .bool_val => |bv| if (!bv) return Value.boolean(false),
            else => return self.typeErr("std.all predicate must return bool", span.line, span.col),
        }
    }
    return Value.boolean(true);
}

fn stdAny(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    try expectArgs(self, args, 2, span);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.any requires list as first argument", span.line, span.col),
    };
    const func = switch (args[1]) {
        .function => |f| f,
        else => return self.typeErr("std.any requires function as second argument", span.line, span.col),
    };
    if (l.elements.len == 0) return Value.boolean(false);
    for (l.elements) |elem| {
        const r = try callFunction(self, func, &.{elem}, span);
        switch (r) {
            .bool_val => |bv| if (bv) return Value.boolean(true),
            else => return self.typeErr("std.any predicate must return bool", span.line, span.col),
        }
    }
    return Value.boolean(false);
}

fn stdMap(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
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

fn stdFilter(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
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

fn stdReduce(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    if (args.len != 3) return self.typeErr("std.reduce requires 3 arguments", span.line, span.col);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.reduce requires list as first argument", span.line, span.col),
    };
    var acc = args[1];
    const func = switch (args[2]) {
        .function => |f| f,
        else => return self.typeErr("std.reduce requires function as third argument", span.line, span.col),
    };
    for (l.elements) |elem| {
        acc = try callFunction(self, func, &.{ acc, elem }, span);
    }
    return acc;
}

fn stdSort(self: *Evaluator, args: []const Value, span: Ast.Span) EvalError!Value {
    if (args.len < 1 or args.len > 2) return self.typeErr("std.sort requires 1-2 arguments", span.line, span.col);
    const l = switch (args[0]) {
        .list => |ll| ll,
        else => return self.typeErr("std.sort requires list", span.line, span.col),
    };
    if (l.elements.len <= 1) return args[0];
    const elems = try self.allocator.alloc(Value, l.elements.len);
    @memcpy(elems, l.elements);

    // 2-arg form: sort with comparator function
    if (args.len == 2) {
        const func = switch (args[1]) {
            .function => |f| f,
            else => return self.typeErr("std.sort second argument must be function", span.line, span.col),
        };

        // Validate comparator: must take 2 params and return bool (§5.16.2)
        if (func.params.len != 2) return self.typeErr("std.sort comparator must take 2 parameters", span.line, span.col);
        if (func.return_type.data == .name) {
            if (!std.mem.eql(u8, func.return_type.data.name, "bool"))
                return self.typeErr("std.sort comparator must return bool", span.line, span.col);
        }

        const Context = struct {
            ev: *Evaluator,
            func: val.Function,
            span: Ast.Span,
            err: ?EvalError,
        };
        var ctx = Context{ .ev = self, .func = func, .span = span, .err = null };
        std.sort.insertion(Value, elems, &ctx, struct {
            fn lessThan(context: *Context, a: Value, b: Value) bool {
                if (context.err != null) return false;
                const r = callFunction(context.ev, context.func, &.{ a, b }, context.span) catch |e| {
                    context.err = e;
                    return false;
                };
                return switch (r) {
                    .bool_val => |bv| bv,
                    else => false,
                };
            }
        }.lessThan);
        if (ctx.err) |e| return e;
        return Value{ .list = .{ .elements = elems } };
    }

    // 1-arg form: sort by natural ordering
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

// ── Function call helper ────────────────────────────────────

fn callFunction(self: *Evaluator, func: val.Function, args: []const Value, span: Ast.Span) EvalError!Value {
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

// ── Unicode case mapping ────────────────────────────────────
// Covers ASCII, Latin-1 Supplement, Latin Extended-A, Greek, Cyrillic.

const CaseUpper = struct { cps: [3]u21, len: u2 };

fn unicodeToUpper(cp: u21) CaseUpper {
    if (cp >= 'a' and cp <= 'z') return .{ .cps = .{ cp - 32, 0, 0 }, .len = 1 };
    if (cp < 0xC0) return .{ .cps = .{ cp, 0, 0 }, .len = 1 };
    if (cp >= 0xE0 and cp <= 0xF6) return .{ .cps = .{ cp - 0x20, 0, 0 }, .len = 1 };
    if (cp >= 0xF8 and cp <= 0xFE) return .{ .cps = .{ cp - 0x20, 0, 0 }, .len = 1 };
    if (cp == 0xDF) return .{ .cps = .{ 'S', 'S', 0 }, .len = 2 }; // ß → SS
    if (cp == 0xFF) return .{ .cps = .{ 0x178, 0, 0 }, .len = 1 }; // ÿ → Ÿ
    if (cp >= 0x100 and cp <= 0x12F and cp % 2 == 1) return .{ .cps = .{ cp - 1, 0, 0 }, .len = 1 };
    if (cp >= 0x132 and cp <= 0x137 and cp % 2 == 1) return .{ .cps = .{ cp - 1, 0, 0 }, .len = 1 };
    if (cp >= 0x13A and cp <= 0x148 and cp % 2 == 0) return .{ .cps = .{ cp - 1, 0, 0 }, .len = 1 };
    if (cp >= 0x14B and cp <= 0x177 and cp % 2 == 1) return .{ .cps = .{ cp - 1, 0, 0 }, .len = 1 };
    if (cp >= 0x17A and cp <= 0x17E and cp % 2 == 0) return .{ .cps = .{ cp - 1, 0, 0 }, .len = 1 };
    if (cp == 0x131) return .{ .cps = .{ 'I', 0, 0 }, .len = 1 };
    if (cp == 0x17F) return .{ .cps = .{ 'S', 0, 0 }, .len = 1 };
    if (cp >= 0x3B1 and cp <= 0x3C1) return .{ .cps = .{ cp - 0x20, 0, 0 }, .len = 1 };
    if (cp >= 0x3C3 and cp <= 0x3C9) return .{ .cps = .{ cp - 0x20, 0, 0 }, .len = 1 };
    if (cp == 0x3C2) return .{ .cps = .{ 0x3A3, 0, 0 }, .len = 1 };
    if (cp == 0x3AC) return .{ .cps = .{ 0x386, 0, 0 }, .len = 1 };
    if (cp == 0x3AD) return .{ .cps = .{ 0x388, 0, 0 }, .len = 1 };
    if (cp == 0x3AE) return .{ .cps = .{ 0x389, 0, 0 }, .len = 1 };
    if (cp == 0x3AF) return .{ .cps = .{ 0x38A, 0, 0 }, .len = 1 };
    if (cp == 0x3CC) return .{ .cps = .{ 0x38C, 0, 0 }, .len = 1 };
    if (cp == 0x3CD) return .{ .cps = .{ 0x38E, 0, 0 }, .len = 1 };
    if (cp == 0x3CE) return .{ .cps = .{ 0x38F, 0, 0 }, .len = 1 };
    if (cp >= 0x430 and cp <= 0x44F) return .{ .cps = .{ cp - 0x20, 0, 0 }, .len = 1 };
    if (cp >= 0x450 and cp <= 0x45F) return .{ .cps = .{ cp - 0x50, 0, 0 }, .len = 1 };
    return .{ .cps = .{ cp, 0, 0 }, .len = 1 };
}

fn unicodeToLower(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp < 0xC0) return cp;
    if (cp >= 0xC0 and cp <= 0xD6) return cp + 0x20;
    if (cp >= 0xD8 and cp <= 0xDE) return cp + 0x20;
    if (cp >= 0x100 and cp <= 0x12F and cp % 2 == 0) return cp + 1;
    if (cp == 0x130) return 'i';
    if (cp >= 0x132 and cp <= 0x137 and cp % 2 == 0) return cp + 1;
    if (cp >= 0x139 and cp <= 0x148 and cp % 2 == 1) return cp + 1;
    if (cp >= 0x14A and cp <= 0x177 and cp % 2 == 0) return cp + 1;
    if (cp == 0x178) return 0xFF;
    if (cp >= 0x179 and cp <= 0x17E and cp % 2 == 1) return cp + 1;
    if (cp >= 0x391 and cp <= 0x3A1) return cp + 0x20;
    if (cp >= 0x3A3 and cp <= 0x3A9) return cp + 0x20;
    if (cp == 0x386) return 0x3AC;
    if (cp == 0x388) return 0x3AD;
    if (cp == 0x389) return 0x3AE;
    if (cp == 0x38A) return 0x3AF;
    if (cp == 0x38C) return 0x3CC;
    if (cp == 0x38E) return 0x3CD;
    if (cp == 0x38F) return 0x3CE;
    if (cp >= 0x410 and cp <= 0x42F) return cp + 0x20;
    if (cp >= 0x400 and cp <= 0x40F) return cp + 0x50;
    return cp;
}
