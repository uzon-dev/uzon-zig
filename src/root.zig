// UZON - A typed, human-readable data expression format
// Zig library implementation (spec v0.7)

const std = @import("std");

pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Ast = @import("Ast.zig");
pub const ValueMod = @import("Value.zig");
pub const Value = ValueMod.Value;
pub const Evaluator = @import("Evaluator.zig");
pub const Scope = @import("Scope.zig");
pub const err = @import("error.zig");
pub const stringify_mod = @import("stringify.zig");
pub const parse_into = @import("parse_into.zig");

// Internal modules (test coverage via refAllDeclsRecursive)
comptime {
    _ = @import("deps.zig");
    _ = @import("eval_helpers.zig");
    _ = @import("eval_ops.zig");
    _ = @import("eval_types.zig");
    _ = @import("eval_exprs.zig");
    _ = @import("stdlib.zig");
    _ = @import("eval_test.zig");
    _ = @import("conformance.zig");
}

// ── Public API types ────────────────────────────────────────

pub const Error = err.Error;
pub const UzonError = err.UzonError;
pub const Location = err.Location;

/// Parse result: either a value or a detailed error.
pub const ParseResult = union(enum) {
    value: Value,
    err: UzonError,
};

// ── Parsing ─────────────────────────────────────────────────

/// Parse and evaluate a UZON source string.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseResult {
    return parseWithBaseDir(allocator, source, null);
}

/// Parse a UZON source string with a base directory for file imports.
pub fn parseWithBaseDir(allocator: std.mem.Allocator, source: []const u8, base_dir: ?[]const u8) ParseResult {
    // Lex
    var lexer = Lexer.init(allocator, source);
    const tokens = lexer.tokenize() catch
        return .{ .err = UzonError.syntaxError(allocator, "out of memory", 0, 0) };

    // Parse
    var parser = Parser.init(allocator, tokens, lexer.comment_lines.items);
    const doc = parser.parse() catch {
        return .{ .err = parser.last_error orelse UzonError.syntaxError(allocator, "unknown parse error", 0, 0) };
    };

    // Evaluate
    var evaluator = Evaluator.init(allocator);
    evaluator.base_dir = base_dir;
    const value = evaluator.evalDocument(doc) catch {
        return .{ .err = evaluator.last_error orelse UzonError.runtimeError(allocator, "unknown evaluation error", 0, 0) };
    };
    return .{ .value = value };
}

/// Parse and evaluate a UZON file.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) ParseResult {
    const file = std.fs.cwd().openFile(path, .{}) catch
        return .{ .err = UzonError.runtimeError(allocator, "cannot open file", 0, 0) };
    defer file.close();
    const source = file.readToEndAlloc(allocator, 1024 * 1024 * 16) catch
        return .{ .err = UzonError.runtimeError(allocator, "cannot read file", 0, 0) };
    const base_dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep_idx|
        path[0..sep_idx]
    else
        ".";
    var result = parseWithBaseDir(allocator, source, base_dir);
    // Attach filename to error if not already set by an import
    switch (result) {
        .err => |*e| {
            if (e.location.filename == null) e.location.filename = path;
        },
        .value => {},
    }
    return result;
}

// ── Serialization ───────────────────────────────────────────

/// Serialize a Value to UZON text.
pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return stringify_mod.stringify(allocator, value);
}

/// Serialize a Value to a UZON file.
pub fn stringifyFile(allocator: std.mem.Allocator, value: Value, path: []const u8) !void {
    return stringify_mod.stringifyFile(allocator, value, path);
}

// ── Deserialization ─────────────────────────────────────────

/// Parse a UZON source string and deserialize into a native Zig type.
pub fn parseInto(comptime T: type, allocator: std.mem.Allocator, source: []const u8) !T {
    const result = parse(allocator, source);
    const value = switch (result) {
        .value => |v| v,
        .err => return error.UzonSyntax,
    };
    return try parse_into.fromValue(T, allocator, value);
}

/// Parse a UZON file and deserialize into a native Zig type.
pub fn parseFileInto(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const result = parseFile(allocator, path);
    const value = switch (result) {
        .value => |v| v,
        .err => return error.UzonSyntax,
    };
    return try parse_into.fromValue(T, allocator, value);
}

// ── Tests ───────────────────────────────────────────────────

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "end-to-end parse and evaluate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\x is 42
        \\y is x + 8
        \\greeting is "hello"
        \\flag is true
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqual(@as(i128, 42), result.struct_val.get("x").?.integer.value);
    try std.testing.expectEqual(@as(i128, 50), result.struct_val.get("y").?.integer.value);
    try std.testing.expectEqualStrings("hello", result.struct_val.get("greeting").?.string);
    try std.testing.expectEqual(true, result.struct_val.get("flag").?.bool_val);
}

test "end-to-end forward references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\a is b + 1
        \\b is 10
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqual(@as(i128, 11), result.struct_val.get("a").?.integer.value);
    try std.testing.expectEqual(@as(i128, 10), result.struct_val.get("b").?.integer.value);
}

test "end-to-end nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\port is 8080
        \\server is {
        \\  host is "localhost"
        \\  port is port
        \\}
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqual(@as(i128, 8080), result.struct_val.get("port").?.integer.value);
    const server = result.struct_val.get("server").?.struct_val;
    try std.testing.expectEqualStrings("localhost", server.get("host").?.string);
    try std.testing.expectEqual(@as(i128, 8080), server.get("port").?.integer.value);
}

test "end-to-end or_else with self-exclusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\port is port or else 3000
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqual(@as(i128, 3000), result.struct_val.get("port").?.integer.value);
}

test "end-to-end if expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\debug is true
        \\level is if debug then "verbose" else "info"
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqualStrings("verbose", result.struct_val.get("level").?.string);
}

test "end-to-end list and member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\items is [10, 20, 30]
        \\first is items.first
        \\second is items.1
    ;

    const result = parse(a, source).value;
    try std.testing.expectEqual(@as(i128, 10), result.struct_val.get("first").?.integer.value);
    try std.testing.expectEqual(@as(i128, 20), result.struct_val.get("second").?.integer.value);
}

test "end-to-end parseInto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Address = struct { host: []const u8, port: u16 };
    const Config = struct {
        name: []const u8,
        debug: bool,
        bind: Address,
        tags: []const []const u8,
    };

    const source =
        \\name is "my-app"
        \\debug is true
        \\bind is {
        \\  host is "0.0.0.0"
        \\  port is 443
        \\}
        \\tags is ["web", "prod"]
    ;

    const config = try parseInto(Config, a, source);
    try std.testing.expectEqualStrings("my-app", config.name);
    try std.testing.expectEqual(true, config.debug);
    try std.testing.expectEqualStrings("0.0.0.0", config.bind.host);
    try std.testing.expectEqual(@as(u16, 443), config.bind.port);
    try std.testing.expectEqual(@as(usize, 2), config.tags.len);
    try std.testing.expectEqualStrings("web", config.tags[0]);
    try std.testing.expectEqualStrings("prod", config.tags[1]);
}
