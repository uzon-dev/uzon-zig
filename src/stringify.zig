const std = @import("std");
const val = @import("Value.zig");
const Value = val.Value;
const IntegerType = val.IntegerType;
const Token = @import("Token.zig");

pub const WriteError = error{OutOfMemory};

/// Tracks emitted type names for compact reuse.
const Ctx = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    emitted_types: std.StringHashMapUnmanaged(void),

    fn init(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) Ctx {
        return .{ .allocator = allocator, .buf = buf, .emitted_types = .{} };
    }

    fn w(self: *Ctx, s: []const u8) WriteError!void {
        self.buf.appendSlice(self.allocator, s) catch return error.OutOfMemory;
    }

    fn ch(self: *Ctx, c: u8) WriteError!void {
        self.buf.append(self.allocator, c) catch return error.OutOfMemory;
    }

    fn markType(self: *Ctx, name: []const u8) WriteError!void {
        self.emitted_types.put(self.allocator, name, {}) catch return error.OutOfMemory;
    }
};

/// Serialize a Value to UZON text. Top-level struct → document (bare bindings).
pub fn stringify(allocator: std.mem.Allocator, value: Value) WriteError![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var ctx = Ctx.init(allocator, &buf);
    if (value == .struct_val) {
        try writeDocument(&ctx, value.struct_val.keys, value.struct_val.values);
    } else {
        try writeValue(&ctx, value, 0);
    }
    return buf.items;
}

/// Serialize always as value syntax (struct gets braces).
pub fn stringifyValue(allocator: std.mem.Allocator, value: Value) WriteError![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var ctx = Ctx.init(allocator, &buf);
    try writeValue(&ctx, value, 0);
    return buf.items;
}

/// Serialize and write to file.
pub fn stringifyFile(allocator: std.mem.Allocator, value: Value, path: []const u8) !void {
    const text = try stringify(allocator, value);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(text);
}

fn writeDocument(ctx: *Ctx, keys: []const []const u8, values: []const Value) WriteError!void {
    for (keys, values) |key, v| {
        try writeIdentifier(ctx, key);
        try ctx.w(" is ");
        try writeValue(ctx, v, 0);
        try ctx.ch('\n');
    }
}

fn writeValue(ctx: *Ctx, value: Value, indent: usize) WriteError!void {
    switch (value) {
        .null_val => try ctx.w("null"),
        .undefined => try ctx.w("undefined"),
        .bool_val => |b| try ctx.w(if (b) "true" else "false"),
        .integer => |i| try writeInteger(ctx, i),
        .float_val => |f| try writeFloat(ctx, f),
        .string => |s| try writeString(ctx, s),
        .list => |l| {
            try writeList(ctx, l.elements, indent);
            if (l.element_type) |et| {
                try ctx.w(" as [");
                try ctx.w(et);
                try ctx.ch(']');
            }
        },
        .tuple => |t| try writeTuple(ctx, t.elements, indent),
        .struct_val => |s| try writeStruct(ctx, s.keys, s.values, indent),
        .enum_val => |e| try writeEnum(ctx, e),
        .union_val => |u| try writeUnion(ctx, u, indent),
        .tagged_union => |tu| try writeTaggedUnion(ctx, tu, indent),
        .function => try ctx.w("<function>"),
    }
}

fn writeInteger(ctx: *Ctx, i: val.Integer) WriteError!void {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{i.value}) catch return error.OutOfMemory;
    try ctx.w(s);
    if (i.explicit) try writeIntTypeAnn(ctx, i.type_ann);
}

fn writeIntTypeAnn(ctx: *Ctx, type_ann: IntegerType) WriteError!void {
    switch (type_ann) {
        .arbitrary => {},
        .signed => |bits| {
            if (bits != 64) {
                try ctx.w(" as i");
                try writeBits(ctx, bits);
            }
        },
        .unsigned => |bits| {
            try ctx.w(" as u");
            try writeBits(ctx, bits);
        },
    }
}

fn writeBits(ctx: *Ctx, bits: u16) WriteError!void {
    var tmp: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{bits}) catch return error.OutOfMemory;
    try ctx.w(s);
}

fn writeFloat(ctx: *Ctx, f: val.Float) WriteError!void {
    if (std.math.isInf(f.value)) {
        if (std.math.signbit(f.value)) try ctx.ch('-');
        try ctx.w("inf");
    } else if (std.math.isNan(f.value)) {
        try ctx.w("nan");
    } else if (f.value == 0.0 and std.math.signbit(f.value)) {
        try ctx.w("-0.0");
    } else if (f.value == 0.0) {
        try ctx.w("0.0");
    } else {
        var tmp: [350]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{f.value}) catch return error.OutOfMemory;
        try ctx.w(s);
        if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null)
            try ctx.w(".0");
    }
    if (f.explicit and f.type_ann != .f64) {
        try ctx.w(" as ");
        try ctx.w(switch (f.type_ann) {
            .f16 => "f16",
            .f32 => "f32",
            .f64 => "f64",
            .f80 => "f80",
            .f128 => "f128",
        });
    }
}

fn writeString(ctx: *Ctx, s: []const u8) WriteError!void {
    try ctx.ch('"');
    for (s) |c| {
        switch (c) {
            '"' => try ctx.w("\\\""),
            '\\' => try ctx.w("\\\\"),
            '\n' => try ctx.w("\\n"),
            '\r' => try ctx.w("\\r"),
            '\t' => try ctx.w("\\t"),
            '{' => try ctx.w("\\{"),
            0 => try ctx.w("\\0"),
            else => try ctx.ch(c),
        }
    }
    try ctx.ch('"');
}

fn writeList(ctx: *Ctx, elements: []const Value, indent: usize) WriteError!void {
    if (elements.len == 0) {
        try ctx.w("[]");
        return;
    }
    try ctx.ch('[');
    for (elements, 0..) |e, i| {
        if (i > 0) try ctx.w(", ");
        try writeValue(ctx, e, indent);
    }
    try ctx.ch(']');
}

fn writeTuple(ctx: *Ctx, elements: []const Value, indent: usize) WriteError!void {
    try ctx.ch('(');
    for (elements, 0..) |e, i| {
        if (i > 0) try ctx.w(", ");
        try writeValue(ctx, e, indent);
    }
    if (elements.len == 1) try ctx.ch(',');
    try ctx.ch(')');
}

fn writeStruct(ctx: *Ctx, keys: []const []const u8, values: []const Value, indent: usize) WriteError!void {
    if (keys.len == 0) {
        try ctx.w("{}");
        return;
    }
    const ni = indent + 2;
    try ctx.w("{\n");
    for (keys, values) |key, v| {
        try writeIndent(ctx, ni);
        try writeIdentifier(ctx, key);
        try ctx.w(" is ");
        try writeValue(ctx, v, ni);
        try ctx.ch('\n');
    }
    try writeIndent(ctx, indent);
    try ctx.ch('}');
}

fn writeEnum(ctx: *Ctx, e: val.Enum) WriteError!void {
    if (e.type_name) |tn| {
        if (ctx.emitted_types.contains(tn)) {
            try ctx.w(e.value);
            try ctx.w(" as ");
            try ctx.w(tn);
            return;
        }
        try ctx.markType(tn);
    }
    try ctx.w(e.value);
    try ctx.w(" from ");
    for (e.variants, 0..) |v, i| {
        if (i > 0) try ctx.w(", ");
        try ctx.w(v);
    }
    if (e.type_name) |tn| {
        try ctx.w(" called ");
        try ctx.w(tn);
    }
}

fn writeUnion(ctx: *Ctx, u: val.Union, indent: usize) WriteError!void {
    try writeValue(ctx, u.value.*, indent);
    try ctx.w(" from union ");
    for (u.types, 0..) |t, i| {
        if (i > 0) try ctx.w(", ");
        try ctx.w(t);
    }
}

fn writeTaggedUnion(ctx: *Ctx, tu: val.TaggedUnion, indent: usize) WriteError!void {
    if (tu.type_name) |tn| {
        if (ctx.emitted_types.contains(tn)) {
            try writeValue(ctx, tu.value.*, indent);
            try ctx.w(" as ");
            try ctx.w(tn);
            try ctx.w(" named ");
            try ctx.w(tu.tag);
            return;
        }
        try ctx.markType(tn);
    }
    try writeValue(ctx, tu.value.*, indent);
    try ctx.w(" named ");
    try ctx.w(tu.tag);
    try ctx.w(" from ");
    for (tu.variants, 0..) |v, i| {
        if (i > 0) try ctx.w(", ");
        try ctx.w(v.name);
        if (v.type_name) |tn| {
            try ctx.w(" as ");
            try ctx.w(tn);
        }
    }
    if (tu.type_name) |tn| {
        try ctx.w(" called ");
        try ctx.w(tn);
    }
}

fn writeIdentifier(ctx: *Ctx, name: []const u8) WriteError!void {
    if (needsQuoting(name)) {
        try ctx.ch('\'');
        try ctx.w(name);
        try ctx.ch('\'');
    } else if (Token.keywords.get(name) != null) {
        try ctx.ch('@');
        try ctx.w(name);
    } else {
        try ctx.w(name);
    }
}

fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return true;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return true;
    return false;
}

fn writeIndent(ctx: *Ctx, indent: usize) WriteError!void {
    for (0..indent) |_| try ctx.ch(' ');
}

// ── Tests ────────────────────────────────────────────────────

test "stringify null/bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("null", try stringify(a, .null_val));
    try std.testing.expectEqualStrings("true", try stringify(a, Value.boolean(true)));
    try std.testing.expectEqualStrings("false", try stringify(a, Value.boolean(false)));
}

test "stringify integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("42", try stringify(a, Value.int(42)));
    try std.testing.expectEqualStrings("-1", try stringify(a, Value.int(-1)));
    try std.testing.expectEqualStrings("42 as u8", try stringify(a, Value{ .integer = .{ .value = 42, .type_ann = .{ .unsigned = 8 }, .explicit = true } }));
}

test "stringify string with escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"hello\"", try stringify(a, Value.str("hello")));
    try std.testing.expectEqualStrings("\"line\\n\"", try stringify(a, Value.str("line\n")));
}

test "stringify list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[]", try stringify(a, Value{ .list = .{ .elements = &.{} } }));
    try std.testing.expectEqualStrings("[1, 2, 3]", try stringify(a, Value{ .list = .{ .elements = &.{ Value.int(1), Value.int(2), Value.int(3) } } }));
}

test "stringify inf/nan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("inf", try stringify(a, Value{ .float_val = .{ .value = std.math.inf(f64) } }));
    try std.testing.expectEqualStrings("-inf", try stringify(a, Value{ .float_val = .{ .value = -std.math.inf(f64) } }));
    try std.testing.expectEqualStrings("nan", try stringify(a, Value{ .float_val = .{ .value = std.math.nan(f64) } }));
}

test "stringify struct as document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Value{ .struct_val = .{ .keys = &.{ "x", "y" }, .values = &.{ Value.int(1), Value.int(2) } } };
    const result = try stringify(a, v);
    try std.testing.expect(std.mem.indexOf(u8, result, "x is 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "y is 2") != null);
}
