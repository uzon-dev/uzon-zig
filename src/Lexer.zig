const std = @import("std");
const Token = @import("Token.zig");
const err = @import("error.zig");

const Lexer = @This();

/// Lexer mode for string interpolation support.
const Mode = enum {
    normal,
    string,
    interpolation,
};

source: []const u8,
pos: usize,
line: u32,
col: u32,
tokens: std.ArrayListUnmanaged(Token.Token),
mode_stack: std.ArrayListUnmanaged(Mode),
brace_depth: std.ArrayListUnmanaged(usize),
comment_lines: std.ArrayListUnmanaged(u32),
allocator: std.mem.Allocator,
/// Tracks the last emitted token type for context-sensitive minus.
last_token_type: ?Token.Type,

pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
    return .{
        .source = source,
        .pos = 0,
        .line = 1,
        .col = 1,
        .tokens = .{},
        .mode_stack = .{},
        .brace_depth = .{},
        .comment_lines = .{},
        .allocator = allocator,
        .last_token_type = null,
    };
}

pub fn deinit(self: *Lexer) void {
    self.tokens.deinit(self.allocator);
    self.mode_stack.deinit(self.allocator);
    self.brace_depth.deinit(self.allocator);
    self.comment_lines.deinit(self.allocator);
}

pub fn tokenize(self: *Lexer) ![]const Token.Token {
    // Skip BOM (§2.1)
    if (self.source.len >= 3 and self.source[0] == 0xEF and self.source[1] == 0xBB and self.source[2] == 0xBF) {
        self.pos = 3;
    }

    try self.mode_stack.append(self.allocator, .normal);

    while (self.pos < self.source.len) {
        const mode = self.mode_stack.items[self.mode_stack.items.len - 1];
        switch (mode) {
            .normal => try self.scanNormal(),
            .string => try self.scanString(),
            .interpolation => try self.scanInterpolation(),
        }
    }

    try self.emit(.eof, "", self.line, self.col);
    return self.tokens.items;
}

// ── Normal mode ──────────────────────────────────────────────────

fn scanNormal(self: *Lexer) !void {
    self.skipWhitespaceAndComments();
    if (self.pos >= self.source.len) return;

    const c = self.source[self.pos];
    const start_line = self.line;
    const start_col = self.col;

    switch (c) {
        '\n' => {
            try self.emit(.newline, "\n", start_line, start_col);
            self.pos += 1;
            self.line += 1;
            self.col = 1;
        },
        '\r' => {
            self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '\n') {
                try self.emit(.newline, "\r\n", start_line, start_col);
                self.pos += 1;
            } else {
                try self.emit(.newline, "\r", start_line, start_col);
            }
            self.line += 1;
            self.col = 1;
        },
        '"' => {
            try self.mode_stack.append(self.allocator, .string);
            self.advance();
            try self.scanString();
        },
        '{' => {
            try self.emit(.l_brace, "{", start_line, start_col);
            self.advance();
        },
        '}' => {
            try self.emit(.r_brace, "}", start_line, start_col);
            self.advance();
        },
        '[' => {
            try self.emit(.l_bracket, "[", start_line, start_col);
            self.advance();
        },
        ']' => {
            try self.emit(.r_bracket, "]", start_line, start_col);
            self.advance();
        },
        '(' => {
            try self.emit(.l_paren, "(", start_line, start_col);
            self.advance();
        },
        ')' => {
            try self.emit(.r_paren, ")", start_line, start_col);
            self.advance();
        },
        ',' => {
            try self.emit(.comma, ",", start_line, start_col);
            self.advance();
        },
        '.' => {
            try self.emit(.dot, ".", start_line, start_col);
            self.advance();
        },
        '@' => try self.scanKeywordEscape(start_line, start_col),
        '\'' => try self.scanQuotedIdentifier(start_line, start_col),
        '+' => try self.scanPlus(start_line, start_col),
        '*' => try self.scanStar(start_line, start_col),
        '/' => try self.scanSlash(start_line, start_col),
        '%' => {
            try self.emit(.percent, "%", start_line, start_col);
            self.advance();
        },
        '^' => {
            try self.emit(.caret, "^", start_line, start_col);
            self.advance();
        },
        '<' => try self.scanLt(start_line, start_col),
        '>' => try self.scanGt(start_line, start_col),
        '-' => try self.scanMinus(start_line, start_col),
        else => {
            if (isDigit(c)) {
                try self.scanNumber(start_line, start_col);
            } else if (!isWordBoundary(c)) {
                try self.scanIdentifierOrKeyword(start_line, start_col);
            } else {
                // Unknown character — skip
                self.advance();
            }
        },
    }
}

// ── String mode ──────────────────────────────────────────────────

fn scanString(self: *Lexer) !void {
    const str_start_line = self.line;
    const str_start_col = self.col;
    const start = self.pos;

    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        switch (c) {
            '"' => {
                try self.emit(.string, self.source[start..self.pos], str_start_line, str_start_col);
                self.advance();
                _ = self.mode_stack.pop();
                return;
            },
            '\\' => {
                self.advance();
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == 'u' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                        self.advance(); // u
                        self.advance(); // {
                        while (self.pos < self.source.len and self.source[self.pos] != '}') {
                            self.advance();
                        }
                        if (self.pos < self.source.len) self.advance(); // }
                    } else if (self.source[self.pos] == 'x') {
                        self.advance(); // x
                        if (self.pos < self.source.len) self.advance(); // H
                        if (self.pos < self.source.len) self.advance(); // H
                    } else {
                        self.advance();
                    }
                }
            },
            '{' => {
                try self.emit(.string, self.source[start..self.pos], str_start_line, str_start_col);
                try self.emit(.interp_start, "{", self.line, self.col);
                self.advance();
                try self.mode_stack.append(self.allocator, .interpolation);
                try self.brace_depth.append(self.allocator, 0);
                return;
            },
            '\n' => {
                try self.emit(.string, self.source[start..self.pos], str_start_line, str_start_col);
                _ = self.mode_stack.pop();
                return;
            },
            else => self.advance(),
        }
    }

    try self.emit(.string, self.source[start..self.pos], str_start_line, str_start_col);
    _ = self.mode_stack.pop();
}

// ── Interpolation mode ───────────────────────────────────────────

fn scanInterpolation(self: *Lexer) !void {
    self.skipWhitespaceAndComments();
    if (self.pos >= self.source.len) return;

    const c = self.source[self.pos];
    const start_line = self.line;
    const start_col = self.col;

    if (c == '}') {
        const depth_idx = self.brace_depth.items.len - 1;
        if (self.brace_depth.items[depth_idx] == 0) {
            try self.emit(.interp_end, "}", start_line, start_col);
            self.advance();
            _ = self.mode_stack.pop();
            _ = self.brace_depth.pop();
            try self.scanString();
            return;
        } else {
            self.brace_depth.items[depth_idx] -= 1;
            try self.emit(.r_brace, "}", start_line, start_col);
            self.advance();
            return;
        }
    }

    if (c == '{') {
        const depth_idx = self.brace_depth.items.len - 1;
        self.brace_depth.items[depth_idx] += 1;
        try self.emit(.l_brace, "{", start_line, start_col);
        self.advance();
        return;
    }

    if (c == '"') {
        try self.mode_stack.append(self.allocator, .string);
        self.advance();
        try self.scanString();
        return;
    }

    try self.scanNormal();
}

// ── Token scanners ───────────────────────────────────────────────

fn scanPlus(self: *Lexer, line: u32, col: u32) !void {
    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '+') {
        try self.emit(.plus_plus, "++", line, col);
        self.advance();
        self.advance();
    } else {
        try self.emit(.plus_op, "+", line, col);
        self.advance();
    }
}

fn scanStar(self: *Lexer, line: u32, col: u32) !void {
    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
        try self.emit(.star_star, "**", line, col);
        self.advance();
        self.advance();
    } else {
        try self.emit(.star, "*", line, col);
        self.advance();
    }
}

fn scanSlash(self: *Lexer, line: u32, col: u32) !void {
    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
        self.comment_lines.append(self.allocator, self.line) catch {};
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advance();
        }
    } else {
        try self.emit(.slash, "/", line, col);
        self.advance();
    }
}

fn scanLt(self: *Lexer, line: u32, col: u32) !void {
    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
        try self.emit(.le, "<=", line, col);
        self.advance();
        self.advance();
    } else {
        try self.emit(.lt, "<", line, col);
        self.advance();
    }
}

fn scanGt(self: *Lexer, line: u32, col: u32) !void {
    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
        try self.emit(.ge, ">=", line, col);
        self.advance();
        self.advance();
    } else {
        try self.emit(.gt, ">", line, col);
        self.advance();
    }
}

/// Context-sensitive minus (§9 lexer rules):
/// After a value token → binary subtraction
/// Otherwise → negative literal or unary negation
fn scanMinus(self: *Lexer, line: u32, col: u32) !void {
    if (self.last_token_type) |last| {
        if (last.isValueToken()) {
            try self.emit(.minus, "-", line, col);
            self.advance();
            return;
        }
    }

    if (self.pos + 1 < self.source.len) {
        const next = self.source[self.pos + 1];
        if (isDigit(next)) {
            try self.scanNumber(line, col);
            return;
        }
        if (self.pos + 3 < self.source.len) {
            if (std.mem.eql(u8, self.source[self.pos + 1 .. self.pos + 4], "inf")) {
                if (self.pos + 4 >= self.source.len or isWordBoundary(self.source[self.pos + 4])) {
                    try self.emit(.inf, self.source[self.pos .. self.pos + 4], line, col);
                    self.pos += 4;
                    self.col += 4;
                    return;
                }
            }
            if (std.mem.eql(u8, self.source[self.pos + 1 .. self.pos + 4], "nan")) {
                if (self.pos + 4 >= self.source.len or isWordBoundary(self.source[self.pos + 4])) {
                    try self.emit(.nan, self.source[self.pos .. self.pos + 4], line, col);
                    self.pos += 4;
                    self.col += 4;
                    return;
                }
            }
        }
    }

    try self.emit(.minus, "-", line, col);
    self.advance();
}

fn scanNumber(self: *Lexer, line: u32, col: u32) !void {
    const start = self.pos;
    var is_float = false;

    if (self.pos < self.source.len and self.source[self.pos] == '-') {
        self.advance();
    }

    // Check for base prefix
    if (self.pos + 1 < self.source.len and self.source[self.pos] == '0') {
        const prefix = self.source[self.pos + 1];
        if (prefix == 'x' or prefix == 'X') {
            self.advance();
            self.advance();
            while (self.pos < self.source.len and (isHexDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.advance();
            }
            if (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
                self.pos = start;
                self.col = col;
                try self.scanIdentifierOrKeyword(line, col);
                return;
            }
            try self.emit(.integer, self.source[start..self.pos], line, col);
            return;
        }
        if (prefix == 'o' or prefix == 'O') {
            self.advance();
            self.advance();
            while (self.pos < self.source.len and (isOctDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.advance();
            }
            try self.emit(.integer, self.source[start..self.pos], line, col);
            return;
        }
        if (prefix == 'b' or prefix == 'B') {
            self.advance();
            self.advance();
            while (self.pos < self.source.len and (self.source[self.pos] == '0' or self.source[self.pos] == '1' or self.source[self.pos] == '_')) {
                self.advance();
            }
            try self.emit(.integer, self.source[start..self.pos], line, col);
            return;
        }
    }

    while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
        self.advance();
    }

    if (self.pos < self.source.len and self.source[self.pos] == '.') {
        if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            is_float = true;
            self.advance();
            while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.advance();
            }
        }
    }

    if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
        is_float = true;
        self.advance();
        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
            self.advance();
        }
        while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
    }

    // If non-boundary char follows digits, this is an identifier (e.g. "1st")
    if (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
        self.pos = start;
        self.col = col;
        try self.scanIdentifierOrKeyword(line, col);
        return;
    }

    if (is_float) {
        try self.emit(.float, self.source[start..self.pos], line, col);
    } else {
        try self.emit(.integer, self.source[start..self.pos], line, col);
    }
}

fn scanIdentifierOrKeyword(self: *Lexer, line: u32, col: u32) !void {
    const start = self.pos;

    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        if (isWordBoundary(c)) break;
        self.advance();
    }

    const lexeme = self.source[start..self.pos];

    if (Token.keywords.get(lexeme)) |kw_type| {
        // Composite keyword detection (§9 lexer rules)
        switch (kw_type) {
            .@"or" => {
                if (try self.tryCompositeKeyword("else")) {
                    try self.emit(.or_else, "or else", line, col);
                    return;
                }
            },
            .is => {
                if (try self.tryCompositeIs(line, col)) return;
            },
            else => {},
        }
        try self.emit(kw_type, lexeme, line, col);
    } else {
        try self.emit(.identifier, lexeme, line, col);
    }
}

/// Try to form composite keywords starting with "is".
fn tryCompositeIs(self: *Lexer, line: u32, col: u32) !bool {
    const saved_pos = self.pos;
    const saved_line = self.line;
    const saved_col = self.col;

    self.skipWhitespaceNewlinesAndComments();
    if (self.pos >= self.source.len) {
        self.restorePos(saved_pos, saved_line, saved_col);
        return false;
    }

    const next_start = self.pos;
    while (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
        self.advance();
    }
    const next_word = self.source[next_start..self.pos];

    if (std.mem.eql(u8, next_word, "not")) {
        const saved2_pos = self.pos;
        const saved2_line = self.line;
        const saved2_col = self.col;

        self.skipWhitespaceNewlinesAndComments();
        if (self.pos < self.source.len) {
            const third_start = self.pos;
            while (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
                self.advance();
            }
            const third_word = self.source[third_start..self.pos];

            if (std.mem.eql(u8, third_word, "named")) {
                try self.emit(.is_not_named, "is not named", line, col);
                return true;
            }
            if (std.mem.eql(u8, third_word, "type")) {
                try self.emit(.is_not_type, "is not type", line, col);
                return true;
            }
        }
        self.restorePos(saved2_pos, saved2_line, saved2_col);
        try self.emit(.is_not, "is not", line, col);
        return true;
    }

    if (std.mem.eql(u8, next_word, "named")) {
        try self.emit(.is_named, "is named", line, col);
        return true;
    }

    if (std.mem.eql(u8, next_word, "type")) {
        try self.emit(.is_type, "is type", line, col);
        return true;
    }

    self.restorePos(saved_pos, saved_line, saved_col);
    return false;
}

/// Try to form "or else" composite.
fn tryCompositeKeyword(self: *Lexer, expected: []const u8) !bool {
    const saved_pos = self.pos;
    const saved_line = self.line;
    const saved_col = self.col;

    self.skipWhitespaceNewlinesAndComments();
    if (self.pos >= self.source.len) {
        self.restorePos(saved_pos, saved_line, saved_col);
        return false;
    }

    const next_start = self.pos;
    while (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
        self.advance();
    }
    const next_word = self.source[next_start..self.pos];

    if (std.mem.eql(u8, next_word, expected)) {
        return true;
    }

    self.restorePos(saved_pos, saved_line, saved_col);
    return false;
}

fn scanKeywordEscape(self: *Lexer, line: u32, col: u32) !void {
    self.advance(); // skip @
    const start = self.pos;

    while (self.pos < self.source.len and !isWordBoundary(self.source[self.pos])) {
        self.advance();
    }

    const lexeme = self.source[start..self.pos];
    try self.emit(.identifier, lexeme, line, col);
}

fn scanQuotedIdentifier(self: *Lexer, line: u32, col: u32) !void {
    self.advance(); // skip opening '
    const start = self.pos;

    while (self.pos < self.source.len and self.source[self.pos] != '\'' and self.source[self.pos] != '\n') {
        self.advance();
    }

    const content = self.source[start..self.pos];

    if (self.pos < self.source.len and self.source[self.pos] == '\'') {
        self.advance(); // skip closing '
    }

    try self.emit(.quoted_identifier, content, line, col);
}

// ── Helpers ──────────────────────────────────────────────────────

fn emit(self: *Lexer, token_type: Token.Type, lexeme: []const u8, line: u32, col: u32) !void {
    try self.tokens.append(self.allocator, .{
        .type = token_type,
        .lexeme = lexeme,
        .line = line,
        .col = col,
    });
    self.last_token_type = token_type;
}

fn advance(self: *Lexer) void {
    if (self.pos < self.source.len) {
        const c = self.source[self.pos];
        // §11.2: column counts Unicode scalar values — only count leading bytes
        if (c < 0x80 or c >= 0xC0) {
            self.col += 1;
        }
        self.pos += 1;
    }
}

fn skipWhitespaceAndComments(self: *Lexer) void {
    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        if (c == ' ' or c == '\t') {
            self.advance();
        } else if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
            self.comment_lines.append(self.allocator, self.line) catch {};
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.advance();
            }
        } else {
            break;
        }
    }
}

fn skipWhitespaceNewlinesAndComments(self: *Lexer) void {
    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        if (c == ' ' or c == '\t') {
            self.advance();
        } else if (c == '\n') {
            self.pos += 1;
            self.line += 1;
            self.col = 1;
        } else if (c == '\r') {
            self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '\n') {
                self.pos += 1;
            }
            self.line += 1;
            self.col = 1;
        } else if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.advance();
            }
        } else {
            break;
        }
    }
}

fn restorePos(self: *Lexer, pos: usize, line: u32, col: u32) void {
    self.pos = pos;
    self.line = line;
    self.col = col;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// §2.3: Characters that terminate identifiers (whitespace + token boundaries).
fn isWordBoundary(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r',
        '{', '}', '[', ']', '(', ')', ',', '.', '"', '\'', '@',
        '+', '-', '*', '/', '%', '^', '<', '>', '=', '!', '?',
        ':', ';', '|', '&', '$', '~', '#', '\\',
        => true,
        else => false,
    };
}

// ── Tests ────────────────────────────────────────────────────────

test "tokenize simple binding" {
    var lexer = Lexer.init(std.testing.allocator, "x is 42");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(4, tokens.len);
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqualStrings("x", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.is, tokens[1].type);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
    try std.testing.expectEqualStrings("42", tokens[2].lexeme);
    try std.testing.expectEqual(Token.Type.eof, tokens[3].type);
}

test "tokenize composite keywords" {
    var lexer = Lexer.init(std.testing.allocator, "x is not 0");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqual(Token.Type.is_not, tokens[1].type);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
}

test "tokenize or else across newline" {
    var lexer = Lexer.init(std.testing.allocator, "x or\nelse 1");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqual(Token.Type.or_else, tokens[1].type);
}

test "tokenize negative number" {
    var lexer = Lexer.init(std.testing.allocator, "x is -42");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqual(Token.Type.is, tokens[1].type);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
    try std.testing.expectEqualStrings("-42", tokens[2].lexeme);
}

test "tokenize binary minus" {
    var lexer = Lexer.init(std.testing.allocator, "3 - 5");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.integer, tokens[0].type);
    try std.testing.expectEqual(Token.Type.minus, tokens[1].type);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
    try std.testing.expectEqualStrings("5", tokens[2].lexeme);
}

test "tokenize string interpolation" {
    const source = "\"hello {name}!\"";
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello ", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.interp_start, tokens[1].type);
    try std.testing.expectEqual(Token.Type.identifier, tokens[2].type);
    try std.testing.expectEqualStrings("name", tokens[2].lexeme);
    try std.testing.expectEqual(Token.Type.interp_end, tokens[3].type);
    try std.testing.expectEqual(Token.Type.string, tokens[4].type);
    try std.testing.expectEqualStrings("!", tokens[4].lexeme);
}

test "tokenize keyword escape" {
    var lexer = Lexer.init(std.testing.allocator, "@is is 3");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqualStrings("is", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.is, tokens[1].type);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
}

test "tokenize hex and binary integers" {
    var lexer = Lexer.init(std.testing.allocator, "0xFF 0b1010 0o17");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.integer, tokens[0].type);
    try std.testing.expectEqualStrings("0xFF", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.integer, tokens[1].type);
    try std.testing.expectEqualStrings("0b1010", tokens[1].lexeme);
    try std.testing.expectEqual(Token.Type.integer, tokens[2].type);
    try std.testing.expectEqualStrings("0o17", tokens[2].lexeme);
}

test "tokenize float with exponent" {
    var lexer = Lexer.init(std.testing.allocator, "3.14 1.0e10 2.5E-3");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.float, tokens[0].type);
    try std.testing.expectEqualStrings("3.14", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.float, tokens[1].type);
    try std.testing.expectEqualStrings("1.0e10", tokens[1].lexeme);
    try std.testing.expectEqual(Token.Type.float, tokens[2].type);
    try std.testing.expectEqualStrings("2.5E-3", tokens[2].lexeme);
}

test "identifier starting with digit (1st)" {
    var lexer = Lexer.init(std.testing.allocator, "1st is 1");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.identifier, tokens[0].type);
    try std.testing.expectEqualStrings("1st", tokens[0].lexeme);
}

test "quoted identifier" {
    var lexer = Lexer.init(std.testing.allocator, "'Content-Type' is \"json\"");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(Token.Type.quoted_identifier, tokens[0].type);
    try std.testing.expectEqualStrings("Content-Type", tokens[0].lexeme);
    try std.testing.expectEqual(Token.Type.is, tokens[1].type);
    try std.testing.expectEqual(Token.Type.string, tokens[2].type);
}
