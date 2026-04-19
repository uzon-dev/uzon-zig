const std = @import("std");
const root = @import("root.zig");
const Value = root.Value;
const h = @import("eval_helpers.zig");

const base_dir = "../conformance/";

// ── Directory scanning helpers ────────────────────────────

fn collectUzonFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    exclude_suffix: ?[]const u8,
) ![]const []const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var names = std.ArrayListUnmanaged([]const u8){};
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".uzon")) continue;
        if (exclude_suffix) |suf| {
            if (std.mem.endsWith(u8, entry.name, suf)) continue;
        }
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    const slice = try names.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

const TestResult = enum { pass, fail, skip };

// ── Eval tests ────────────────────────────────────────────

fn runEvalTest(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8) !TestResult {
    const input_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename });
    const base_name = filename[0 .. filename.len - ".uzon".len];
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/{s}.expected.uzon", .{ dir_path, base_name });

    const input_source = std.fs.cwd().readFileAlloc(allocator, input_path, 4 * 1024 * 1024) catch return .skip;
    const expected_source = std.fs.cwd().readFileAlloc(allocator, expected_path, 4 * 1024 * 1024) catch return .skip;

    const result = switch (root.parseWithBaseDir(allocator, input_source, dir_path)) {
        .value => |v| v,
        .errors => |errs| {
            if (std.process.hasEnvVarConstant("UZON_TEST_DEBUG")) {
                for (errs) |e| std.debug.print("    {s}: {s} ({d}:{d})\n", .{ filename, e.message, e.location.line, e.location.col });
            }
            return .fail;
        },
    };
    const expected = switch (root.parseWithBaseDir(allocator, expected_source, dir_path)) {
        .value => |v| v,
        .errors => return .skip,
    };

    // Every key in expected must match in result.
    // Result may have extra keys (function defs, _ prefixed bindings) that expected omits.
    if (result == .struct_val and expected == .struct_val) {
        for (expected.struct_val.keys, expected.struct_val.values) |ek, ev| {
            const rv = result.struct_val.get(ek) orelse return .fail;
            if (!h.valuesEqual(rv, ev)) {
                if (std.process.hasEnvVarConstant("UZON_TEST_DEBUG")) {
                    std.debug.print("    {s}: key '{s}' mismatch\n", .{ filename, ek });
                }
                return .fail;
            }
        }
        return .pass;
    }
    return if (h.valuesEqual(result, expected)) .pass else .fail;
}

test "conformance: eval" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const dir_path = base_dir ++ "eval";
    const files = try collectUzonFiles(a, dir_path, @as(?[]const u8, ".expected.uzon"));
    if (files.len == 0) {
        std.debug.print("  [eval] SKIP — directory not found\n", .{});
        return;
    }

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var failed_names = std.ArrayListUnmanaged([]const u8){};

    for (files) |file| {
        var test_arena = std.heap.ArenaAllocator.init(alloc);
        defer test_arena.deinit();

        const result = try runEvalTest(test_arena.allocator(), dir_path, file);
        switch (result) {
            .pass => pass += 1,
            .fail => {
                fail += 1;
                try failed_names.append(a, file);
            },
            .skip => skip += 1,
        }
    }

    std.debug.print("\n  [eval] {d} pass, {d} fail, {d} skip / {d} total\n", .{ pass, fail, skip, files.len });
    for (failed_names.items) |name| {
        std.debug.print("    FAIL: {s}\n", .{name});
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
}

// ── Parse valid tests ────────────────────────────────────

fn runParseValidTest(allocator: std.mem.Allocator, path: []const u8) !TestResult {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return .skip;
    const file_dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep_idx|
        path[0..sep_idx]
    else
        ".";
    return switch (root.parseWithBaseDir(allocator, source, file_dir)) {
        .value => .pass,
        .errors => |errs| blk: {
            if (std.process.hasEnvVarConstant("UZON_TEST_DEBUG")) {
                for (errs) |e| std.debug.print("      {s}: {s} ({d}:{d})\n", .{ path, e.message, e.location.line, e.location.col });
            }
            break :blk .fail;
        },
    };
}

fn runParseValidDir(alloc: std.mem.Allocator, collector: std.mem.Allocator, dir_path: []const u8, pass: *usize, fail: *usize, skip: *usize, failed_names: *std.ArrayListUnmanaged([]const u8)) !void {
    const files = try collectUzonFiles(collector, dir_path, null);
    for (files) |file| {
        var test_arena = std.heap.ArenaAllocator.init(alloc);
        defer test_arena.deinit();

        const path = try std.fmt.allocPrint(test_arena.allocator(), "{s}/{s}", .{ dir_path, file });
        const result = try runParseValidTest(test_arena.allocator(), path);
        switch (result) {
            .pass => pass.* += 1,
            .fail => {
                fail.* += 1;
                try failed_names.append(collector, try std.fmt.allocPrint(collector, "{s}/{s}", .{ dir_path, file }));
            },
            .skip => skip.* += 1,
        }
    }
}

test "conformance: parse/valid" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var failed_names = std.ArrayListUnmanaged([]const u8){};

    try runParseValidDir(alloc, a, base_dir ++ "parse/valid", &pass, &fail, &skip, &failed_names);
    try runParseValidDir(alloc, a, base_dir ++ "parse/valid/cross", &pass, &fail, &skip, &failed_names);
    try runParseValidDir(alloc, a, base_dir ++ "parse/valid/starship", &pass, &fail, &skip, &failed_names);

    const total = pass + fail + skip;
    if (total == 0) {
        std.debug.print("  [parse/valid] SKIP — no test files found\n", .{});
        return;
    }
    std.debug.print("\n  [parse/valid] {d} pass, {d} fail, {d} skip / {d} total\n", .{ pass, fail, skip, total });
    for (failed_names.items) |name| {
        std.debug.print("    FAIL: {s}\n", .{name});
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
}

// ── Parse invalid tests ──────────────────────────────────

fn runParseInvalidTest(allocator: std.mem.Allocator, path: []const u8) !TestResult {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return .skip;
    const file_dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep_idx|
        path[0..sep_idx]
    else
        ".";
    return switch (root.parseWithBaseDir(allocator, source, file_dir)) {
        .value => .fail, // should have errored
        .errors => .pass,
    };
}

fn runParseInvalidDir(alloc: std.mem.Allocator, collector: std.mem.Allocator, dir_path: []const u8, pass: *usize, fail: *usize, skip: *usize, failed_names: *std.ArrayListUnmanaged([]const u8)) !void {
    const files = try collectUzonFiles(collector, dir_path, null);
    for (files) |file| {
        var test_arena = std.heap.ArenaAllocator.init(alloc);
        defer test_arena.deinit();

        const path = try std.fmt.allocPrint(test_arena.allocator(), "{s}/{s}", .{ dir_path, file });
        const result = try runParseInvalidTest(test_arena.allocator(), path);
        switch (result) {
            .pass => pass.* += 1,
            .fail => {
                fail.* += 1;
                try failed_names.append(collector, try std.fmt.allocPrint(collector, "{s}/{s}", .{ dir_path, file }));
            },
            .skip => skip.* += 1,
        }
    }
}

test "conformance: parse/invalid" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var failed_names = std.ArrayListUnmanaged([]const u8){};

    try runParseInvalidDir(alloc, a, base_dir ++ "parse/invalid", &pass, &fail, &skip, &failed_names);
    try runParseInvalidDir(alloc, a, base_dir ++ "parse/invalid/cross", &pass, &fail, &skip, &failed_names);
    try runParseInvalidDir(alloc, a, base_dir ++ "parse/invalid/starship", &pass, &fail, &skip, &failed_names);

    const total = pass + fail + skip;
    if (total == 0) {
        std.debug.print("  [parse/invalid] SKIP — no test files found\n", .{});
        return;
    }
    std.debug.print("\n  [parse/invalid] {d} pass, {d} fail, {d} skip / {d} total\n", .{ pass, fail, skip, total });
    for (failed_names.items) |name| {
        std.debug.print("    FAIL: {s}\n", .{name});
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
}

// ── Roundtrip tests ──────────────────────────────────────

fn runRoundtripTest(allocator: std.mem.Allocator, path: []const u8) !TestResult {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return .skip;

    const val1 = switch (root.parse(allocator, source)) {
        .value => |v| v,
        .errors => return .skip,
    };
    const text = root.stringify(allocator, val1) catch return .fail;
    const val2 = switch (root.parse(allocator, text)) {
        .value => |v| v,
        .errors => return .fail,
    };
    return if (h.valuesEqual(val1, val2)) .pass else .fail;
}

test "conformance: roundtrip" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const dir_path = base_dir ++ "roundtrip";
    const files = try collectUzonFiles(a, dir_path, null);
    if (files.len == 0) {
        std.debug.print("  [roundtrip] SKIP — directory not found\n", .{});
        return;
    }

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var failed_names = std.ArrayListUnmanaged([]const u8){};

    for (files) |file| {
        var test_arena = std.heap.ArenaAllocator.init(alloc);
        defer test_arena.deinit();

        const path = try std.fmt.allocPrint(test_arena.allocator(), "{s}/{s}", .{ dir_path, file });
        const result = try runRoundtripTest(test_arena.allocator(), path);
        switch (result) {
            .pass => pass += 1,
            .fail => {
                fail += 1;
                try failed_names.append(a, file);
            },
            .skip => skip += 1,
        }
    }

    std.debug.print("\n  [roundtrip] {d} pass, {d} fail, {d} skip / {d} total\n", .{ pass, fail, skip, files.len });
    for (failed_names.items) |name| {
        std.debug.print("    FAIL: {s}\n", .{name});
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
}
