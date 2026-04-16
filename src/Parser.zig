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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        left = try self.node(.{ .or_else = .{ .left = left, .right = try self.parseOr() } }, s);
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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        left = try self.node(.{ .binary_op = .{ .op = .@"or", .left = left, .right = try self.parseAnd() } }, s);
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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        left = try self.node(.{ .binary_op = .{ .op = .@"and", .left = left, .right = try self.parseNot() } }, s);
    }
    return left;
}

// Level 15: not
fn parseNot(self: *Parser) Error!*const Ast.Node {
    if (self.at(.not)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .unary_op = .{ .op = .not, .operand = try self.parseNot() } }, s);
    }
    return self.parseEquality();
}

// Level 14: is, is not, is named, is not named, is type, is not type
fn parseEquality(self: *Parser) Error!*const Ast.Node {
    const left = try self.parseMembership();
    self.skipNewlines();
    const s = self.span();
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
            const t = self.advance();
            break :blk try self.node(.{ .identifier = .{ .name = t.lexeme } }, .{ .line = t.line, .col = t.col });
        } else try self.parseMembership();
        return self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = right } }, s);
    }
    return left;
}

// Level 13: in
fn parseMembership(self: *Parser) Error!*const Ast.Node {
    const left = try self.parseRelational();
    self.skipNewlines();
    if (self.at(.in_)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .binary_op = .{ .op = .in_, .left = left, .right = try self.parseRelational() } }, s);
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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = try self.parseConcat() } }, s);
    }
    return left;
}

// Level 11: ++
fn parseConcat(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseAddition();
    while (blk: {
        self.skipNewlines();
        break :blk self.at(.plus_plus);
    }) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        left = try self.node(.{ .binary_op = .{ .op = .concat, .left = left, .right = try self.parseAddition() } }, s);
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
            const s = self.span();
            _ = self.advance();
            self.skipNewlines();
            left = try self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = try self.parseMultiplication() } }, s);
        } else break;
    }
    return left;
}

// Level 9: *, /, %, **
fn parseMultiplication(self: *Parser) Error!*const Ast.Node {
    var left = try self.parseUnary();
    while (true) {
        self.skipNewlines();
        const op: ?Ast.BinaryOp = switch (self.peek().type) {
            .star => .mul, .slash => .div, .percent => .mod_, .star_star => .repeat, else => null,
        };
        if (op) |binary_op| {
            const s = self.span();
            _ = self.advance();
            self.skipNewlines();
            left = try self.node(.{ .binary_op = .{ .op = binary_op, .left = left, .right = try self.parseUnary() } }, s);
        } else break;
    }
    return left;
}

// Level 8: unary -
fn parseUnary(self: *Parser) Error!*const Ast.Node {
    if (self.at(.minus)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .unary_op = .{ .op = .negate, .operand = try self.parsePower() } }, s);
    }
    return self.parsePower();
}

// Level 7: ^ (right-associative)
fn parsePower(self: *Parser) Error!*const Ast.Node {
    const base = try self.parseTypeDecl();
    self.skipNewlines();
    if (self.at(.caret)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .binary_op = .{ .op = .pow, .left = base, .right = try self.parseUnary() } }, s);
    }
    return base;
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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        var result = try self.node(.{ .type_annotation = .{ .expr = expr, .type_expr = try self.parseTypeExpr() } }, s);
        // Allow chained `to` after `as`
        self.skipNewlines();
        if (self.at(.to)) {
            const to_s = self.span();
            _ = self.advance();
            self.skipNewlines();
            result = try self.node(.{ .conversion = .{ .expr = result, .type_expr = try self.parseTypeExpr() } }, to_s);
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
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        const rhs = try self.parseStructLiteral();
        self.skipNewlines();
        if (self.at(.with) or self.at(.plus)) {
            const t = self.peek();
            return self.failSug("cannot chain 'with'/'plus'", "use an intermediate binding", t.line, t.col);
        }
        return if (is_ext)
            self.node(.{ .struct_extension = .{ .base = expr, .extension = rhs } }, s)
        else
            self.node(.{ .struct_override = .{ .base = expr, .overrides = rhs } }, s);
    }
    return expr;
}

// Level 2: to
fn parseConversion(self: *Parser) Error!*const Ast.Node {
    const expr = try self.parseCallOrAccess();
    self.skipNewlines();
    if (self.at(.to)) {
        const s = self.span();
        _ = self.advance();
        self.skipNewlines();
        return self.node(.{ .conversion = .{ .expr = expr, .type_expr = try self.parseTypeExpr() } }, s);
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
            expr = try self.node(.{ .member_access = .{ .object = expr, .member = m.lexeme } }, .{ .line = m.line, .col = m.col });
        } else if (self.at(.l_paren) and self.peek().line == callee_line) {
            // §5.15: ( on same line → function call
            const s = self.span();
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
            expr = try self.node(.{ .function_call = .{ .callee = expr, .args = args.items } }, s);
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
        expr = try self.node(.{ .member_access = .{ .object = expr, .member = m.lexeme } }, .{ .line = m.line, .col = m.col });
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

fn parseStructLiteral(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.l_brace);
    const saved = self.suppress_as;
    self.suppress_as = false;
    const fields = try self.parseBindings(.r_brace);
    _ = try self.expect(.r_brace);
    self.suppress_as = saved;
    return self.node(.{ .struct_literal = .{ .fields = fields } }, .{ .line = tok.line, .col = tok.col });
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
    return self.node(.{ .list_literal = .{ .elements = elements.items } }, .{ .line = tok.line, .col = tok.col });
}

fn parseTupleOrGroup(self: *Parser) Error!*const Ast.Node {
    const tok = try self.expect(.l_paren);
    const s = Ast.Span{ .line = tok.line, .col = tok.col };
    self.skipNewlines();

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .tuple_literal = .{ .elements = &.{} } }, s);
    }

    const first = try self.parseExpression();
    self.skipNewlines();

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .grouping = .{ .expr = first } }, s);
    }

    _ = try self.expect(.comma);
    self.skipNewlines();
    var elements = std.ArrayListUnmanaged(*const Ast.Node){};
    try elements.append(self.allocator, first);

    if (self.at(.r_paren)) {
        _ = self.advance();
        return self.node(.{ .tuple_literal = .{ .elements = elements.items } }, s);
    }

    try elements.append(self.allocator, try self.parseExpression());
    while (self.skipNewlinesEat(.comma)) {
        self.skipNewlines();
        if (self.at(.r_paren)) break;
        try elements.append(self.allocator, try self.parseExpression());
    }
    self.skipNewlines();
    _ = try self.expect(.r_paren);
    return self.node(.{ .tuple_literal = .{ .elements = elements.items } }, s);
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

    return self.node(.{ .string_literal = .{ .parts = parts.items } }, s);
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
    return self.node(.{ .if_expr = .{ .condition = cond, .then_branch = then_br, .else_branch = try self.parseExpression() } }, .{ .line = tok.line, .col = tok.col });
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
    return self.node(.{ .case_expr = .{ .mode = mode, .scrutinee = scrutinee, .when_clauses = when_clauses.items, .else_branch = try self.parseExpression() } }, s);
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
        } else break;
    }

    const body_expr = try self.parseExpression();
    self.suppress_multiline_string = prev_suppress;
    self.skipNewlines();
    _ = try self.expect(.r_brace);

    return self.node(.{ .function_expr = .{ .params = params.items, .return_type = return_type, .body_bindings = body_bindings.items, .body_expr = body_expr } }, s);
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
    return self.node(.{ .struct_import = .{ .path = (try self.expect(.string)).lexeme } }, .{ .line = tok.line, .col = tok.col });
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
