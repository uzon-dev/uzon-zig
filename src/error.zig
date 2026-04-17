const std = @import("std");

/// Source location for error reporting.
/// Line and column are 1-based. Column counts Unicode scalar values, not bytes (§11.2).
pub const Location = struct {
    line: u32 = 0,
    col: u32 = 0,
    end_line: u32 = 0,
    end_col: u32 = 0,
    filename: ?[]const u8 = null,

    pub fn write(self: Location, writer: anytype) !void {
        if (self.filename) |f| {
            try writer.print("{s}:{d}:{d}", .{ f, self.line, self.col });
        } else {
            try writer.print("{d}:{d}", .{ self.line, self.col });
        }
        if (self.end_line != 0 or self.end_col != 0) {
            try writer.print("-{d}:{d}", .{ self.end_line, self.end_col });
        }
    }
};

/// Error categories per §11.2.
/// Priority: syntax > circular > type_ > runtime.
pub const ErrorKind = enum {
    syntax,
    circular,
    type_,
    runtime,
};

/// A UZON error with location, optional import trace, and optional suggestion.
pub const UzonError = struct {
    kind: ErrorKind,
    message: []const u8,
    suggestion: ?[]const u8 = null,
    location: Location,
    import_trace: std.ArrayListUnmanaged(Location),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, kind: ErrorKind, message: []const u8, line: u32, col: u32) UzonError {
        return .{
            .kind = kind,
            .message = message,
            .location = .{ .line = line, .col = col },
            .import_trace = .{},
            .allocator = allocator,
        };
    }

    pub fn initWithSuggestion(allocator: std.mem.Allocator, kind: ErrorKind, message: []const u8, suggestion: ?[]const u8, line: u32, col: u32) UzonError {
        return .{
            .kind = kind,
            .message = message,
            .suggestion = suggestion,
            .location = .{ .line = line, .col = col },
            .import_trace = .{},
            .allocator = allocator,
        };
    }

    pub fn initSpan(allocator: std.mem.Allocator, kind: ErrorKind, message: []const u8, span: @import("Ast.zig").Span) UzonError {
        return .{
            .kind = kind,
            .message = message,
            .location = .{ .line = span.line, .col = span.col, .end_line = span.end_line, .end_col = span.end_col },
            .import_trace = .{},
            .allocator = allocator,
        };
    }

    pub fn syntaxError(allocator: std.mem.Allocator, message: []const u8, line: u32, col: u32) UzonError {
        return init(allocator, .syntax, message, line, col);
    }

    pub fn typeError(allocator: std.mem.Allocator, message: []const u8, line: u32, col: u32) UzonError {
        return init(allocator, .type_, message, line, col);
    }

    pub fn runtimeError(allocator: std.mem.Allocator, message: []const u8, line: u32, col: u32) UzonError {
        return init(allocator, .runtime, message, line, col);
    }

    pub fn circularError(allocator: std.mem.Allocator, message: []const u8, line: u32, col: u32) UzonError {
        return init(allocator, .circular, message, line, col);
    }

    pub fn deinit(self: *UzonError) void {
        self.import_trace.deinit(self.allocator);
    }

    pub fn write(self: UzonError, writer: anytype) !void {
        const kind_str = switch (self.kind) {
            .syntax => "SyntaxError",
            .circular => "CircularError",
            .type_ => "TypeError",
            .runtime => "RuntimeError",
        };
        try writer.print("{s}: {s}\n  at ", .{ kind_str, self.message });
        try self.location.write(writer);
        for (self.import_trace.items) |loc| {
            try writer.print("\n  imported from ", .{});
            try loc.write(writer);
        }
        if (self.suggestion) |sug| {
            try writer.print("\n  Suggestion: {s}", .{sug});
        }
    }

    pub fn toString(self: UzonError, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        try self.write(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    pub fn dump(self: UzonError) void {
        const msg = self.toString(self.allocator) catch return;
        std.debug.print("{s}\n", .{msg});
    }
};

/// Error union for UZON operations.
pub const Error = error{
    UzonSyntax,
    UzonType,
    UzonRuntime,
    UzonCircular,
    OutOfMemory,
};
