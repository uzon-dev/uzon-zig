const std = @import("std");

pub const Type = enum {
    // Literals
    integer,
    float,
    string,
    true_,
    false_,
    null_,
    undefined,
    inf,
    nan,

    // Keywords — binding
    is,
    are,

    // Keywords — type system
    from,
    called,
    as,
    named,
    with,
    union_,
    plus,
    type_,

    // Keywords — conversion/extraction
    to,
    of,

    // Keywords — logic
    @"and",
    @"or",
    not,

    // Keywords — control
    if_,
    then,
    else_,
    case,
    when,

    // Keywords — environment
    env,

    // Keywords — import
    struct_,

    // Keywords — membership
    in_,

    // Keywords — function
    function,
    returns,
    default,

    // Keywords — reserved
    lazy,

    // Composite operators (emitted as single tokens by lexer)
    or_else,
    is_not,
    is_named,
    is_not_named,
    is_type,
    is_not_type,

    // Operators
    plus_op,
    minus,
    star,
    slash,
    percent,
    caret,
    plus_plus,
    star_star,
    lt,
    le,
    gt,
    ge,

    // Delimiters
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    l_paren,
    r_paren,
    comma,
    dot,
    at,

    // String interpolation
    interp_start,
    interp_end,

    // Structural
    identifier,
    quoted_identifier,
    newline,
    eof,

    pub fn isKeyword(self: Type) bool {
        return switch (self) {
            .is, .are, .from, .called, .as, .named, .with, .union_, .plus, .type_,
            .to, .of, .@"and", .@"or", .not, .if_, .then, .else_, .case, .when,
            .env, .struct_, .in_, .function, .returns, .default, .lazy,
            .true_, .false_, .null_, .undefined, .inf, .nan,
            => true,
            else => false,
        };
    }

    /// Returns true if this token type represents a value that can precede
    /// a binary minus (context-sensitive minus disambiguation per §9).
    pub fn isValueToken(self: Type) bool {
        return switch (self) {
            .integer, .float, .string, .true_, .false_, .null_, .inf, .nan,
            .undefined, .env, .identifier, .quoted_identifier,
            .r_paren, .r_bracket, .r_brace, .interp_end,
            => true,
            else => false,
        };
    }
};

pub const Token = struct {
    type: Type,
    lexeme: []const u8,
    line: u32,
    col: u32,
};

/// Map from keyword string to token type.
pub const keywords = std.StaticStringMap(Type).initComptime(.{
    .{ "is", .is },
    .{ "are", .are },
    .{ "from", .from },
    .{ "called", .called },
    .{ "as", .as },
    .{ "named", .named },
    .{ "with", .with },
    .{ "union", .union_ },
    .{ "plus", .plus },
    .{ "type", .type_ },
    .{ "to", .to },
    .{ "of", .of },
    .{ "and", .@"and" },
    .{ "or", .@"or" },
    .{ "not", .not },
    .{ "if", .if_ },
    .{ "then", .then },
    .{ "else", .else_ },
    .{ "case", .case },
    .{ "when", .when },
    .{ "env", .env },
    .{ "struct", .struct_ },
    .{ "in", .in_ },
    .{ "function", .function },
    .{ "returns", .returns },
    .{ "default", .default },
    .{ "lazy", .lazy },
    .{ "true", .true_ },
    .{ "false", .false_ },
    .{ "null", .null_ },
    .{ "undefined", .undefined },
    .{ "inf", .inf },
    .{ "nan", .nan },
});

/// All keyword strings for case-insensitive matching.
const keyword_strings = [_][]const u8{
    "is",        "are",       "from",     "called",  "as",       "named",
    "with",      "union",     "plus",     "type",    "to",       "of",
    "and",       "or",        "not",      "if",      "then",     "else",
    "case",      "when",      "env",      "struct",  "in",       "function",
    "returns",   "default",   "lazy",     "true",    "false",    "null",
    "undefined", "inf",       "nan",
};

/// Check if an identifier is a keyword with wrong casing.
/// Returns the correct keyword if found, null otherwise.
pub fn findCaseInsensitiveKeyword(lexeme: []const u8) ?[]const u8 {
    for (keyword_strings) |kw| {
        if (kw.len != lexeme.len) continue;
        if (std.mem.eql(u8, kw, lexeme)) return null;
        if (std.ascii.eqlIgnoreCase(kw, lexeme)) return kw;
    }
    return null;
}
