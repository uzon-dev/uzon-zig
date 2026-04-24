const std = @import("std");
const Ast = @import("Ast.zig");

/// Integer type annotation (§4.1).
pub const IntegerType = union(enum) {
    /// Untyped (adopts type from context).
    arbitrary,
    /// Signed: i8, i16, i32, i64, i128, etc.
    signed: u16,
    /// Unsigned: u8, u16, u32, u64, u128, etc.
    unsigned: u16,
};

/// Float type annotation (§4.2).
pub const FloatType = enum {
    f16,
    f32,
    f64,
    f80,
    f128,
};

/// Typed integer value with adoption tracking (§4.1).
pub const Integer = struct {
    value: i128,
    type_ann: IntegerType = .{ .signed = 64 },
    explicit: bool = false,
};

/// Typed float value with adoption tracking (§4.2).
pub const Float = struct {
    value: f64,
    type_ann: FloatType = .f64,
    explicit: bool = false,
};

/// List value with optional element type (§3.4).
pub const List = struct {
    elements: []const Value,
    element_type: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
};

/// Tuple value — fixed-length heterogeneous sequence (§3.3).
pub const Tuple = struct {
    elements: []const Value,
};

/// Struct value — ordered map of field name → value (§3.2).
pub const Struct = struct {
    keys: []const []const u8,
    values: []const Value,
    type_name: ?[]const u8 = null,

    pub fn get(self: Struct, key: []const u8) ?Value {
        for (self.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return self.values[i];
        }
        return null;
    }
};

/// Enum value — selected variant from a set (§3.5).
pub const Enum = struct {
    value: []const u8,
    variants: []const []const u8,
    type_name: ?[]const u8 = null,
};

/// Untagged union value (§3.6).
pub const Union = struct {
    value: *const Value,
    types: []const []const u8,
    type_name: ?[]const u8 = null,
};

/// Tagged union value (§3.7).
pub const TaggedUnion = struct {
    value: *const Value,
    tag: []const u8,
    variants: []const VariantInfo,
    type_name: ?[]const u8 = null,

    pub const VariantInfo = struct {
        name: []const u8,
        type_name: ?[]const u8 = null,
    };
};

/// Function value (§3.8).
pub const Function = struct {
    params: []const Ast.FunctionParam,
    return_type: Ast.TypeExpr,
    body_bindings: []const Ast.Binding,
    body_expr: *const Ast.Node,
    captured_keys: []const []const u8,
    captured_values: []const Value,
    captured_types: []const TypeDef,
    type_name: ?[]const u8 = null,
};

/// Type definition registered via `called` (§6).
pub const TypeDef = struct {
    name: []const u8,
    kind: Kind,
    /// §3.9 optional refinement predicate — if set, `as T` / `is type T` /
    /// `to T` evaluates the predicate with `self` bound to the candidate.
    refinement: ?Refinement = null,

    pub const Refinement = struct {
        base_type_name: []const u8,
        /// Predicate AST node, evaluated with `self` in scope.
        predicate: *const Ast.Node,
    };

    pub const Kind = union(enum) {
        enum_type: struct { variants: []const []const u8 },
        union_type: struct { types: []const []const u8 },
        tagged_union_type: struct { variants: []const TaggedUnion.VariantInfo },
        struct_type: struct { fields: []const FieldInfo },
        function_type: struct { param_types: []const []const u8, return_type: []const u8 },
        list_type: struct { element_type: ?[]const u8 },
        /// §3.9 refinement on a primitive base (u16, string, etc.).
        refinement_primitive: struct { base: []const u8 },
        /// §6.2 nominal identity wrapper over a primitive scalar (e.g.
        /// `small_int is 42 called SmallInt` → i64-backed SmallInt).
        scalar_type: struct { base: []const u8 },
    };

    pub const FieldInfo = struct {
        name: []const u8,
        type_category: []const u8,
        type_annotation: ?[]const u8 = null,
        default: Value = .undefined,
    };
};

/// The UZON runtime value.
pub const Value = union(enum) {
    null_val,
    undefined,
    bool_val: bool,
    integer: Integer,
    float_val: Float,
    string: []const u8,
    list: List,
    tuple: Tuple,
    struct_val: Struct,
    enum_val: Enum,
    union_val: Union,
    tagged_union: TaggedUnion,
    function: Function,

    // ── Convenience constructors ────────────────────────────

    pub fn int(v: i128) Value {
        return .{ .integer = .{ .value = v } };
    }

    pub fn float(v: f64) Value {
        return .{ .float_val = .{ .value = v } };
    }

    pub fn boolean(v: bool) Value {
        return .{ .bool_val = v };
    }

    pub fn str(v: []const u8) Value {
        return .{ .string = v };
    }

    // ── Predicates ──────────────────────────────────────────

    pub fn isUndefined(self: Value) bool {
        return self == .undefined;
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    /// Returns the type category name for error messages (§11.2).
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null_val => "null",
            .undefined => "undefined",
            .bool_val => "bool",
            .integer => "integer",
            .float_val => "float",
            .string => "string",
            .list => "list",
            .tuple => "tuple",
            .struct_val => "struct",
            .enum_val => "enum",
            .union_val => "union",
            .tagged_union => "tagged_union",
            .function => "function",
        };
    }

    /// Unwrap union/tagged union to inner value (transparency rule §3.6/§3.7.1).
    pub fn unwrapTransparent(self: Value) Value {
        return switch (self) {
            .union_val => |u| u.value.*,
            .tagged_union => |tu| tu.value.*,
            else => self,
        };
    }

    /// Unwrap untagged union only. Tagged unions pass through.
    pub fn unwrapUntagged(self: Value) Value {
        return switch (self) {
            .union_val => |u| u.value.*,
            else => self,
        };
    }
};
