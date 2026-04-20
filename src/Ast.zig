const std = @import("std");

/// Source location for AST nodes.
pub const Span = struct {
    line: u32,
    col: u32,
    end_line: u32 = 0,
    end_col: u32 = 0,
};

/// Binary operators (§5.2–5.8).
pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod_,
    pow,
    concat,
    repeat,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    eq,
    neq,
    is_named,
    is_not_named,
    is_type,
    is_not_type,
    in_,
};

/// Unary operators.
pub const UnaryOp = enum {
    negate,
    not,
};

/// Mode of a `case` expression (§5.10).
pub const CaseMode = enum {
    value,
    type_,
    named,
};

/// A type expression (§6).
pub const TypeExpr = struct {
    data: Data,
    span: Span,

    pub const Data = union(enum) {
        /// Single type name: `i32`, `string`, `bool`, `MyType`
        name: []const u8,
        /// Qualified path: `Config.Port`, `outer.inner.Type`
        path: []const []const u8,
        /// List type: `[Type]`
        list: *const TypeExpr,
        /// Tuple type: `()`, `(Type,)`, `(Type, Type, ...)`
        tuple: []const TypeExpr,
        /// The `null` type
        null_type: void,
    };
};

/// Part of a string literal — plain text or interpolation (§4.4.1).
pub const StringPart = union(enum) {
    literal: []const u8,
    interpolation: *const Node,
};

/// A function parameter: `name as Type [default expr]` (§3.8).
pub const FunctionParam = struct {
    name: []const u8,
    type_expr: TypeExpr,
    default: ?*const Node,
    span: Span,
};

/// A `when` clause in a `case` expression (§5.10).
pub const WhenClause = struct {
    value: *const Node,
    result: *const Node,
    span: Span,
};

/// A tagged union variant definition: `tag as Type`.
pub const VariantDef = struct {
    name: []const u8,
    type_expr: TypeExpr,
};

/// A binding: `name is expr [called TypeName]` (§5.1).
pub const Binding = struct {
    name: []const u8,
    value: *const Node,
    called: ?[]const u8,
    is_are: bool,
    list_type_annotation: ?TypeExpr,
    span: Span,
};

/// An AST node.
pub const Node = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        // Literals (§4)
        integer_literal: struct { value: []const u8 },
        float_literal: struct { value: []const u8 },
        string_literal: struct { parts: []const StringPart },
        bool_literal: struct { value: bool },
        null_literal: void,
        undefined_literal: void,
        inf_literal: struct { negative: bool },
        nan_literal: void,

        // References
        identifier: struct { name: []const u8 },
        env_ref: void,

        // Expressions (§5)
        member_access: struct { object: *const Node, member: []const u8 },
        binary_op: struct { op: BinaryOp, left: *const Node, right: *const Node },
        unary_op: struct { op: UnaryOp, operand: *const Node },
        or_else: struct { left: *const Node, right: *const Node },
        if_expr: struct { condition: *const Node, then_branch: *const Node, else_branch: *const Node },
        case_expr: struct { mode: CaseMode, scrutinee: *const Node, when_clauses: []const WhenClause, else_branch: *const Node },

        // Type system (§6)
        type_annotation: struct { expr: *const Node, type_expr: TypeExpr },
        conversion: struct { expr: *const Node, type_expr: TypeExpr },
        from_enum: struct { value: *const Node, variants: []const []const u8 },
        from_union: struct { value: *const Node, types: []const TypeExpr },
        named_variant: struct { value: *const Node, tag: []const u8, variants: []const VariantDef },
        /// Parser-synthesized placeholder that resolves to the default value of a named
        /// type (§3.6). Used where a default must be emitted but the default of a
        /// user-named type isn't knowable at parse time — e.g. the first variant's
        /// inner default in `parseStandaloneTaggedUnion`.
        type_default: struct { type_expr: TypeExpr },

        // Compounds (§3)
        struct_literal: struct { fields: []const Binding },
        list_literal: struct { elements: []const *const Node },
        tuple_literal: struct { elements: []const *const Node },
        grouping: struct { expr: *const Node },
        struct_override: struct { base: *const Node, overrides: *const Node },
        struct_extension: struct { base: *const Node, extension: *const Node },

        // Functions (§3.8)
        function_expr: struct {
            params: []const FunctionParam,
            return_type: TypeExpr,
            body_bindings: []const Binding,
            body_expr: *const Node,
        },
        function_call: struct { callee: *const Node, args: []const *const Node },

        // Import & special
        struct_import: struct { path: []const u8, path_span: Span },
        field_extraction: struct { source: *const Node },

        // Type pattern (for case type when clauses with compound types)
        type_pattern: struct { type_expr: TypeExpr },

        // Variant shorthand: `variant_name inner_primary` (§3.7 v0.10)
        variant_shorthand: struct { variant: []const u8, inner: *const Node },
    };
};

/// The root of a parsed UZON document (§1).
pub const Document = struct {
    bindings: []const Binding,
    span: Span,
};
