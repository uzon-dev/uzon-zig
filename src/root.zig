// UZON - A typed, human-readable data expression format
// Zig library implementation (spec v0.7)

const std = @import("std");

pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Ast = @import("Ast.zig");
pub const Value = @import("Value.zig");
pub const Evaluator = @import("Evaluator.zig");
pub const Scope = @import("Scope.zig");
pub const err = @import("error.zig");

// Internal modules (referenced by evaluator)
comptime {
    _ = @import("deps.zig");
    _ = @import("eval_helpers.zig");
    _ = @import("eval_ops.zig");
    _ = @import("eval_types.zig");
    _ = @import("eval_exprs.zig");
    _ = @import("stdlib.zig");
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
