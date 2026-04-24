const std = @import("std");
const Token = @import("Token.zig");
const Ast = @import("Ast.zig");
const err_mod = @import("error.zig");
const UzonError = err_mod.UzonError;

const Parser = @This();

pub const Error = error{ UzonSyntax, OutOfMemory };

tokens: []const Token.Token,
pos: usize,
allocator: std.mem.Allocator,
suppress_as: bool,
suppress_multiline_string: bool,
comment_lines: []const u32,
last_error: ?UzonError,

pub fn init(allocator: std.mem.Allocator, tokens: []const Token.Token, comment_lines: []const u32) Parser {
    return .{
        .tokens = tokens,
        .pos = 0,
        .allocator = allocator,
        .suppress_as = false,
        .suppress_multiline_string = false,
        .comment_lines = comment_lines,
        .last_error = null,
    };
}

// ── Core helpers ────────────────────────────────────────────

fn peek(self: *const Parser) Token.Token {
    if (self.pos < self.tokens.len) return self.tokens[self.pos];
    return .{ .type = .eof, .lexeme = "", .line = 0, .col = 0 };
}

fn at(self: *const Parser, tt: Token.Type) bool {
    return self.peek().type == tt;
}

fn advance(self: *Parser) Token.Token {
    const tok = self.peek();
    if (self.pos < self.tokens.len) self.pos += 1;
    return tok;
}

fn expect(self: *Parser, tt: Token.Type) Error!Token.Token {
    if (!self.at(tt)) {
        const tok = self.peek();
        return self.fail("unexpected token", tok.line, tok.col);
    }
    return self.advance();
}

fn eat(self: *Parser, tt: Token.Type) bool {
    if (self.at(tt)) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn skipNewlines(self: *Parser) void {
    while (self.at(.newline)) _ = self.advance();
}

fn prevLine(self: *const Parser) u32 {
    return if (self.pos > 0) self.tokens[self.pos - 1].line else 1;
}

fn span(self: *const Parser) Ast.Span {
    const tok = self.peek();
    return .{ .line = tok.line, .col = tok.col };
}

/// Create a span from `start` to the end of the previous token.
fn endSpan(self: *const Parser, start: Ast.Span) Ast.Span {
    if (self.pos > 0) {
        const prev = self.tokens[self.pos - 1];
        return .{ .line = start.line, .col = start.col, .end_line = prev.line, .end_col = prev.col + @as(u32, @intCast(prev.lexeme.len)) };
    }
    return start;
}

fn node(self: *Parser, kind: Ast.Node.Kind, s: Ast.Span) Error!*const Ast.Node {
    const n = try self.allocator.create(Ast.Node);
    n.* = .{ .kind = kind, .span = s };
    return n;
}

fn fail(self: *Parser, message: []const u8, line: u32, col: u32) error{UzonSyntax} {
    self.last_error = UzonError.syntaxError(self.allocator, message, line, col);
    return error.UzonSyntax;
}

fn failSug(self: *Parser, message: []const u8, suggestion: []const u8, line: u32, col: u32) error{UzonSyntax} {
    self.last_error = UzonError.initWithSuggestion(self.allocator, .syntax, message, suggestion, line, col);
    return error.UzonSyntax;
}

// ── Entry point ─────────────────────────────────────────────

pub fn parse(self: *Parser) Error!Ast.Document {
    const s = self.span();
    const bindings = try self.parseBindings(.eof);
    return .{ .bindings = bindings, .span = s };
}

fn parseBindings(self: *Parser, until: Token.Type) Error![]const Ast.Binding {
    var list = std.ArrayListUnmanaged(Ast.Binding){};
    self.skipNewlines();
    while (!self.at(until) and !self.at(.eof)) {
        try list.append(self.allocator, try self.parseBinding());
        _ = self.skipSeparator();
    }
    return list.items;
}

fn parseBinding(self: *Parser) Error!Ast.Binding {
    const tok = self.peek();

    if (tok.type != .identifier and tok.type != .quoted_identifier) {
        if (tok.type.isKeyword()) {
            const sug = std.fmt.allocPrint(self.allocator, "use @{s} to escape the keyword", .{tok.lexeme}) catch
                return self.fail("cannot use keyword as binding name", tok.line, tok.col);
            return self.failSug("cannot use keyword as binding name", sug, tok.line, tok.col);
        }
        return self.fail("expected identifier", tok.line, tok.col);
    }

    const name_tok = self.advance();
    const s = Ast.Span{ .line = name_tok.line, .col = name_tok.col };
    self.skipNewlines();

    // `are` binding (§3.4.1)
    if (self.at(.are)) {
        _ = self.advance();
        self.skipNewlines();
        return self.parseAreBinding(name_tok.lexeme, s);
    }

    // Composite token decomposition at binding position (§9)
    const bt = self.peek();
    switch (bt.type) {
        .is => {
            _ = self.advance();
            self.skipNewlines();
        },
        .is_not => {
            _ = self.advance();
            self.skipNewlines();
            const inner = try self.parseExpression();
            const not_node = try self.node(.{ .unary_op = .{ .op = .not, .operand = inner } }, .{ .line = bt.line, .col = bt.col });
            return .{ .name = name_tok.lexeme, .value = not_node, .called = try self.tryParseCalled(), .is_are = false, .list_type_annotation = null, .span = s };
        },
        .is_named => {
            _ = self.advance();
            self.skipNewlines();
            const ident = try self.node(.{ .identifier = .{ .name = "named" } }, .{ .line = bt.line, .col = bt.col });
            return .{ .name = name_tok.lexeme, .value = try self.continueFromTypeDecl(ident), .called = try self.tryParseCalled(), .is_are = false, .list_type_annotation = null, .span = s };
        },
        .is_type => {
            _ = self.advance();
            self.skipNewlines();
            const ident = try self.node(.{ .identifier = .{ .name = "type" } }, .{ .line = bt.line, .col = bt.col });
            return .{ .name = name_tok.lexeme, .value = try self.continueFromTypeDecl(ident), .called = try self.tryParseCalled(), .is_are = false, .list_type_annotation = null, .span = s };
        },
        .is_not_named, .is_not_type => {
            return self.failSug("invalid composite at binding position", "wrap in parentheses", bt.line, bt.col);
        },
        else => {
            if (bt.type == .identifier) {
                if (Token.findCaseInsensitiveKeyword(bt.lexeme)) |kw| {
                    const msg = std.fmt.allocPrint(self.allocator, "expected 'is' or 'are', found '{s}'", .{bt.lexeme}) catch
                        return self.fail("expected 'is' or 'are'", bt.line, bt.col);
                    const sug = std.fmt.allocPrint(self.allocator, "did you mean '{s}'?", .{kw}) catch
                        return self.fail(msg, bt.line, bt.col);
                    return self.failSug(msg, sug, bt.line, bt.col);
                }
            }
            return self.fail("expected 'is' or 'are'", bt.line, bt.col);
        },
    }

    // `is of` — field extraction (§5.14)
    if (self.at(.of)) {
        _ = self.advance();
        self.skipNewlines();
        const source = try self.parseMemberAccess();
        return .{ .name = name_tok.lexeme, .value = try self.node(.{ .field_extraction = .{ .source = source } }, s), .called = null, .is_are = false, .list_type_annotation = null, .span = s };
    }

    // Standalone type declarations (§3.2, §3.5, §3.6, §3.7)
    // — `is struct { ... }`, `is enum ...`, `is union ...`, `is tagged union ...`
    if (self.at(.struct_) and self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].type == .l_brace) {
        _ = self.advance(); // struct
        self.skipNewlines();
        const value = try self.parseStructLiteral();
        return .{ .name = name_tok.lexeme, .value = value, .called = name_tok.lexeme, .is_are = false, .list_type_annotation = null, .span = s };
    }
    if (self.at(.enum_)) {
        _ = self.advance();
        self.skipNewlines();
        const value = try self.parseStandaloneEnum(s);
        return .{ .name = name_tok.lexeme, .value = value, .called = name_tok.lexeme, .is_are = false, .list_type_annotation = null, .span = s };
    }
    if (self.at(.tagged)) {
        _ = self.advance();
        self.skipNewlines();
        _ = try self.expect(.union_);
        self.skipNewlines();
        const value = try self.parseStandaloneTaggedUnion(s);
        return .{ .name = name_tok.lexeme, .value = value, .called = name_tok.lexeme, .is_are = false, .list_type_annotation = null, .span = s };
    }
    if (self.at(.union_)) {
        _ = self.advance();
        self.skipNewlines();
        const value = try self.parseStandaloneUnion(s);
        return .{ .name = name_tok.lexeme, .value = value, .called = name_tok.lexeme, .is_are = false, .list_type_annotation = null, .span = s };
    }

    const value = try self.parseExpression();
    return .{ .name = name_tok.lexeme, .value = value, .called = try self.tryParseCalled(), .is_are = false, .list_type_annotation = null, .span = s };
}

fn parseAreBinding(self: *Parser, name: []const u8, s: Ast.Span) Error!Ast.Binding {
    var elements = std.ArrayListUnmanaged(*const Ast.Node){};
    const first_pos = self.pos;
    try elements.append(self.allocator, try self.parseExpression());

    while (true) {
        self.skipNewlines();
        if (!self.at(.comma)) break;
        _ = self.advance();
        self.skipNewlines();
        // §3.4.1: `are` does not permit trailing commas
        if (self.at(.eof) or self.at(.r_brace) or self.at(.r_bracket) or self.at(.r_paren) or self.at(.called)) {
            const t = self.tokens[self.pos];
            return self.fail("trailing comma in 'are' binding", t.line, t.col);
        }
        try elements.append(self.allocator, try self.parseExpression());
    }

    // List-level `as` disambiguation
    var list_type: ?Ast.TypeExpr = null;
    if (self.peekPastNewlines(.as)) {
        self.skipNewlines();
        _ = self.advance();
        self.skipNewlines();
        list_type = try self.parseTypeExpr();
    } else if (elements.items.len == 1 and std.meta.activeTag(elements.items[0].kind) == .type_annotation) {
        // Re-parse single element with suppress_as
        self.pos = first_pos;
        elements.items.len = 0;
        self.suppress_as = true;
        try elements.append(self.allocator, try self.parseExpression());
        self.suppress_as = false;
        self.skipNewlines();
        if (self.eat(.as)) {
            self.skipNewlines();
            list_type = try self.parseTypeExpr();
        }
    } else if (elements.items.len > 1) {
        const last = elements.items[elements.items.len - 1];
        if (std.meta.activeTag(last.kind) == .type_annotation) {
            elements.items[elements.items.len - 1] = last.kind.type_annotation.expr;
            list_type = last.kind.type_annotation.type_expr;
        }
    }

    return .{
        .name = name,
        .value = try self.node(.{ .list_literal = .{ .elements = elements.items } }, s),
        .called = try self.tryParseCalled(),
        .is_are = true,
        .list_type_annotation = list_type,
        .span = s,
    };
}

fn tryParseCalled(self: *Parser) Error!?[]const u8 {
    self.skipNewlines();
    if (self.eat(.called)) {
        self.skipNewlines();
        return (try self.expect(.identifier)).lexeme;
    }
    return null;
}

// ── Separator handling ──────────────────────────────────────

fn skipSeparator(self: *Parser) bool {
    var found = false;
    while (true) {
        if (self.eat(.comma)) {
            found = true;
            self.skipNewlines();
        } else if (self.at(.newline)) {
            var look = self.pos + 1;
            while (look < self.tokens.len and self.tokens[look].type == .newline) look += 1;
            if (look >= self.tokens.len or self.tokens[look].type == .eof or
                self.tokens[look].type == .r_brace or self.isBindingStartAt(look))
            {
                self.skipNewlines();
                found = true;
            } else {
                self.skipNewlines();
            }
        } else break;
    }
    return found;
}

fn isBindingStartAt(self: *const Parser, pos: usize) bool {
    return self.looksLikeBinding(pos, true);
}

fn isFuncBindingStartAt(self: *const Parser, pos: usize) bool {
    const p = @min(pos, self.tokens.len - 1);
    const tok = self.tokens[p];
    if (tok.type != .identifier and tok.type != .quoted_identifier) return false;
    var next = p + 1;
    while (next < self.tokens.len and self.tokens[next].type == .newline) next += 1;
    return next < self.tokens.len and self.tokens[next].type == .is;
}

fn looksLikeBinding(self: *const Parser, pos: usize, allow_are: bool) bool {
    const p = @min(pos, self.tokens.len - 1);
    const tok = self.tokens[p];
    if (tok.type != .identifier and tok.type != .quoted_identifier) return false;
    var next = p + 1;
    while (next < self.tokens.len and self.tokens[next].type == .newline) next += 1;
    if (next >= self.tokens.len) return false;
    const nt = self.tokens[next].type;
    return nt == .is or nt == .is_not or nt == .is_named or nt == .is_type or
        nt == .is_not_named or nt == .is_not_type or (allow_are and nt == .are);
}

fn peekPastNewlines(self: *const Parser, tt: Token.Type) bool {
    var look = self.pos;
    while (look < self.tokens.len and self.tokens[look].type == .newline) look += 1;
    return look < self.tokens.len and self.tokens[look].type == tt;
}

// ── Expression chain (§5.5 precedence) ─────────────────────

fn parseExpression(self: *Parser) Error!*const Ast.Node {
    return self.parseOrElse();
}

// Level 18: or else
fn parseOrElse(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseOr();
    while (blk: {
        self.skipNewlines();
        break :blk self.at(.or_else);
    }) {
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseOr();
        left = try self.node(.{ .or_else = .{ .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

// Level 17: or
fn parseOr(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseAnd();
    while (blk: {
        self.skipNewlines();
        break :blk self.at(.@"or");
    }) {
        _ = self.advance();
        self.skipNewlines();
        const right_or = try self.parseAnd();
        left = try self.node(.{ .binary_op = .{ .op = .@"or", .left = left, .right = right_or } }, self.endSpan(left.span));
    }
    return left;
}

// Level 16: and
fn parseAnd(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseNot();
    while (blk: {
        self.skipNewlines();
        break :blk self.at(.@"and");
    }) {
        _ = self.advance();
        self.skipNewlines();
        const right_and = try self.parseNot();
        left = try self.node(.{ .binary_op = .{ .op = .@"and", .left = left, .right = right_and } }, self.endSpan(left.span));
    }
    return left;
}

// Level 15: not
fn parseNot(self: *Parser) Error!*const Ast.Node {
    if (self.at(.not)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        const operand = try self.parseNot();
        return self.node(.{ .unary_op = .{ .op = .not, .operand = operand } }, self.endSpan(s));
    }
    return self.parseEquality();
}

// Level 14: is, is not, is named, is not named, is type, is not type
fn parseEquality(self: *Parser) Error!*const Ast.Node {
    const left = try self.parseMembership();
    self.skipNewlines();
    const op: ?Ast.BinaryOp = switch (self.peek().type) {
        .is => .eq,
        .is_not => .neq,
        .is_named => .is_named,
        .is_not_named => .is_not_named,
        .is_type => .is_type,
        .is_not_type => .is_not_type,
        else => null,
    };
    if (op) |binary_op| {
        const is_name_or_type = switch (binary_op) {
            .is_named, .is_not_named, .is_type, .is_not_type => true,
            else => false,
        };
        _ = self.advance();
        self.skipNewlines();
        const right = if (is_name_or_type) blk: {
            // §5.2: `is type` / `is not type` accepts compound type expressions on the RHS
            // ([T], (T,T,…), null). For those, parse a full TypeExpr and wrap as type_pattern.
            const accepts_compound = (binary_op == .is_type or binary_op == .is_not_type);
            if (accepts_compound and (self.at(.l_bracket) or self.at(.l_paren) or self.at(.null_))) {
                const te_span = self.span();
                const te = try self.parseTypeExpr();
                break :blk try self.node(.{ .type_pattern = .{ .type_expr = te } }, te_span);
            }
            const t = self.advance();
            // §7.3: `is type` / `is not type` accepts a qualified type name like `m.Point`
            // so imported nominal types can be tested. `is named` / `is not named` still
            // takes a plain variant name (no dots).
            if (accepts_compound and self.at(.dot)) {
                var buf = std.ArrayListUnmanaged(u8){};
                try buf.appendSlice(self.allocator, t.lexeme);
                while (self.at(.dot)) {
                    _ = self.advance();
                    const next = try self.expect(.identifier);
                    try buf.append(self.allocator, '.');
                    try buf.appendSlice(self.allocator, next.lexeme);
                }
                break :blk try self.node(.{ .identifier = .{ .name = buf.items } }, .{ .line = t.line, .col = t.col });
            }
            break :blk try self.node(.{ .identifier = .{ .name = t.lexeme } }, .{ .line = t.line, .col = t.col });
        } else try self.parseMembership();
        // §5.1: at most one equality operator per expression — chaining is a syntax error.
        self.skipNewlines();
        switch (self.peek().type) {
            .is, .is_not, .is_named, .is_not_named, .is_type, .is_not_type => {
                const tok = self.peek();
                return self.failSug("chained equality is not permitted", "parenthesize to make evaluation order explicit", tok.line, tok.col);
            },
            else => {},
        }
        return self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

// Level 13: in
fn parseMembership(self: *Parser) Error!*const Ast.Node {
    const left = try self.parseRelational();
    self.skipNewlines();
    if (self.at(.in_)) {
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseRelational();
        return self.node(.{ .binary_op = .{ .op = .in_, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

// Level 12: <, <=, >, >=
fn parseRelational(self: *Parser) Error!*const Ast.Node {
    const left = try self.parseConcat();
    self.skipNewlines();
    const op: ?Ast.BinaryOp = switch (self.peek().type) {
        .lt => .lt, .le => .le, .gt => .gt, .ge => .ge, else => null,
    };
    if (op) |binary_op| {
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseConcat();
        return self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

// Level 11: ++
fn parseConcat(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseBitOr();
    while (blk: {
        self.skipNewlines();
        break :blk self.at(.plus_plus);
    }) {
        _ = self.advance();
        self.skipNewlines();
        const right_cc = try self.parseBitOr();
        left = try self.node(.{ .binary_op = .{ .op = .concat, .left = left, .right = right_cc } }, self.endSpan(left.span));
    }
    return left;
}

// §5.3a bitwise levels, precedence low→high: | < ^ < & < shift < additive
fn parseBitOr(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseBitXor();
    while (true) {
        self.skipNewlines();
        if (!self.at(.pipe)) break;
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseBitXor();
        left = try self.node(.{ .binary_op = .{ .op = .bit_or, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

fn parseBitXor(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseBitAnd();
    while (true) {
        self.skipNewlines();
        if (!self.at(.caret)) break;
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseBitAnd();
        left = try self.node(.{ .binary_op = .{ .op = .bit_xor, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

fn parseBitAnd(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseShift();
    while (true) {
        self.skipNewlines();
        if (!self.at(.amp)) break;
        _ = self.advance();
        self.skipNewlines();
        const right = try self.parseShift();
        left = try self.node(.{ .binary_op = .{ .op = .bit_and, .left = left, .right = right } }, self.endSpan(left.span));
    }
    return left;
}

fn parseShift(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseAddition();
    while (true) {
        self.skipNewlines();
        const op: ?Ast.BinaryOp = switch (self.peek().type) {
            .lshift => .shl, .rshift => .shr, else => null,
        };
        if (op) |bo| {
            _ = self.advance();
            self.skipNewlines();
            const right = try self.parseAddition();
            left = try self.node(.{ .binary_op = .{ .op = bo, .left = left, .right = right } }, self.endSpan(left.span));
        } else break;
    }
    return left;
}

// Level 10: +, -
fn parseAddition(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseMultiplication();
    while (true) {
        self.skipNewlines();
        const op: ?Ast.BinaryOp = switch (self.peek().type) {
            .plus_op => .add, .minus => .sub, else => null,
        };
        if (op) |binary_op| {
            _ = self.advance();
            self.skipNewlines();
            const right_add = try self.parseMultiplication();
            left = try self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = right_add } }, self.endSpan(left.span));
        } else break;
    }
    return left;
}

// Level 9: *, /, %
fn parseMultiplication(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseUnary();
    while (true) {
        self.skipNewlines();
        const op: ?Ast.BinaryOp = switch (self.peek().type) {
            .star => .mul, .slash => .div, .percent => .mod_, else => null,
        };
        if (op) |binary_op| {
            _ = self.advance();
            self.skipNewlines();
            const right_mul = try self.parseUnary();
            left = try self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = right_mul } }, self.endSpan(left.span));
        } else break;
    }
    return left;
}

// Level 8: unary -, ~ (§5.3a)
fn parseUnary(self: *Parser) Error!*const Ast.Node {
    if (self.at(.minus)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        const operand = try self.parseTypeDecl();
        return self.node(.{ .unary_op = .{ .op = .negate, .operand = operand } }, self.endSpan(s));
    }
    if (self.at(.tilde)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        const operand = try self.parseTypeDecl();
        return self.node(.{ .unary_op = .{ .op = .bit_not, .operand = operand } }, self.endSpan(s));
    }
    return self.parseTypeDecl();
}

// ── Type declarations (levels 2-6) ─────────────────────────

fn parseTypeDecl(self: *Parser) Error!*const Ast.Node {
    const expr = try self.parseTypeAnnotation();
    // NEWLINE_SEP: don't consume from/named if a new binding starts
    if (self.at(.newline)) {
        var look = self.pos;
        while (look < self.tokens.len and self.tokens[look].type == .newline) look += 1;
        if (look < self.tokens.len and self.isBindingStartAt(look)) return expr;
    }
    self.skipNewlines();
    if (self.at(.from)) return self.parseFromClause(expr);
    if (self.at(.named)) return self.parseNamedClause(expr);
    return expr;
}

fn continueFromTypeDecl(self: *Parser, expr: *const Ast.Node) Error!*const Ast.Node {
    self.skipNewlines();
    if (self.at(.from)) return self.parseFromClause(expr);
    if (self.at(.named)) return self.parseNamedClause(expr);
    return expr;
}

// Level 4: as
fn parseTypeAnnotation(self: *Parser) Error!*const Ast.Node {
    const expr = try self.parseStructOverride();
    if (self.suppress_as) return expr;
    self.skipNewlines();
    if (self.at(.as)) {
        _ = self.advance();
        self.skipNewlines();
        const te = try self.parseTypeExpr();
        var result = try self.node(.{ .type_annotation = .{ .expr = expr, .type_expr = te } }, self.endSpan(expr.span));
        // Allow chained `to` after `as`
        self.skipNewlines();
        if (self.at(.to)) {
            _ = self.advance();
            self.skipNewlines();
            const to_te = try self.parseTypeExpr();
            result = try self.node(.{ .conversion = .{ .expr = result, .type_expr = to_te } }, self.endSpan(result.span));
        }
        return result;
    }
    return expr;
}

// Level 3: with, plus
fn parseStructOverride(self: *Parser) Error!*const Ast.Node {
    const expr = try self.parseConversion();
    self.skipNewlines();
    if (self.at(.with) or self.at(.plus)) {
        const is_ext = self.at(.plus);
        _ = self.advance();
        self.skipNewlines();
        const rhs = try self.parseStructLiteral();
        const full_span = self.endSpan(expr.span);
        self.skipNewlines();
        if (self.at(.with) or self.at(.plus)) {
            const t = self.peek();
            return self.failSug("cannot chain 'with'/'plus'", "use an intermediate binding", t.line, t.col);
        }
        return if (is_ext)
            self.node(.{ .struct_extension = .{ .base = expr, .extension = rhs } }, full_span)
        else
            self.node(.{ .struct_override = .{ .base = expr, .overrides = rhs } }, full_span);
    }
    return expr;
}

// Level 2: to
fn parseConversion(self: *Parser) Error!*const Ast.Node {
    const expr = try self.parseCallOrAccess();
    self.skipNewlines();
    if (self.at(.to)) {
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .conversion = .{ .expr = expr, .type_expr = try self.parseTypeExpr() } }, self.endSpan(expr.span));
    }
    return expr;
}

// Level 1: member access (.) and function call ()
fn parseCallOrAccess(self: *Parser) Error!*const Ast.Node {
    var expr = try self.parsePrimary();
    while (true) {
        const callee_line = self.prevLine();
        self.skipNewlines();
        if (self.at(.dot)) {
            _ = self.advance();
            const m = self.advance();
            expr = try self.node(.{ .member_access = .{ .object = expr, .member = m.lexeme } }, self.endSpan(expr.span));
        } else if (self.at(.l_paren) and self.peek().line == callee_line) {
            // §5.15: ( on same line → function call
            _ = self.advance();
            self.skipNewlines();
            var args = std.ArrayListUnmanaged(*const Ast.Node){};
            if (!self.at(.r_paren)) {
                try args.append(self.allocator, try self.parseExpression());
                while (self.skipNewlinesEat(.comma)) {
                    self.skipNewlines();
                    if (self.at(.r_paren)) break;
                    try args.append(self.allocator, try self.parseExpression());
                }
            }
            self.skipNewlines();
            _ = try self.expect(.r_paren);
            expr = try self.node(.{ .function_call = .{ .callee = expr, .args = args.items } }, self.endSpan(expr.span));
        } else break;
    }
    return expr;
}

fn parseMemberAccess(self: *Parser) Error!*const Ast.Node {
    var expr = try self.parsePrimary();
    while (true) {
        self.skipNewlines();
        if (!self.at(.dot)) break;
        _ = self.advance();
        const m = self.advance();
        expr = try self.node(.{ .member_access = .{ .object = expr, .member = m.lexeme } }, self.endSpan(expr.span));
    }
    return expr;
}

fn skipNewlinesEat(self: *Parser, tt: Token.Type) bool {
    self.skipNewlines();
    return self.eat(tt);
}

// ── Primary expressions ─────────────────────────────────────

fn parsePrimary(self: *Parser) Error!*const Ast.Node {
    const tok = self.peek();
    const s = Ast.Span{ .line = tok.line, .col = tok.col };

    return switch (tok.type) {
        .integer => blk: {
            _ = self.advance();
            break :blk self.node(.{ .integer_literal = .{ .value = tok.lexeme } }, s);
        },
        .float => blk: {
            _ = self.advance();
            break :blk self.node(.{ .float_literal = .{ .value = tok.lexeme } }, s);
        },
        .string, .interp_start => self.parseStringLiteral(),
        .true_ => blk: {
            _ = self.advance();
            break :blk self.node(.{ .bool_literal = .{ .value = true } }, s);
        },
        .false_ => blk: {
            _ = self.advance();
            break :blk self.node(.{ .bool_literal = .{ .value = false } }, s);
        },
        .null_ => blk: {
            _ = self.advance();
            break :blk self.node(.null_literal, s);
        },
        .undefined => blk: {
            _ = self.advance();
            break :blk self.node(.undefined_literal, s);
        },
        .inf => blk: {
            _ = self.advance();
            break :blk self.node(.{ .inf_literal = .{ .negative = tok.lexeme.len > 0 and tok.lexeme[0] == '-' } }, s);
        },
        .nan => blk: {
            _ = self.advance();
            break :blk self.node(.nan_literal, s);
        },
        .env => blk: {
            _ = self.advance();
            break :blk self.node(.env_ref, s);
        },
        .identifier, .quoted_identifier => blk: {
            _ = self.advance();
            // §3.7 variant shorthand: `ident primary` on same line.
            // Exclude `(` — that form goes through the function_call postfix path (spec §9 call_or_access).
            // Exclude `[` — `ident [ ... ]` is not a shorthand (ambiguous with potential future index access
            //   and no useful inner form today). Users should use struct/string/ident/literal primaries.
            if (self.pos < self.tokens.len) {
                const nt = self.tokens[self.pos];
                if (nt.line == tok.line and isShorthandInnerStart(nt.type)) {
                    const inner = try self.parsePrimary();
                    break :blk self.node(.{ .variant_shorthand = .{ .variant = tok.lexeme, .inner = inner } }, self.endSpan(s));
                }
            }
            break :blk self.node(.{ .identifier = .{ .name = tok.lexeme } }, s);
        },
        .l_brace => self.parseStructLiteral(),
        .l_bracket => self.parseListLiteral(),
        .l_paren => self.parseTupleOrGroup(),
        .if_ => self.parseIfExpr(),
        .case => self.parseCaseExpr(),
        .struct_ => self.parseStructImport(),
        .function => self.parseFunctionExpr(),
        else => self.fail("unexpected token", tok.line, tok.col),
    };
}

fn isPrimaryStart(tt: Token.Type) bool {
    return switch (tt) {
        .integer, .float, .string, .interp_start, .true_, .false_, .null_, .undefined,
        .inf, .nan, .env, .identifier, .quoted_identifier, .l_brace, .l_bracket, .l_paren,
        .if_, .case, .struct_, .function => true,
        else => false,
    };
}

fn isShorthandInnerStart(tt: Token.Type) bool {
    return switch (tt) {
        .integer, .float, .string, .interp_start, .true_, .false_, .null_, .undefined,
        .inf, .nan, .env, .identifier, .quoted_identifier, .l_brace, .l_bracket,
        .if_, .case, .struct_, .function => true,
        else => false,
    };
}

fn parseStructLiteral(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.l_brace);
    const s = Ast.Span{ .line = tok.line, .col = tok.col };
    const saved = self.suppress_as;
    self.suppress_as = false;
    const fields = try self.parseBindings(.r_brace);
    _ = try self.expect(.r_brace);
    self.suppress_as = saved;
    return self.node(.{ .struct_literal = .{ .fields = fields } }, self.endSpan(s));
}

fn parseListLiteral(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.l_bracket);
    self.skipNewlines();
    var elements = std.ArrayListUnmanaged(*const Ast.Node){};
    if (!self.at(.r_bracket)) {
        try elements.append(self.allocator, try self.parseExpression());
        while (self.skipNewlinesEat(.comma)) {
            self.skipNewlines();
            if (self.at(.r_bracket)) break;
            try elements.append(self.allocator, try self.parseExpression());
        }
    }
    self.skipNewlines();
    _ = try self.expect(.r_bracket);
    return self.node(.{ .list_literal = .{ .elements = elements.items } }, self.endSpan(.{ .line = tok.line, .col = tok.col }));
}

fn parseTupleOrGroup(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.l_paren);
    const s = Ast.Span{ .line = tok.line, .col = tok.col };
    self.skipNewlines();

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .tuple_literal = .{ .elements = &.{} } }, self.endSpan(s));
    }

    const first = try self.parseExpression();
    self.skipNewlines();

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .grouping = .{ .expr = first } }, self.endSpan(s));
    }

    _ = try self.expect(.comma);
    self.skipNewlines();
    var elements = std.ArrayListUnmanaged(*const Ast.Node){};
    try elements.append(self.allocator, first);

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .tuple_literal = .{ .elements = elements.items } }, self.endSpan(s));
    }

    try elements.append(self.allocator, try self.parseExpression());
    while (self.skipNewlinesEat(.comma)) {
        self.skipNewlines();
        if (self.at(.r_paren)) break;
        try elements.append(self.allocator, try self.parseExpression());
    }
    self.skipNewlines();
    _ = try self.expect(.r_paren);
    return self.node(.{ .tuple_literal = .{ .elements = elements.items } }, self.endSpan(s));
}

fn parseStringLiteral(self: *Parser) Error!*const Ast.Node {
    const s = Ast.Span{ .line = self.peek().line, .col = self.peek().col };
    var parts = std.ArrayListUnmanaged(Ast.StringPart){};
    try self.parseStringSegment(&parts);

    while (!self.suppress_multiline_string) {
        if (!self.at(.newline)) break;
        const saved = self.pos;
        _ = self.advance();

        if (self.at(.newline) or self.at(.eof)) {
            // Check for comment between multiline parts
            const string_end_line = self.tokens[saved].line;
            var peek_pos = self.pos;
            while (peek_pos < self.tokens.len and self.tokens[peek_pos].type == .newline) peek_pos += 1;
            if (peek_pos < self.tokens.len) {
                const nt = self.tokens[peek_pos];
                if (nt.type == .string or nt.type == .interp_start) {
                    for (self.comment_lines) |cl| {
                        if (cl > string_end_line and cl < nt.line)
                            return self.fail("comment between multiline string parts is not allowed", nt.line, nt.col);
                    }
                }
            }
            self.pos = saved;
            break;
        }

        if (self.at(.string) or self.at(.interp_start)) {
            try parts.append(self.allocator, .{ .literal = "\n" });
            try self.parseStringSegment(&parts);
        } else {
            self.pos = saved;
            break;
        }
    }

    return self.node(.{ .string_literal = .{ .parts = parts.items } }, self.endSpan(s));
}

fn parseStringSegment(self: *Parser, parts: *std.ArrayListUnmanaged(Ast.StringPart)) Error!void {
    while (true) {
        switch (self.peek().type) {
            .string => {
                const tok = self.advance();
                if (tok.lexeme.len > 0) try parts.append(self.allocator, .{ .literal = tok.lexeme });
            },
            .interp_start => {
                _ = self.advance();
                self.skipNewlines();
                const expr = try self.parseExpression();
                self.skipNewlines();
                _ = try self.expect(.interp_end);
                try parts.append(self.allocator, .{ .interpolation = expr });
            },
            else => break,
        }
    }
}

// ── Control flow ────────────────────────────────────────────

fn parseIfExpr(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.if_);
    self.skipNewlines();
    const cond = try self.parseExpression();
    self.skipNewlines();
    _ = try self.expect(.then);
    self.skipNewlines();
    const then_br = try self.parseExpression();
    self.skipNewlines();
    _ = try self.expect(.else_);
    self.skipNewlines();
    return self.node(.{ .if_expr = .{ .condition = cond, .then_branch = then_br, .else_branch = try self.parseExpression() } }, self.endSpan(.{ .line = tok.line, .col = tok.col }));
}

fn parseCaseExpr(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.case);
    const s = Ast.Span{ .line = tok.line, .col = tok.col };
    self.skipNewlines();

    const mode: Ast.CaseMode = if (self.eat(.type_)) blk: {
        self.skipNewlines();
        break :blk .type_;
    } else if (self.eat(.named)) blk: {
        self.skipNewlines();
        break :blk .named;
    } else .value;

    const scrutinee = try self.parseExpression();
    var when_clauses = std.ArrayListUnmanaged(Ast.WhenClause){};

    while (true) {
        self.skipNewlines();
        if (!self.at(.when)) break;
        const ws = self.span();
        _ = self.advance();
        self.skipNewlines();

        const value: *const Ast.Node = switch (mode) {
            .named => blk: {
                const vn = try self.parseVariantName();
                break :blk try self.node(.{ .identifier = .{ .name = vn } }, ws);
            },
            .type_ => blk: {
                // Support compound type expressions: [i32], (i32, string), etc.
                if (self.at(.l_bracket) or self.at(.l_paren)) {
                    const te = try self.parseTypeExpr();
                    break :blk try self.node(.{ .type_pattern = .{ .type_expr = te } }, ws);
                }
                const t = self.advance();
                break :blk try self.node(.{ .identifier = .{ .name = t.lexeme } }, .{ .line = t.line, .col = t.col });
            },
            .value => try self.parseExpression(),
        };

        self.skipNewlines();
        _ = try self.expect(.then);
        self.skipNewlines();
        try when_clauses.append(self.allocator, .{ .value = value, .result = try self.parseExpression(), .span = ws });
    }

    if (when_clauses.items.len == 0)
        return self.fail("case requires at least one when clause", s.line, s.col);

    self.skipNewlines();
    _ = try self.expect(.else_);
    self.skipNewlines();
    return self.node(.{ .case_expr = .{ .mode = mode, .scrutinee = scrutinee, .when_clauses = when_clauses.items, .else_branch = try self.parseExpression() } }, self.endSpan(s));
}

// ── Type system clauses ─────────────────────────────────────

fn parseFromClause(self: *Parser, value: *const Ast.Node) Error!*const Ast.Node {
    const s = self.span();
    _ = self.advance(); // from
    self.skipNewlines();

    if (self.eat(.union_)) {
        self.skipNewlines();
        var types = std.ArrayListUnmanaged(Ast.TypeExpr){};
        try types.append(self.allocator, try self.parseTypeExpr());
        while (self.commaAndNotBinding()) {
            try types.append(self.allocator, try self.parseTypeExpr());
        }
        return self.node(.{ .from_union = .{ .value = value, .types = types.items } }, s);
    }

    var variants = std.ArrayListUnmanaged([]const u8){};
    try variants.append(self.allocator, try self.parseVariantName());
    while (self.commaAndNotBinding()) {
        try variants.append(self.allocator, try self.parseVariantName());
    }
    return self.node(.{ .from_enum = .{ .value = value, .variants = variants.items } }, s);
}

fn parseNamedClause(self: *Parser, value: *const Ast.Node) Error!*const Ast.Node {
    const s = self.span();
    _ = self.advance(); // named
    self.skipNewlines();
    const tag = try self.parseVariantName();
    self.skipNewlines();

    if (self.at(.from)) {
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .named_variant = .{ .value = value, .tag = tag, .variants = try self.parseTaggedUnionVariants() } }, s);
    }

    if (self.at(.as)) {
        const as_tok = self.peek();
        return self.failSug("'as Type' must precede 'named variant'", "write 'value as Type named variant' instead", as_tok.line, as_tok.col);
    }

    return self.node(.{ .named_variant = .{ .value = value, .tag = tag, .variants = &.{} } }, s);
}

/// Consume comma and check next tokens aren't a new binding start.
fn commaAndNotBinding(self: *Parser) bool {
    self.skipNewlines();
    if (!self.at(.comma)) return false;
    var look = self.pos + 1;
    while (look < self.tokens.len and self.tokens[look].type == .newline) look += 1;
    if (self.isBindingStartAt(look)) return false;
    _ = self.advance(); // comma
    self.skipNewlines();
    if (self.at(.called) or self.at(.eof) or self.at(.r_brace) or self.at(.r_bracket) or self.at(.r_paren)) return false;
    return true;
}

fn parseTaggedUnionVariants(self: *Parser) Error![]const Ast.VariantDef {
    var variants = std.ArrayListUnmanaged(Ast.VariantDef){};
    const vn = try self.parseVariantName();
    self.skipNewlines();
    _ = try self.expect(.as);
    self.skipNewlines();
    try variants.append(self.allocator, .{ .name = vn, .type_expr = try self.parseTypeExpr() });

    while (self.commaAndNotBinding()) {
        const n = try self.parseVariantName();
        self.skipNewlines();
        _ = try self.expect(.as);
        self.skipNewlines();
        try variants.append(self.allocator, .{ .name = n, .type_expr = try self.parseTypeExpr() });
    }
    return variants.items;
}

fn parseVariantName(self: *Parser) Error![]const u8 {
    const tok = self.peek();
    if (tok.type == .identifier or tok.type == .quoted_identifier or tok.type.isKeyword()) {
        _ = self.advance();
        return tok.lexeme;
    }
    return self.fail("expected variant name", tok.line, tok.col);
}

// ── Standalone type declarations ────────────────────────────

fn parseStandaloneEnum(self: *Parser, s: Ast.Span) Error!*const Ast.Node {
    // `enum v1, v2, ...` — value is first variant (as an identifier)
    var variants = std.ArrayListUnmanaged([]const u8){};
    try variants.append(self.allocator, try self.parseVariantName());
    while (self.commaAndNotBinding()) {
        try variants.append(self.allocator, try self.parseVariantName());
    }
    if (variants.items.len == 0) return self.fail("enum must have at least one variant", s.line, s.col);
    const first = try self.node(.{ .identifier = .{ .name = variants.items[0] } }, s);
    return self.node(.{ .from_enum = .{ .value = first, .variants = variants.items } }, s);
}

fn parseStandaloneUnion(self: *Parser, s: Ast.Span) Error!*const Ast.Node {
    // `union T1, T2, ...` — value is default of first type
    var types = std.ArrayListUnmanaged(Ast.TypeExpr){};
    try types.append(self.allocator, try self.parseTypeExpr());
    while (self.commaAndNotBinding()) {
        try types.append(self.allocator, try self.parseTypeExpr());
    }
    if (types.items.len == 0) return self.fail("union must have at least one member type", s.line, s.col);
    const default_value = try self.defaultForTypeExpr(types.items[0], s);
    return self.node(.{ .from_union = .{ .value = default_value, .types = types.items } }, s);
}

fn parseStandaloneTaggedUnion(self: *Parser, s: Ast.Span) Error!*const Ast.Node {
    // `tagged union tag1 as T1, tag2 as T2, ...` — default of first variant's type tagged with first variant
    const variants = try self.parseTaggedUnionVariants();
    if (variants.len == 0) return self.fail("tagged union must have at least one variant", s.line, s.col);
    const default_value = try self.defaultForTypeExpr(variants[0].type_expr, s);
    return self.node(.{ .named_variant = .{ .value = default_value, .tag = variants[0].name, .variants = variants } }, s);
}

/// Produce an AST node representing the default value of the given type expression (§3.6 table).
fn defaultForTypeExpr(self: *Parser, te: Ast.TypeExpr, s: Ast.Span) Error!*const Ast.Node {
    switch (te.data) {
        .name => |n| {
            if (n.len >= 2 and (n[0] == 'i' or n[0] == 'u') and isAllDigits(n[1..])) {
                return self.node(.{ .integer_literal = .{ .value = "0" } }, s);
            }
            if (n.len >= 2 and n[0] == 'f' and isAllDigits(n[1..])) {
                return self.node(.{ .float_literal = .{ .value = "0.0" } }, s);
            }
            if (std.mem.eql(u8, n, "string")) {
                return self.node(.{ .string_literal = .{ .parts = &.{} } }, s);
            }
            if (std.mem.eql(u8, n, "bool")) {
                return self.node(.{ .bool_literal = .{ .value = false } }, s);
            }
            if (std.mem.eql(u8, n, "null")) {
                return self.node(.null_literal, s);
            }
            // Named type — defer to evaluator. The default of a user-named type
            // isn't knowable at parse time, so emit a `type_default` node that
            // the evaluator resolves via `computeNamedDefault`.
            return self.node(.{ .type_default = .{ .type_expr = te } }, s);
        },
        .null_type => return self.node(.null_literal, s),
        .list => return self.node(.{ .list_literal = .{ .elements = &.{} } }, s),
        .tuple => |elems| {
            // §3.6: default of a tuple type is a tuple of each element's default.
            const out = try self.allocator.alloc(*const Ast.Node, elems.len);
            for (elems, 0..) |et, i| out[i] = try self.defaultForTypeExpr(et, s);
            return self.node(.{ .tuple_literal = .{ .elements = out } }, s);
        },
        .path => return self.node(.{ .type_default = .{ .type_expr = te } }, s),
    }
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

// ── Functions ───────────────────────────────────────────────

fn parseFunctionExpr(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.function);
    const s = Ast.Span{ .line = tok.line, .col = tok.col };
    self.skipNewlines();

    var params = std.ArrayListUnmanaged(Ast.FunctionParam){};
    if (!self.at(.returns) and !self.at(.l_brace)) {
        try params.append(self.allocator, try self.parseFunctionParam());
        while (self.skipNewlinesEat(.comma)) {
            self.skipNewlines();
            try params.append(self.allocator, try self.parseFunctionParam());
        }
    }
    self.skipNewlines();

    // Validate duplicate parameter names
    for (params.items, 0..) |p, i| {
        for (params.items[0..i]) |prev| {
            if (std.mem.eql(u8, p.name, prev.name)) {
                return self.fail("duplicate parameter name", p.span.line, p.span.col);
            }
        }
    }

    // Validate default param ordering
    var seen_default = false;
    for (params.items) |p| {
        if (p.default != null) {
            seen_default = true;
        } else if (seen_default) {
            return self.fail("required parameter after defaulted parameter", p.span.line, p.span.col);
        }
    }

    _ = try self.expect(.returns);
    self.skipNewlines();
    const return_type = try self.parseTypeExpr();
    self.skipNewlines();
    _ = try self.expect(.l_brace);
    self.skipNewlines();

    var body_bindings = std.ArrayListUnmanaged(Ast.Binding){};
    const prev_suppress = self.suppress_multiline_string;
    self.suppress_multiline_string = true;

    while (!self.at(.r_brace) and !self.at(.eof)) {
        if (self.isFuncBindingStartAt(self.pos)) {
            const binding = try self.parseBinding();
            if (binding.called != null)
                return self.failSug("'called' not permitted in function bodies", "use 'as' for type annotations", binding.span.line, binding.span.col);
            try body_bindings.append(self.allocator, binding);
            _ = self.skipSeparator();
        } else {
            // §3.8: reject `are` in function bodies with a clear message.
            if (self.looksLikeBinding(self.pos, true) and !self.looksLikeBinding(self.pos, false)) {
                const btok = self.tokens[self.pos];
                return self.failSug("'are' not permitted in function bodies", "use 'is' with a list value", btok.line, btok.col);
            }
            break;
        }
    }

    const body_expr = try self.parseExpression();
    self.suppress_multiline_string = prev_suppress;
    self.skipNewlines();
    _ = try self.expect(.r_brace);

    return self.node(.{ .function_expr = .{ .params = params.items, .return_type = return_type, .body_bindings = body_bindings.items, .body_expr = body_expr } }, self.endSpan(s));
}

fn parseFunctionParam(self: *Parser) Error!Ast.FunctionParam {
    const nt = try self.expect(.identifier);
    self.skipNewlines();
    _ = try self.expect(.as);
    self.skipNewlines();
    const te = try self.parseTypeExpr();
    var default_val: ?*const Ast.Node = null;
    self.skipNewlines();
    if (self.eat(.default)) {
        self.skipNewlines();
        default_val = try self.parseExpression();
    }
    return .{ .name = nt.lexeme, .type_expr = te, .default = default_val, .span = .{ .line = nt.line, .col = nt.col } };
}

// ── Struct import ───────────────────────────────────────────

fn parseStructImport(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.struct_);
    self.skipNewlines();
    const path_tok = try self.expect(.string);
    return self.node(.{ .struct_import = .{ .path = path_tok.lexeme, .path_span = .{ .line = path_tok.line, .col = path_tok.col } } }, self.endSpan(.{ .line = tok.line, .col = tok.col }));
}

// ── Type expressions ────────────────────────────────────────

fn parseTypeExpr(self: *Parser) Error!Ast.TypeExpr {
    const s = self.span();
    if (self.at(.l_paren)) return self.parseTupleType(s);
    if (self.at(.l_bracket)) return self.parseListType(s);
    if (self.eat(.null_)) return .{ .data = .null_type, .span = s };

    const first = try self.expect(.identifier);
    var path = std.ArrayListUnmanaged([]const u8){};
    try path.append(self.allocator, first.lexeme);
    while (self.at(.dot)) {
        _ = self.advance();
        try path.append(self.allocator, (try self.expect(.identifier)).lexeme);
    }
    return if (path.items.len == 1)
        .{ .data = .{ .name = path.items[0] }, .span = s }
    else
        .{ .data = .{ .path = path.items }, .span = s };
}

fn parseTupleType(self: *Parser, s: Ast.Span) Error!Ast.TypeExpr {
    _ = self.advance(); // (
    self.skipNewlines();
    if (self.eat(.r_paren)) return .{ .data = .{ .tuple = &.{} }, .span = s };

    const first = try self.parseTypeExpr();
    self.skipNewlines();
    if (self.eat(.r_paren)) return first; // grouping

    _ = try self.expect(.comma);
    self.skipNewlines();
    var types = std.ArrayListUnmanaged(Ast.TypeExpr){};
    try types.append(self.allocator, first);
    if (self.eat(.r_paren)) return .{ .data = .{ .tuple = types.items }, .span = s }; // 1-tuple

    try types.append(self.allocator, try self.parseTypeExpr());
    while (self.skipNewlinesEat(.comma)) {
        self.skipNewlines();
        if (self.at(.r_paren)) break;
        try types.append(self.allocator, try self.parseTypeExpr());
    }
    self.skipNewlines();
    _ = try self.expect(.r_paren);
    return .{ .data = .{ .tuple = types.items }, .span = s };
}

fn parseListType(self: *Parser, s: Ast.Span) Error!Ast.TypeExpr {
    _ = self.advance(); // [
    self.skipNewlines();
    const inner = try self.parseTypeExpr();
    self.skipNewlines();
    _ = try self.expect(.r_bracket);
    const ptr = try self.allocator.create(Ast.TypeExpr);
    ptr.* = inner;
    return .{ .data = .{ .list = ptr }, .span = s };
}

// ── Tests ───────────────────────────────────────────────────

const Lexer = @import("Lexer.zig");

fn testParse(source: []const u8) !struct { doc: Ast.Document, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.tokenize();
    var parser = Parser.init(arena.allocator(), tokens, lexer.comment_lines.items);
    return .{ .doc = try parser.parse(), .arena = arena };
}

test "parse simple binding" {
    var tp = try testParse("x is 42");
    defer tp.arena.deinit();
    try std.testing.expectEqual(1, tp.doc.bindings.len);
    try std.testing.expectEqualStrings("x", tp.doc.bindings[0].name);
    try std.testing.expectEqual(.integer_literal, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse struct literal" {
    var tp = try testParse("s is { a is 1, b is 2 }");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.struct_literal, std.meta.activeTag(tp.doc.bindings[0].value.kind));
    try std.testing.expectEqual(2, tp.doc.bindings[0].value.kind.struct_literal.fields.len);
}

test "parse list literal" {
    var tp = try testParse("xs is [1, 2, 3]");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.list_literal, std.meta.activeTag(tp.doc.bindings[0].value.kind));
    try std.testing.expectEqual(3, tp.doc.bindings[0].value.kind.list_literal.elements.len);
}

test "parse are binding" {
    var tp = try testParse("xs are 1, 2, 3");
    defer tp.arena.deinit();
    try std.testing.expect(tp.doc.bindings[0].is_are);
    try std.testing.expectEqual(.list_literal, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse if expression" {
    var tp = try testParse("x is if true then 1 else 2");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.if_expr, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse binary operators precedence" {
    var tp = try testParse("x is 1 + 2 * 3");
    defer tp.arena.deinit();
    const val = tp.doc.bindings[0].value;
    try std.testing.expectEqual(.binary_op, std.meta.activeTag(val.kind));
    try std.testing.expectEqual(Ast.BinaryOp.add, val.kind.binary_op.op);
}

test "parse called" {
    var tp = try testParse("x is 42 called Answer");
    defer tp.arena.deinit();
    try std.testing.expectEqualStrings("Answer", tp.doc.bindings[0].called.?);
}

test "parse enum" {
    var tp = try testParse("c is red from red, green, blue");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.from_enum, std.meta.activeTag(tp.doc.bindings[0].value.kind));
    try std.testing.expectEqual(3, tp.doc.bindings[0].value.kind.from_enum.variants.len);
}

test "parse function" {
    var tp = try testParse("add is function a as i64, b as i64 returns i64 { a + b }");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.function_expr, std.meta.activeTag(tp.doc.bindings[0].value.kind));
    try std.testing.expectEqual(2, tp.doc.bindings[0].value.kind.function_expr.params.len);
}

test "parse multiline" {
    var tp = try testParse("x is 1\ny is 2\nz is 3");
    defer tp.arena.deinit();
    try std.testing.expectEqual(3, tp.doc.bindings.len);
}

test "parse member access" {
    var tp = try testParse("x is obj.field.sub");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.member_access, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse type annotation" {
    var tp = try testParse("x is 42 as i32");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.type_annotation, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse conversion" {
    var tp = try testParse("x is 42 to f64");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.conversion, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse or else" {
    var tp = try testParse("x is y or else 0");
    defer tp.arena.deinit();
    try std.testing.expectEqual(.or_else, std.meta.activeTag(tp.doc.bindings[0].value.kind));
}

test "parse case" {
    var tp = try testParse("x is case v when 1 then \"one\" when 2 then \"two\" else \"other\"");
    defer tp.arena.deinit();
    const val = tp.doc.bindings[0].value;
    try std.testing.expectEqual(.case_expr, std.meta.activeTag(val.kind));
    try std.testing.expectEqual(2, val.kind.case_expr.when_clauses.len);
}
