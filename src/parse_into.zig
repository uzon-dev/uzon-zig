//! Comptime-typed deserialization: UZON Value → native Zig types.
//!
//! Leverages Zig's comptime reflection to map UZON values directly to
//! native types (u5, f16, i256, union(enum), etc.) with zero-cost type
//! checking at compile time and range validation at runtime.
//!
//!   const Config = struct { port: u16, host: []const u8, tls: bool };
//!   const config = try uzon.parseInto(Config, allocator, source);

const std = @import("std");
const val = @import("Value.zig");
const Value = val.Value;

pub const Error = error{
    TypeMismatch,
    OutOfRange,
    MissingField,
    UnknownVariant,
    LengthMismatch,
    OutOfMemory,
};

/// Convert a UZON Value to a native Zig type.
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    return parseValue(T, allocator, value);
}

fn parseValue(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const info = @typeInfo(T);

    // Optional: null/undefined → null
    if (comptime info == .optional) {
        if (value == .null_val or value == .undefined) return null;
        return @as(T, try parseValue(info.optional.child, allocator, value));
    }

    // Unwrap UZON unions transparently for non-union targets (§3.6/§3.7.1)
    const v = if (comptime info == .@"union") value else value.unwrapTransparent();

    if (v == .null_val or v == .undefined) return error.TypeMismatch;

    if (comptime info == .bool) return if (v == .bool_val) v.bool_val else error.TypeMismatch;
    if (comptime info == .int) return parseInteger(T, v);
    if (comptime info == .float) return parseFloat(T, v);
    if (comptime info == .pointer) return parseSlice(T, allocator, v);
    if (comptime info == .array) return parseArray(T, allocator, v);
    if (comptime info == .@"struct") return parseStruct(T, allocator, v);
    if (comptime info == .@"enum") return parseEnum(T, v);
    if (comptime info == .@"union") return parseUnion(T, allocator, v);

    @compileError("unsupported target type: " ++ @typeName(T));
}

// ── Integer ───────────────────────────────────────────────

fn parseInteger(comptime T: type, value: Value) Error!T {
    const raw: i128 = switch (value) {
        .integer => |i| i.value,
        else => return error.TypeMismatch,
    };
    const info = @typeInfo(T).int;

    // Target >= 128 bits — always fits (with sign check for unsigned)
    if (comptime info.bits >= 128) {
        if (comptime info.signedness == .unsigned) {
            if (raw < 0) return error.OutOfRange;
        }
        return @intCast(raw);
    }

    // Smaller types: compile-time bounds fit in i128
    if (raw < std.math.minInt(T) or raw > std.math.maxInt(T)) return error.OutOfRange;
    return @intCast(raw);
}

// ── Float ─────────────────────────────────────────────────

fn parseFloat(comptime T: type, value: Value) Error!T {
    const raw: f64 = switch (value) {
        .float_val => |f| f.value,
        .integer => |i| @floatFromInt(i.value), // int → float adoption
        else => return error.TypeMismatch,
    };
    return @floatCast(raw);
}

// ── Slice / String ────────────────────────────────────────

fn parseSlice(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const ptr = @typeInfo(T).pointer;
    if (comptime ptr.size != .slice) @compileError("only slices supported: " ++ @typeName(T));

    // []const u8 / []u8 — string
    if (comptime ptr.child == u8) {
        const s: []const u8 = switch (value) {
            .string => |str| str,
            else => return error.TypeMismatch,
        };
        if (comptime ptr.is_const) return s;
        return allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    // []const Child / []Child — from list or tuple
    const elements: []const Value = switch (value) {
        .list => |l| l.elements,
        .tuple => |t| t.elements,
        else => return error.TypeMismatch,
    };
    const result = allocator.alloc(ptr.child, elements.len) catch return error.OutOfMemory;
    for (elements, 0..) |elem, i| {
        result[i] = try parseValue(ptr.child, allocator, elem);
    }
    return result;
}

// ── Fixed-size Array ──────────────────────────────────────

fn parseArray(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const arr = @typeInfo(T).array;
    const elements: []const Value = switch (value) {
        .list => |l| l.elements,
        .tuple => |t| t.elements,
        else => return error.TypeMismatch,
    };
    if (elements.len != arr.len) return error.LengthMismatch;

    var result: T = undefined;
    for (0..arr.len) |i| {
        result[i] = try parseValue(arr.child, allocator, elements[i]);
    }
    return result;
}

// ── Struct ────────────────────────────────────────────────

fn parseStruct(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const s = switch (value) {
        .struct_val => |sv| sv,
        else => return error.TypeMismatch,
    };
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (s.get(field.name)) |fv| {
            @field(result, field.name) = try parseValue(field.type, allocator, fv);
        } else if (field.defaultValue()) |dflt| {
            @field(result, field.name) = dflt;
        } else if (comptime @typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

// ── Enum ──────────────────────────────────────────────────

fn parseEnum(comptime T: type, value: Value) Error!T {
    const name: []const u8 = switch (value) {
        .enum_val => |e| e.value,
        .string => |s| s, // string → enum convenience
        else => return error.TypeMismatch,
    };
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return error.UnknownVariant;
}

// ── Tagged Union ──────────────────────────────────────────

fn parseUnion(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const tu = switch (value) {
        .tagged_union => |t| t,
        else => return error.TypeMismatch,
    };
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, tu.tag, field.name)) {
            if (comptime field.type == void) {
                return @unionInit(T, field.name, {});
            } else {
                return @unionInit(T, field.name, try parseValue(field.type, allocator, tu.value.*));
            }
        }
    }
    return error.UnknownVariant;
}

// ── Tests ──────────────────────────────────────────────────

test "bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(true, try fromValue(bool, a, Value.boolean(true)));
    try std.testing.expectEqual(false, try fromValue(bool, a, Value.boolean(false)));
    try std.testing.expectError(error.TypeMismatch, fromValue(bool, a, Value.int(1)));
}

test "integer types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(@as(u8, 42), try fromValue(u8, a, Value.int(42)));
    try std.testing.expectEqual(@as(i32, -100), try fromValue(i32, a, Value.int(-100)));
    try std.testing.expectEqual(@as(u16, 8080), try fromValue(u16, a, Value.int(8080)));

    // Arbitrary bit-width integers
    try std.testing.expectEqual(@as(u5, 31), try fromValue(u5, a, Value.int(31)));
    try std.testing.expectError(error.OutOfRange, fromValue(u5, a, Value.int(32)));

    // Range errors
    try std.testing.expectError(error.OutOfRange, fromValue(u8, a, Value.int(256)));
    try std.testing.expectError(error.OutOfRange, fromValue(u8, a, Value.int(-1)));
    try std.testing.expectError(error.OutOfRange, fromValue(i8, a, Value.int(128)));
}

test "float types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f32_val = try fromValue(f32, a, Value.float(3.14));
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), f32_val, 0.01);

    const f64_val = try fromValue(f64, a, Value.float(2.718));
    try std.testing.expectApproxEqAbs(@as(f64, 2.718), f64_val, 0.001);

    // int → float adoption
    try std.testing.expectEqual(@as(f64, 42.0), try fromValue(f64, a, Value.int(42)));
}

test "string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("hello", try fromValue([]const u8, a, Value.str("hello")));
}

test "optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(@as(?u16, null), try fromValue(?u16, a, .null_val));
    try std.testing.expectEqual(@as(?u16, null), try fromValue(?u16, a, .undefined));
    try std.testing.expectEqual(@as(?u16, 42), try fromValue(?u16, a, Value.int(42)));
}

test "struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Config = struct { port: u16, host: []const u8, tls: bool };
    const value = Value{ .struct_val = .{
        .keys = &.{ "port", "host", "tls" },
        .values = &.{ Value.int(8080), Value.str("localhost"), Value.boolean(true) },
    } };

    const config = try fromValue(Config, a, value);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(true, config.tls);
}

test "struct with defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Config = struct { host: []const u8, port: u16 = 3000, debug: bool = false };
    const value = Value{ .struct_val = .{
        .keys = &.{"host"},
        .values = &.{Value.str("localhost")},
    } };

    const config = try fromValue(Config, a, value);
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 3000), config.port);
    try std.testing.expectEqual(false, config.debug);
}

test "struct with optional field missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Config = struct { host: []const u8, proxy: ?[]const u8 };
    const value = Value{ .struct_val = .{
        .keys = &.{"host"},
        .values = &.{Value.str("localhost")},
    } };

    const config = try fromValue(Config, a, value);
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(?[]const u8, null), config.proxy);
}

test "struct missing required field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Config = struct { host: []const u8, port: u16 };
    const value = Value{ .struct_val = .{
        .keys = &.{"host"},
        .values = &.{Value.str("localhost")},
    } };

    try std.testing.expectError(error.MissingField, fromValue(Config, a, value));
}

test "enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Level = enum { debug, info, warn, err };

    const from_enum = try fromValue(Level, a, Value{ .enum_val = .{
        .value = "debug",
        .variants = &.{ "debug", "info", "warn", "err" },
    } });
    try std.testing.expectEqual(Level.debug, from_enum);

    // string → enum convenience
    try std.testing.expectEqual(Level.warn, try fromValue(Level, a, Value.str("warn")));

    // unknown variant
    try std.testing.expectError(error.UnknownVariant, fromValue(Level, a, Value.str("trace")));
}

test "fixed array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = Value{ .list = .{
        .elements = &.{ Value.int(10), Value.int(20), Value.int(30) },
    } };

    const arr = try fromValue([3]i32, a, value);
    try std.testing.expectEqual(@as(i32, 10), arr[0]);
    try std.testing.expectEqual(@as(i32, 20), arr[1]);
    try std.testing.expectEqual(@as(i32, 30), arr[2]);

    // Length mismatch
    try std.testing.expectError(error.LengthMismatch, fromValue([2]i32, a, value));
}

test "slice from list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = Value{ .list = .{
        .elements = &.{ Value.int(1), Value.int(2), Value.int(3) },
    } };

    const slice = try fromValue([]const i32, a, value);
    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(i32, 1), slice[0]);
    try std.testing.expectEqual(@as(i32, 2), slice[1]);
    try std.testing.expectEqual(@as(i32, 3), slice[2]);
}

test "nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Address = struct { host: []const u8, port: u16 };
    const Config = struct { name: []const u8, bind: Address };

    const inner = Value{ .struct_val = .{
        .keys = &.{ "host", "port" },
        .values = &.{ Value.str("0.0.0.0"), Value.int(443) },
    } };
    const outer = Value{ .struct_val = .{
        .keys = &.{ "name", "bind" },
        .values = &.{ Value.str("prod"), inner },
    } };

    const config = try fromValue(Config, a, outer);
    try std.testing.expectEqualStrings("prod", config.name);
    try std.testing.expectEqualStrings("0.0.0.0", config.bind.host);
    try std.testing.expectEqual(@as(u16, 443), config.bind.port);
}

test "tagged union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Shape = union(enum) { circle: f32, point: void };

    const inner_ptr = try a.create(Value);
    inner_ptr.* = Value.float(3.14);
    const variants = try a.alloc(val.TaggedUnion.VariantInfo, 2);
    variants[0] = .{ .name = "circle", .type_name = "f32" };
    variants[1] = .{ .name = "point", .type_name = null };

    const tu_val = Value{ .tagged_union = .{
        .value = inner_ptr,
        .tag = "circle",
        .variants = variants,
    } };

    const shape = try fromValue(Shape, a, tu_val);
    switch (shape) {
        .circle => |r| try std.testing.expectApproxEqAbs(@as(f32, 3.14), r, 0.01),
        .point => unreachable,
    }
}

test "type mismatch errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.TypeMismatch, fromValue(u16, a, Value.str("hello")));
    try std.testing.expectError(error.TypeMismatch, fromValue(bool, a, Value.int(0)));
    try std.testing.expectError(error.TypeMismatch, fromValue([]const u8, a, Value.int(42)));
    try std.testing.expectError(error.TypeMismatch, fromValue(u16, a, .null_val));
    try std.testing.expectError(error.TypeMismatch, fromValue(u16, a, .undefined));
}
