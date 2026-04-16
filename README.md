# uzon

A Zig library for parsing, evaluating, and serializing [UZON](https://uzon.dev) — a typed, human-readable data expression format.

```zig
const uzon = @import("uzon");

const result = uzon.parse(allocator,
    \\name is "Alice"
    \\age is 30
    \\server is { host is "localhost", port is 8080 }
);
const doc = result.value;

doc.struct_val.get("name").?.string;     // "Alice"
doc.struct_val.get("age").?.integer.value; // 30
```

## Installation

Add `uzon` as a dependency in your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/uzon-dev/uzon-zig
```

Then in your `build.zig`:

```zig
const uzon_dep = b.dependency("uzon", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("uzon", uzon_dep.module("uzon"));
```

Requires Zig 0.14.0 or later.

## Table of Contents

- [What is UZON?](#what-is-uzon)
- [UZON Syntax Overview](#uzon-syntax-overview)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
  - [Parsing](#parsing)
  - [Serialization](#serialization)
  - [Comptime Deserialization](#comptime-deserialization)
  - [Value](#value)
  - [Value Subtypes](#value-subtypes)
  - [Error Handling](#error-handling)
- [Build & Test](#build--test)
- [License](#license)

## What is UZON?

UZON (Universal Zone Object Notation) is a typed, human-readable data expression format designed for configuration files, data interchange, and anywhere you need structured data with more expressiveness than JSON or TOML. Key features:

- **Bindings, not assignments.** `name is "Alice"` declares an immutable binding. There is no mutation.
- **Expressions, not just values.** Bindings can reference other bindings, perform arithmetic, concatenate strings, branch with `if`/`case`, and call functions — all evaluated deterministically by dependency order.
- **Forward references.** Bindings are resolved by their dependency graph, not by source order. `a is b + 1` followed by `b is 10` works — `a` evaluates to `11`.
- **Rich type system.** Integers and floats carry explicit bit-width annotations (`42 as u8`, `3.14 as f32`). Collections include lists, tuples, structs, enums, untagged unions, and tagged unions — each with optional named types via `called`.
- **Type conversions.** The `to` operator converts between compatible types (`"8080" to u16`). `or else` provides a fallback when a value is undefined.
- **Environment variables.** `env.PORT to u16 or else 8080` reads from the environment with type conversion and a default.
- **File imports.** `struct "database"` imports another UZON file, enabling modular configuration.
- **Functions and standard library.** First-class functions with typed parameters, closures, and a built-in `std` module with `map`, `filter`, `fold`, `len`, `keys`, `upper`, `lower`, and more.
- **Four error categories.** Syntax, circular, type, and runtime errors — each with precise source locations and optional import traces.
- **Roundtrip fidelity.** Parse UZON text to values, serialize back to text, re-parse — the result is identical.

UZON is specified in a [formal specification](https://uzon.dev) and has conformance test suites that all implementations must pass.

## UZON Syntax Overview

```
// Scalars
name is "hello"
count is 42
ratio is 3.14
active is true
nothing is null

// Typed numbers
port is 8080 as u16
temperature is -40 as i8
weight is 72.5 as f32

// String interpolation
greeting is "Hello, {name}!"

// Multiline strings (leading whitespace stripped)
description is
    """
    This is a
    multiline string.
    """

// Lists
tags are "web", "api", "v2"
matrix is [[1, 2], [3, 4]]
typed_ids is [1, 2, 3] as [i32]

// Tuples — fixed-length heterogeneous sequences
point is (10, 20)
single is (42,)

// Structs — ordered maps
server is {
    host is "0.0.0.0"
    port is 443 as u16
}

// Enums — one variant from a defined set
color is red from red, green, blue called Color
selected is green as Color

// Untagged unions — a value with one of several possible types
flexible is 42 as i32 from union i32, f64, string

// Tagged unions — variant dispatch
result is "ok" named success from success as string, error as string called Result

// Expressions
total is count + 1
double is count * 2
greeting2 is "Hello, " ++ name

// Conditionals
mode is if active then "verbose" else "quiet"
label is case color
    when red then "Red"
    when green then "Green"
    else "Blue"

// Type dispatch
type_label is case type flexible
    when i32 then "integer"
    when f64 then "float"
    else "other"

// Variant dispatch
status_label is case named result
    when success then "good"
    when error then "bad"
    else "unknown"

// Type checking
is_int is flexible is type i32
is_not_str is flexible is not type string

// Functions
add is function a as i32, b as i32 returns i32 { a + b }
sum is add(3, 4)

// Standard library
doubled is std.map([1, 2, 3], function n as i64 returns i64 { n * 2 })
count2 is std.len(tags)
upper_name is std.upper(name)

// Copy-and-update / extension
dev_server is server with { port is 3000 as u16 }
extended is server plus { tls is true, cert is "/path" }

// Field extraction
host is of server

// Environment variables with type conversion and fallback
bind_port is env.PORT to u16 or else 8080
debug is env.DEBUG to bool or else false

// Undefined coalescing
fallback is server.missing or else "default"

// File imports
db is struct "database"
```

See the full [UZON specification](https://uzon.dev) for details.

---

## Quick Start

### Parse and access values

```zig
const std = @import("std");
const uzon = @import("uzon");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = uzon.parse(allocator,
        \\name is "Alice"
        \\age is 30
        \\scores is [95, 88, 92]
        \\server is { host is "localhost", port is 8080 }
    );

    switch (result) {
        .value => |doc| {
            const name = doc.struct_val.get("name").?.string;       // "Alice"
            const age = doc.struct_val.get("age").?.integer.value;   // 30

            const scores = doc.struct_val.get("scores").?.list.elements;
            _ = scores[0].integer.value; // 95

            const server = doc.struct_val.get("server").?.struct_val;
            _ = server.get("host").?.string;       // "localhost"
            _ = server.get("port").?.integer.value; // 8080

            _ = name;
            _ = age;
        },
        .err => |e| {
            e.dump(); // prints error with location
        },
    }
}
```

### Deserialize into Zig types

```zig
const uzon = @import("uzon");

const Address = struct { host: []const u8, port: u16 };
const Config = struct {
    name: []const u8,
    debug: bool,
    bind: Address,
    tags: []const []const u8,
};

const config = try uzon.parseInto(Config, allocator,
    \\name is "my-app"
    \\debug is true
    \\bind is { host is "0.0.0.0", port is 443 }
    \\tags is ["web", "prod"]
);

config.name;           // "my-app"
config.debug;          // true
config.bind.host;      // "0.0.0.0"
config.bind.port;      // 443
config.tags[0];        // "web"
```

### Serialize values

```zig
const uzon = @import("uzon");

const doc = uzon.Value{ .struct_val = .{
    .keys = &.{ "host", "port" },
    .values = &.{ uzon.Value.str("localhost"), uzon.Value.int(8080) },
} };

const text = try uzon.stringify(allocator, doc);
// host is "localhost"
// port is 8080
```

---

## API Reference

### Parsing

#### `parse`

```zig
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseResult
```

Parse and evaluate a UZON source string. Returns a `ParseResult` — either a fully evaluated `Value` or a detailed `UzonError`.

All memory is allocated via the provided allocator. Using an `ArenaAllocator` is recommended for typical use.

**Parameters:**

| Name        | Type                  | Description         |
|-------------|-----------------------|---------------------|
| `allocator` | `std.mem.Allocator`   | Memory allocator.   |
| `source`    | `[]const u8`          | UZON source text.   |

**Returns:** `ParseResult`

```zig
const result = uzon.parse(allocator, source);
switch (result) {
    .value => |v| { /* use v */ },
    .err => |e| { e.dump(); },
}
```

---

#### `parseWithBaseDir`

```zig
pub fn parseWithBaseDir(
    allocator: std.mem.Allocator,
    source: []const u8,
    base_dir: ?[]const u8,
) ParseResult
```

Parse and evaluate a UZON source string with a base directory for resolving file imports (`struct "filename"`). When `base_dir` is `null`, file imports are not resolved.

**Parameters:**

| Name        | Type                  | Description                                     |
|-------------|-----------------------|-------------------------------------------------|
| `allocator` | `std.mem.Allocator`   | Memory allocator.                                |
| `source`    | `[]const u8`          | UZON source text.                                |
| `base_dir`  | `?[]const u8`         | Base directory for resolving file imports.        |

**Returns:** `ParseResult`

```zig
const result = uzon.parseWithBaseDir(allocator, source, "/etc/myapp");
```

---

#### `parseFile`

```zig
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) ParseResult
```

Parse and evaluate a UZON file. The file's directory is automatically used as the base directory for resolving file imports. The filename is attached to any error for diagnostics.

Reads up to 16 MiB.

**Parameters:**

| Name        | Type                  | Description                  |
|-------------|-----------------------|------------------------------|
| `allocator` | `std.mem.Allocator`   | Memory allocator.             |
| `path`      | `[]const u8`          | Filesystem path to the file.  |

**Returns:** `ParseResult`

```zig
const result = uzon.parseFile(allocator, "config.uzon");
switch (result) {
    .value => |config| { /* use config */ },
    .err => |e| {
        // e.location.filename == "config.uzon"
        e.dump();
    },
}
```

---

#### `ParseResult`

```zig
pub const ParseResult = union(enum) {
    value: Value,
    err: UzonError,
};
```

The return type of all parsing functions. Either holds the successfully evaluated `Value` (typically a top-level struct representing all document bindings) or a `UzonError` with precise diagnostics.

---

### Serialization

#### `stringify`

```zig
pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]const u8
```

Serialize a `Value` to UZON text. If the value is a struct, it is emitted as a top-level document (bare bindings without braces). All other values are emitted in value syntax.

Type annotations, enum variant sets, union type lists, and tagged union variants are preserved for roundtrip fidelity. Keywords used as field names are escaped with `@` (e.g., `@is`). Field names requiring quoting use single quotes (e.g., `'field-name'`).

**Parameters:**

| Name        | Type                  | Description                            |
|-------------|-----------------------|----------------------------------------|
| `allocator` | `std.mem.Allocator`   | Memory allocator for the output text.   |
| `value`     | `Value`               | The value to serialize.                 |

**Returns:** `[]const u8` — The UZON text.

**Errors:** `error.OutOfMemory`

```zig
const text = try uzon.stringify(allocator, value);
```

**Roundtrip example:**

```zig
const source =
    \\name is "Alice"
    \\age is 30
;
const parsed = uzon.parse(allocator, source).value;
const output = try uzon.stringify(allocator, parsed);
const reparsed = uzon.parse(allocator, output).value;
// parsed and reparsed are structurally identical
```

---

#### `stringifyFile`

```zig
pub fn stringifyFile(allocator: std.mem.Allocator, value: Value, path: []const u8) !void
```

Serialize a `Value` and write the result to a file.

**Parameters:**

| Name        | Type                  | Description                    |
|-------------|-----------------------|--------------------------------|
| `allocator` | `std.mem.Allocator`   | Memory allocator.               |
| `value`     | `Value`               | The value to serialize.         |
| `path`      | `[]const u8`          | Filesystem path to write to.    |

**Errors:** `error.OutOfMemory`, file I/O errors.

```zig
try uzon.stringifyFile(allocator, config, "output.uzon");
```

---

### Comptime Deserialization

#### `parseInto`

```zig
pub fn parseInto(comptime T: type, allocator: std.mem.Allocator, source: []const u8) !T
```

Parse a UZON source string and deserialize the result directly into a native Zig type. Leverages Zig's comptime reflection for zero-cost type checking at compile time and range validation at runtime.

**Parameters:**

| Name        | Type                  | Description                        |
|-------------|-----------------------|------------------------------------|
| `T`         | `type` (comptime)     | The target Zig type.                |
| `allocator` | `std.mem.Allocator`   | Memory allocator.                   |
| `source`    | `[]const u8`          | UZON source text.                   |

**Returns:** `T`

**Errors:**

| Error              | Description                                                |
|--------------------|------------------------------------------------------------|
| `error.UzonSyntax` | UZON source has syntax, type, runtime, or circular errors. |
| `error.TypeMismatch` | UZON value type does not match the target Zig type.      |
| `error.OutOfRange`   | Integer value does not fit in the target integer type.   |
| `error.MissingField` | Required struct field is not present in the UZON struct. |
| `error.UnknownVariant` | Enum/union variant name not found in the Zig type.     |
| `error.LengthMismatch` | Array length does not match the UZON list/tuple length.|
| `error.OutOfMemory`    | Allocation failure.                                     |

```zig
const Config = struct {
    host: []const u8,
    port: u16,
    debug: bool = false,
};

const config = try uzon.parseInto(Config, allocator,
    \\host is "localhost"
    \\port is 8080
);
// config.host == "localhost"
// config.port == 8080
// config.debug == false (default)
```

---

#### `parseFileInto`

```zig
pub fn parseFileInto(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T
```

Parse a UZON file and deserialize the result into a native Zig type.

**Parameters:**

| Name        | Type                  | Description                        |
|-------------|-----------------------|------------------------------------|
| `T`         | `type` (comptime)     | The target Zig type.                |
| `allocator` | `std.mem.Allocator`   | Memory allocator.                   |
| `path`      | `[]const u8`          | Filesystem path to the UZON file.   |

**Returns:** `T`

**Errors:** Same as `parseInto`, plus file I/O errors.

```zig
const config = try uzon.parseFileInto(Config, allocator, "config.uzon");
```

---

#### `fromValue`

```zig
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: Value) !T
```

Convert an already-parsed `Value` into a native Zig type. This is the lower-level function used by `parseInto` and `parseFileInto`.

Available as `uzon.parse_into.fromValue`.

**Type mapping:**

| Zig type              | UZON value               | Notes                                        |
|-----------------------|--------------------------|----------------------------------------------|
| `bool`                | `bool_val`               |                                              |
| `u8`, `i32`, `u16`, ... | `integer`             | Range-checked at runtime.                    |
| `f32`, `f64`          | `float_val`, `integer`   | Integer to float adoption.                   |
| `[]const u8`          | `string`                 | Borrows the string (zero-copy).              |
| `[]u8`                | `string`                 | Allocates a copy via `allocator.dupe`.       |
| `[]const T`           | `list`, `tuple`          | Each element deserialized recursively.       |
| `[N]T`                | `list`, `tuple`          | Length must match exactly.                   |
| `?T`                  | any, `null_val`, `undefined` | `null`/`undefined` maps to Zig `null`.   |
| `struct`              | `struct_val`             | Fields matched by name. Defaults and optionals supported. |
| `enum`                | `enum_val`, `string`     | String-to-enum convenience.                  |
| `union(enum)`         | `tagged_union`           | Tag matched to union field name.             |

**Struct deserialization rules:**
- Each Zig struct field is looked up by name in the UZON struct.
- If a field is missing but has a default value, the default is used.
- If a field is missing and its type is `?T` (optional), it becomes `null`.
- If a field is missing and has no default and is not optional, `error.MissingField` is returned.

**Union/TaggedUnion transparency:** For non-union target types, UZON unions and tagged unions are automatically unwrapped to their inner value before deserialization.

```zig
const Shape = union(enum) { circle: f32, rect: struct { w: f32, h: f32 }, point: void };

const shape = try uzon.parse_into.fromValue(Shape, allocator, tagged_union_value);
switch (shape) {
    .circle => |r| { /* radius */ },
    .rect => |r| { /* r.w, r.h */ },
    .point => {},
}
```

---

### Value

```zig
pub const Value = union(enum) {
    null_val,              // null
    undefined,             // absence of value
    bool_val: bool,        // true / false
    integer: Integer,      // i128 + type annotation
    float_val: Float,      // f64 + type annotation
    string: []const u8,    // UTF-8 string
    list: List,            // [a, b, c] — homogeneous sequence
    tuple: Tuple,          // (a, b, c) — fixed-length heterogeneous
    struct_val: Struct,    // { key is value } — ordered map
    enum_val: Enum,        // variant from a set
    union_val: Union,      // untagged union
    tagged_union: TaggedUnion, // tagged union
    function: Function,    // closure
};
```

`Value` is the core runtime representation of all UZON data. A top-level UZON document evaluates to a `Value.struct_val` whose fields are the document's bindings.

#### Convenience constructors

```zig
Value.int(42)           // Integer with default i64 type
Value.float(3.14)       // Float with default f64 type
Value.boolean(true)     // Bool
Value.str("hello")      // String
```

#### Predicates

```zig
value.isUndefined()     // true if .undefined
value.isNull()          // true if .null_val
```

#### Type introspection

```zig
value.typeName()        // -> "null", "undefined", "bool", "integer", "float",
                        //    "string", "list", "tuple", "struct", "enum",
                        //    "union", "tagged_union", "function"
```

#### Union transparency

```zig
value.unwrapTransparent()  // Unwrap union_val or tagged_union to inner value
value.unwrapUntagged()     // Unwrap union_val only; tagged unions pass through
```

Per the UZON spec (§3.6/§3.7.1), unions and tagged unions are transparent — member access, type checking, and most operations pass through to the inner value. These methods extract the inner value for direct access.

---

### Value Subtypes

#### `Integer`

```zig
pub const Integer = struct {
    value: i128,
    type_ann: IntegerType = .{ .signed = 64 },
    explicit: bool = false,
};
```

All UZON integers are stored as `i128` with an associated type annotation. The `explicit` flag is `true` when the source contained an explicit `as` annotation (e.g., `42 as u8`).

| Field       | Type          | Description                                             |
|-------------|---------------|---------------------------------------------------------|
| `value`     | `i128`        | The integer value.                                       |
| `type_ann`  | `IntegerType` | Type annotation: `.arbitrary`, `.{ .signed = N }`, or `.{ .unsigned = N }`. |
| `explicit`  | `bool`        | Whether the type was explicitly annotated in source.     |

#### `IntegerType`

```zig
pub const IntegerType = union(enum) {
    arbitrary,       // untyped — adopts type from context
    signed: u16,     // i8, i16, i32, i64, i128, ... (bit width)
    unsigned: u16,   // u8, u16, u32, u64, u128, ... (bit width)
};
```

UZON supports arbitrary bit-width integers. The default type for untyped integer literals is `i64` (`.{ .signed = 64 }`).

---

#### `Float`

```zig
pub const Float = struct {
    value: f64,
    type_ann: FloatType = .f64,
    explicit: bool = false,
};
```

| Field       | Type        | Description                                          |
|-------------|-------------|------------------------------------------------------|
| `value`     | `f64`       | The float value (internally stored as f64).           |
| `type_ann`  | `FloatType` | Type annotation: `.f16`, `.f32`, `.f64`, `.f80`, `.f128`. |
| `explicit`  | `bool`      | Whether the type was explicitly annotated in source.  |

#### `FloatType`

```zig
pub const FloatType = enum { f16, f32, f64, f80, f128 };
```

---

#### `List`

```zig
pub const List = struct {
    elements: []const Value,
    element_type: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
};
```

A homogeneous sequence. `element_type` is set when the source contains an `as [Type]` annotation (e.g., `[1, 2, 3] as [i32]`). `type_name` is set when the list type is named via `called`.

| Field          | Type              | Description                            |
|----------------|-------------------|----------------------------------------|
| `elements`     | `[]const Value`   | The list elements.                      |
| `element_type` | `?[]const u8`     | Element type annotation, if present.    |
| `type_name`    | `?[]const u8`     | Named type via `called`, if present.    |

---

#### `Tuple`

```zig
pub const Tuple = struct {
    elements: []const Value,
};
```

A fixed-length heterogeneous sequence. Single-element tuples require a trailing comma: `(42,)`.

| Field      | Type              | Description       |
|------------|-------------------|-------------------|
| `elements` | `[]const Value`   | The tuple elements.|

---

#### `Struct`

```zig
pub const Struct = struct {
    keys: []const []const u8,
    values: []const Value,
    type_name: ?[]const u8 = null,
};
```

An ordered map of field name to value. Field order is preserved from the source. Duplicate keys within the same struct are not allowed.

| Field       | Type                    | Description                          |
|-------------|-------------------------|--------------------------------------|
| `keys`      | `[]const []const u8`    | Field names, in source order.         |
| `values`    | `[]const Value`         | Field values, parallel to `keys`.     |
| `type_name` | `?[]const u8`           | Named type via `called`, if present.  |

**Lookup:**

```zig
pub fn get(self: Struct, key: []const u8) ?Value
```

Look up a field by name. Returns `null` if the field does not exist.

```zig
const host = doc.struct_val.get("host") orelse return error.MissingField;
```

---

#### `Enum`

```zig
pub const Enum = struct {
    value: []const u8,
    variants: []const []const u8,
    type_name: ?[]const u8 = null,
};
```

An enum value — one selected variant from a defined set.

| Field       | Type                    | Description                          |
|-------------|-------------------------|--------------------------------------|
| `value`     | `[]const u8`            | The selected variant name.            |
| `variants`  | `[]const []const u8`    | All possible variant names.           |
| `type_name` | `?[]const u8`           | Named type via `called`, if present.  |

```zig
// red from red, green, blue called Color
const color = value.enum_val;
color.value;      // "red"
color.variants;   // {"red", "green", "blue"}
color.type_name;  // "Color"
```

---

#### `Union`

```zig
pub const Union = struct {
    value: *const Value,
    types: []const []const u8,
    type_name: ?[]const u8 = null,
};
```

An untagged union — a value that can be one of several types.

| Field       | Type                    | Description                            |
|-------------|-------------------------|----------------------------------------|
| `value`     | `*const Value`          | Pointer to the inner value.             |
| `types`     | `[]const []const u8`    | Possible type names.                    |
| `type_name` | `?[]const u8`           | Named type via `called`, if present.    |

---

#### `TaggedUnion`

```zig
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
```

A tagged union — a value paired with an explicit variant tag and a set of possible variants.

| Field       | Type                    | Description                                   |
|-------------|-------------------------|-----------------------------------------------|
| `value`     | `*const Value`          | Pointer to the inner value (payload).          |
| `tag`       | `[]const u8`            | The active variant tag.                         |
| `variants`  | `[]const VariantInfo`   | All possible variants with optional type info.  |
| `type_name` | `?[]const u8`           | Named type via `called`, if present.            |

```zig
// "ok" named success from success as string, error as string called Result
const tu = value.tagged_union;
tu.tag;                     // "success"
tu.value.*;                 // Value.string "ok"
tu.variants[0].name;        // "success"
tu.variants[0].type_name;   // "string"
tu.type_name;               // "Result"
```

---

#### `Function`

```zig
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
```

A function value (closure). Functions capture their definition scope — they are first-class values that can be stored in bindings, passed as arguments, and returned from other functions.

Functions are opaque — they cannot be compared for equality.

---

#### `TypeDef`

```zig
pub const TypeDef = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        enum_type: struct { variants: []const []const u8 },
        union_type: struct { types: []const []const u8 },
        tagged_union_type: struct { variants: []const TaggedUnion.VariantInfo },
        struct_type: struct { fields: []const FieldInfo },
        function_type: struct { param_types: []const []const u8, return_type: []const u8 },
        list_type: struct { element_type: ?[]const u8 },
    };

    pub const FieldInfo = struct {
        name: []const u8,
        type_category: []const u8,
        type_annotation: ?[]const u8 = null,
    };
};
```

A type definition registered via the `called` keyword. Stores the full shape of named types for reuse with the `as` operator.

---

### Error Handling

#### `UzonError`

```zig
pub const UzonError = struct {
    kind: ErrorKind,
    message: []const u8,
    suggestion: ?[]const u8 = null,
    location: Location,
    import_trace: std.ArrayListUnmanaged(Location),
    allocator: std.mem.Allocator,
};
```

A UZON error with a category, human-readable message, precise source location, and optional import trace for errors originating in imported files.

| Field          | Type                                   | Description                                       |
|----------------|----------------------------------------|---------------------------------------------------|
| `kind`         | `ErrorKind`                            | Error category.                                    |
| `message`      | `[]const u8`                           | Human-readable error description.                  |
| `suggestion`   | `?[]const u8`                          | Optional suggestion for fixing the error.          |
| `location`     | `Location`                             | Source location (line, column, optional filename).  |
| `import_trace` | `ArrayListUnmanaged(Location)`         | Stack of import locations for cross-file errors.    |

**Methods:**

```zig
// Print the error to stderr
error_val.dump();

// Format the error to a string
const msg = try error_val.toString(allocator);

// Write to any writer
try error_val.write(writer);
```

**Output format:**

```
TypeError: cannot convert to bool
  at config.uzon:5:12
  imported from main.uzon:3:8
  Suggestion: only identity conversion (bool to bool) is permitted
```

---

#### `ErrorKind`

```zig
pub const ErrorKind = enum {
    syntax,    // Lexer/parser errors
    circular,  // Circular reference between bindings or imports
    type_,     // Type annotation, conversion, or compatibility errors
    runtime,   // Evaluation errors (division by zero, overflow, etc.)
};
```

Error categories per the UZON specification (§11.2). Priority order: syntax > circular > type > runtime. Higher-priority errors suppress lower-priority ones.

---

#### `Location`

```zig
pub const Location = struct {
    line: u32 = 0,
    col: u32 = 0,
    filename: ?[]const u8 = null,
};
```

Source location for error reporting. Line and column are 1-based. Column counts Unicode scalar values, not bytes (per §11.2).

---

#### `Error` (error set)

```zig
pub const Error = error{
    UzonSyntax,
    UzonType,
    UzonRuntime,
    UzonCircular,
    OutOfMemory,
};
```

The Zig error set used by `parseInto` and `parseFileInto` when a UZON-level error is encountered. Use `ParseResult` (returned by `parse`, `parseFile`, `parseWithBaseDir`) for richer error information.

---

### Public Modules

The library re-exports its internal modules for advanced use cases:

```zig
const uzon = @import("uzon");

uzon.Token      // Token types and keyword table
uzon.Lexer      // Tokenizer
uzon.Parser     // AST parser
uzon.Ast        // Abstract syntax tree nodes
uzon.Value      // Value type and subtypes (also uzon.ValueMod)
uzon.Evaluator  // AST evaluator
uzon.Scope      // Scope management
uzon.err        // Error types (UzonError, ErrorKind, Location)
uzon.stringify_mod  // Stringify module (stringify, stringifyValue, stringifyFile)
uzon.parse_into    // Deserialization module (fromValue)
```

These are available for building custom tooling (formatters, linters, language servers, etc.) but are not part of the stable API.

---

## Build & Test

```bash
# Build the library
zig build

# Run all tests (unit tests + conformance tests)
zig build test
```

The test suite includes unit tests for each module and runs the full [UZON conformance test suite](https://github.com/uzon-dev/conformance) covering parsing, evaluation, and roundtrip fidelity.

## License

MIT
