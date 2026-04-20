const std = @import("std");
const val = @import("Value.zig");
const Value = val.Value;
const Integer = val.Integer;
const Float = val.Float;
const IntegerType = val.IntegerType;
const FloatType = val.FloatType;

// ── Type adoption ────────────────────────────────────────────

/// Adopt an untyped literal to a target type name (§5 adoption rule).
pub fn adoptToType(v: Value, type_name: []const u8) Value {
    switch (v) {
        .integer => |iv| {
            if (iv.explicit) return v;
            if (parseIntegerTypeName(type_name)) |target|
                return Value{ .integer = .{ .value = iv.value, .type_ann = target, .explicit = true } };
            if (parseFloatTypeName(type_name)) |target|
                return Value{ .float_val = .{ .value = @floatFromInt(iv.value), .type_ann = target, .explicit = true } };
            return v;
        },
        .float_val => |fv| {
            if (fv.explicit) return v;
            if (parseFloatTypeName(type_name)) |target|
                return Value{ .float_val = .{ .value = fv.value, .type_ann = target, .explicit = true } };
            return v;
        },
        else => return v,
    }
}

/// Check if a value's runtime type matches the given type name.
pub fn valueMatchesType(v: Value, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "null")) return v == .null_val;
    if (std.mem.eql(u8, type_name, "bool")) return v == .bool_val;
    if (std.mem.eql(u8, type_name, "string")) return v == .string;
    if (std.mem.eql(u8, type_name, "integer")) return v == .integer;
    if (std.mem.eql(u8, type_name, "float")) return v == .float_val;
    if (std.mem.eql(u8, type_name, "struct")) return v == .struct_val;
    if (std.mem.eql(u8, type_name, "list")) return v == .list;
    if (std.mem.eql(u8, type_name, "tuple")) return v == .tuple;
    if (std.mem.eql(u8, type_name, "enum")) return v == .enum_val;
    if (std.mem.eql(u8, type_name, "function")) return v == .function;

    if (parseIntegerTypeName(type_name)) |target_type| {
        return switch (v) {
            .integer => |iv| intTypesMatch(iv.type_ann, target_type),
            else => false,
        };
    }
    if (parseFloatTypeName(type_name)) |target_type| {
        return switch (v) {
            .float_val => |fv| fv.type_ann == target_type,
            else => false,
        };
    }

    // Named types
    switch (v) {
        .enum_val => |e| if (e.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        .union_val => |u| if (u.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        .tagged_union => |tu| if (tu.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        .struct_val => |s| if (s.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        .list => |l| if (l.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        .function => |f| if (f.type_name) |tn| return std.mem.eql(u8, tn, type_name),
        else => {},
    }
    return false;
}

pub fn isValidVariantTag(variant_infos: []const val.TaggedUnion.VariantInfo, tag: []const u8) bool {
    for (variant_infos) |v| {
        if (std.mem.eql(u8, v.name, tag)) return true;
    }
    return false;
}

/// Type category for branch type checking (§5.9). null → "null", undefined → null.
pub fn valueTypeCategory(v: Value) ?[]const u8 {
    return switch (v) {
        .null_val => "null",
        .undefined => null,
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

/// Check branch type compatibility (§5.9). null/undefined compatible with anything; int/float cross-compatible.
pub fn branchTypesCompatible(a: Value, b: Value) bool {
    if (a.isNull() or b.isNull()) return true;
    const cat_a = valueTypeCategory(a) orelse return true;
    const cat_b = valueTypeCategory(b) orelse return true;
    if (!std.mem.eql(u8, cat_a, cat_b)) return isNumericMix(cat_a, cat_b);
    // §7.3 nominal identity: if both sides carry a nominal type_name for
    // a nominal category (struct/enum/union/tagged_union), they must match.
    return nominalNamesCompatible(a, b);
}

fn nominalNamesCompatible(a: Value, b: Value) bool {
    const an = nominalName(a);
    const bn = nominalName(b);
    if (an == null or bn == null) return true;
    return std.mem.eql(u8, an.?, bn.?);
}

fn nominalName(v: Value) ?[]const u8 {
    return switch (v) {
        .struct_val => |s| s.type_name,
        .enum_val => |e| e.type_name,
        .union_val => |u| u.type_name,
        .tagged_union => |tu| tu.type_name,
        .list => |l| l.type_name,
        else => null,
    };
}

fn isNumericMix(a: []const u8, b: []const u8) bool {
    return (std.mem.eql(u8, a, "integer") and std.mem.eql(u8, b, "float")) or
        (std.mem.eql(u8, a, "float") and std.mem.eql(u8, b, "integer"));
}

// ── Type name parsing ────────────────────────────────────────

pub fn parseIntegerTypeName(name: []const u8) ?IntegerType {
    if (name.len < 2) return null;
    const prefix = name[0];
    if (prefix != 'i' and prefix != 'u') return null;
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return if (prefix == 'i') IntegerType{ .signed = bits } else IntegerType{ .unsigned = bits };
}

pub fn parseFloatTypeName(name: []const u8) ?FloatType {
    if (std.mem.eql(u8, name, "f16")) return .f16;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "f80")) return .f80;
    if (std.mem.eql(u8, name, "f128")) return .f128;
    return null;
}

pub fn intTypeName(t: IntegerType) ?[]const u8 {
    return switch (t) {
        .arbitrary => null,
        .signed => |bits| switch (bits) {
            8 => "i8",
            16 => "i16",
            32 => "i32",
            64 => "i64",
            128 => "i128",
            else => null,
        },
        .unsigned => |bits| switch (bits) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            64 => "u64",
            128 => "u128",
            else => null,
        },
    };
}

pub fn intTypeNameAlloc(allocator: std.mem.Allocator, t: IntegerType) ?[]const u8 {
    if (intTypeName(t)) |name| return name;
    return switch (t) {
        .arbitrary => null,
        .signed => |bits| std.fmt.allocPrint(allocator, "i{d}", .{bits}) catch null,
        .unsigned => |bits| std.fmt.allocPrint(allocator, "u{d}", .{bits}) catch null,
    };
}

pub fn floatTypeName(t: FloatType) ?[]const u8 {
    return switch (t) {
        .f16 => "f16",
        .f32 => "f32",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
    };
}

// ── Integer range checking ───────────────────────────────────

pub fn intFitsType(value: i128, int_type: IntegerType) bool {
    return switch (int_type) {
        .arbitrary => true,
        .signed => |bits| intFitsSigned(value, bits),
        .unsigned => |bits| intFitsUnsigned(value, bits),
    };
}

pub fn intFitsSigned(value: i128, bits: u16) bool {
    if (bits == 0) return value == 0;
    if (bits >= 128) return true;
    const shift: u7 = @intCast(bits - 1);
    const min_val: i128 = -(@as(i128, 1) << shift);
    const max_val: i128 = (@as(i128, 1) << shift) - 1;
    return value >= min_val and value <= max_val;
}

pub fn intFitsUnsigned(value: i128, bits: u16) bool {
    if (value < 0) return false;
    if (bits == 0) return value == 0;
    if (bits >= 128) return true;
    const shift: u7 = @intCast(bits);
    const max_val: i128 = (@as(i128, 1) << shift) - 1;
    return value <= max_val;
}

pub fn intTypesMatch(a: IntegerType, b: IntegerType) bool {
    return switch (a) {
        .arbitrary => b == .arbitrary,
        .signed => |ab| switch (b) {
            .signed => |bb| ab == bb,
            else => false,
        },
        .unsigned => |ab| switch (b) {
            .unsigned => |bb| ab == bb,
            else => false,
        },
    };
}

// ── Equality ────────────────────────────────────────────────

pub fn sameCategory(a: Value, b: Value) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

/// Check if two untagged unions have the same type (v0.8 §5.2).
/// Named unions: nominal identity (type_name must match).
/// Anonymous unions: structural identity (member type set equality, order-insensitive).
pub fn unionTypesMatch(a: val.Union, b: val.Union) bool {
    // Both named → nominal
    if (a.type_name != null and b.type_name != null)
        return std.mem.eql(u8, a.type_name.?, b.type_name.?);
    // One named, one not → different
    if (a.type_name != null or b.type_name != null) return false;
    // Both anonymous → structural (set equality)
    if (a.types.len != b.types.len) return false;
    for (a.types) |at| {
        var found = false;
        for (b.types) |bt| {
            if (std.mem.eql(u8, at, bt)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Runtime equality (IEEE 754: NaN != NaN). Used by `is`/`is not`.
pub fn runtimeEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null_val => true,
        .undefined => true,
        .bool_val => |av| av == b.bool_val,
        .integer => |ai| ai.value == b.integer.value,
        .float_val => |af| af.value == b.float_val.value,
        .string => |as_| std.mem.eql(u8, as_, b.string),
        .enum_val => |ae| std.mem.eql(u8, ae.value, b.enum_val.value),
        .list => |al| {
            if (al.elements.len != b.list.elements.len) return false;
            for (al.elements, b.list.elements) |ae, be| {
                if (!runtimeEqual(ae, be)) return false;
            }
            return true;
        },
        .tuple => |at_| {
            if (at_.elements.len != b.tuple.elements.len) return false;
            for (at_.elements, b.tuple.elements) |ae, be| {
                if (!runtimeEqual(ae, be)) return false;
            }
            return true;
        },
        .struct_val => |as_| {
            if (as_.keys.len != b.struct_val.keys.len) return false;
            for (as_.keys, as_.values) |key, val_a| {
                if (b.struct_val.get(key)) |val_b| {
                    if (!runtimeEqual(val_a, val_b)) return false;
                } else return false;
            }
            return true;
        },
        .union_val => |au| runtimeEqual(au.value.*, b.union_val.value.*),
        .tagged_union => |at_| std.mem.eql(u8, at_.tag, b.tagged_union.tag) and runtimeEqual(at_.value.*, b.tagged_union.value.*),
        .function => false,
    };
}

/// Structural equality (NaN == NaN). Used for conformance comparison.
pub fn valuesEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null_val => true,
        .undefined => true,
        .bool_val => |av| av == b.bool_val,
        .integer => |ai| ai.value == b.integer.value,
        .float_val => |af| blk: {
            if (std.math.isNan(af.value) and std.math.isNan(b.float_val.value)) break :blk true;
            break :blk af.value == b.float_val.value;
        },
        .string => |as_| std.mem.eql(u8, as_, b.string),
        .enum_val => |ae| std.mem.eql(u8, ae.value, b.enum_val.value),
        .list => |al| {
            if (al.elements.len != b.list.elements.len) return false;
            for (al.elements, b.list.elements) |ae, be| {
                if (!valuesEqual(ae, be)) return false;
            }
            return true;
        },
        .tuple => |at_| {
            if (at_.elements.len != b.tuple.elements.len) return false;
            for (at_.elements, b.tuple.elements) |ae, be| {
                if (!valuesEqual(ae, be)) return false;
            }
            return true;
        },
        .struct_val => |as_| {
            if (as_.keys.len != b.struct_val.keys.len) return false;
            for (as_.keys, as_.values) |key, val_a| {
                if (b.struct_val.get(key)) |val_b| {
                    if (!valuesEqual(val_a, val_b)) return false;
                } else return false;
            }
            return true;
        },
        .union_val => |au| valuesEqual(au.value.*, b.union_val.value.*),
        .tagged_union => |at_| std.mem.eql(u8, at_.tag, b.tagged_union.tag) and valuesEqual(at_.value.*, b.tagged_union.value.*),
        .function => false,
    };
}

// ── Numeric literal parsing ──────────────────────────────────

pub fn parseIntegerText(allocator: std.mem.Allocator, text: []const u8) !i128 {
    if (text.len == 0) return error.InvalidCharacter;
    var s = text;
    var negative = false;
    if (s[0] == '-') {
        negative = true;
        s = s[1..];
    }
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => {
                base = 16;
                s = s[2..];
            },
            'o', 'O' => {
                base = 8;
                s = s[2..];
            },
            'b', 'B' => {
                base = 2;
                s = s[2..];
            },
            else => {},
        }
    }
    const stripped = try stripUnderscores(allocator, s);
    if (stripped.len == 0) return error.InvalidCharacter;
    const abs_val = std.fmt.parseInt(u128, stripped, base) catch return error.InvalidCharacter;
    if (negative) {
        if (abs_val > @as(u128, @intCast(-@as(i129, std.math.minInt(i128))))) return error.Overflow;
        return -@as(i128, @intCast(abs_val));
    } else {
        if (abs_val > @as(u128, @intCast(std.math.maxInt(i128)))) return error.Overflow;
        return @intCast(abs_val);
    }
}

pub fn parseFloatText(allocator: std.mem.Allocator, text: []const u8) !f64 {
    if (text.len == 0) return error.InvalidCharacter;
    const stripped = try stripUnderscores(allocator, text);
    return std.fmt.parseFloat(f64, stripped) catch error.InvalidCharacter;
}

fn stripUnderscores(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null) return s;
    var buf = std.ArrayListUnmanaged(u8){};
    for (s) |c| {
        if (c != '_') try buf.append(allocator, c);
    }
    return buf.items;
}

// ── Numeric type adoption helpers ────────────────────────────

/// Cross-category adoption for binary operations.
pub fn adoptNumericTypes(left: Value, right: Value) [2]Value {
    // int + float → adopt int to float
    switch (left) {
        .integer => |li| if (right == .float_val and !li.explicit) {
            return .{ Value{ .float_val = .{ .value = @floatFromInt(li.value), .type_ann = right.float_val.type_ann, .explicit = right.float_val.explicit } }, right };
        },
        .float_val => |lf| if (right == .integer and !right.integer.explicit) {
            return .{ left, Value{ .float_val = .{ .value = @floatFromInt(right.integer.value), .type_ann = lf.type_ann, .explicit = lf.explicit } } };
        },
        else => {},
    }
    // Same-category: untyped adopts typed
    switch (left) {
        .integer => |li| if (right == .integer) {
            const ri = right.integer;
            if (!li.explicit and ri.explicit)
                return .{ Value{ .integer = .{ .value = li.value, .type_ann = ri.type_ann, .explicit = false } }, right };
            if (li.explicit and !ri.explicit)
                return .{ left, Value{ .integer = .{ .value = ri.value, .type_ann = li.type_ann, .explicit = false } } };
        },
        .float_val => |lf| if (right == .float_val) {
            const rf = right.float_val;
            if (!lf.explicit and rf.explicit)
                return .{ Value{ .float_val = .{ .value = lf.value, .type_ann = rf.type_ann, .explicit = false } }, right };
            if (lf.explicit and !rf.explicit)
                return .{ left, Value{ .float_val = .{ .value = rf.value, .type_ann = lf.type_ann, .explicit = false } } };
        },
        else => {},
    }
    return .{ left, right };
}

pub fn adoptIntType(left: Integer, right: Integer) IntegerType {
    if (left.explicit) return left.type_ann;
    if (right.explicit) return right.type_ann;
    return left.type_ann;
}

pub fn adoptFloatType(left: Float, right: Float) FloatType {
    if (left.explicit) return left.type_ann;
    if (right.explicit) return right.type_ann;
    return left.type_ann;
}

/// Format float per §5.11.2 spec rules.
/// §5.11.2 Float → string. ECMAScript-style shortest round-trip representation
/// with UZON-specific requirements: result always contains '.', scientific
/// notation uses `eN` (no sign on positive exponent), `.0` suffix when integer.
pub fn formatFloat(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "nan";
    if (std.math.isInf(value)) return if (std.math.signbit(value)) "-inf" else "inf";
    if (value == 0.0) return if (std.math.signbit(value)) "-0.0" else "0.0";

    // Zig's scientific renderer gives shortest round-trip as "<mantissa>e<exp>",
    // e.g. `3.14e0`, `1e100`, `1.5e-6`. Parse it, then reformat per ECMAScript rules.
    var raw_buf: [64]u8 = undefined;
    const raw = std.fmt.float.render(&raw_buf, value, .{ .mode = .scientific }) catch return error.OutOfMemory;

    const neg = raw[0] == '-';
    const body = if (neg) raw[1..] else raw;
    const e_pos = std.mem.indexOfScalar(u8, body, 'e') orelse return error.OutOfMemory;
    const mantissa_raw = body[0..e_pos];
    const exp = std.fmt.parseInt(i32, body[e_pos + 1 ..], 10) catch return error.OutOfMemory;

    // Split mantissa into integer and fraction digits (without the '.').
    var digit_buf: [64]u8 = undefined;
    const dot_idx = std.mem.indexOfScalar(u8, mantissa_raw, '.');
    const digits: []const u8 = if (dot_idx) |di| blk: {
        @memcpy(digit_buf[0..di], mantissa_raw[0..di]);
        @memcpy(digit_buf[di .. mantissa_raw.len - 1], mantissa_raw[di + 1 ..]);
        break :blk digit_buf[0 .. mantissa_raw.len - 1];
    } else mantissa_raw;
    const dot_offset: i32 = if (dot_idx) |di| @intCast(di) else @intCast(mantissa_raw.len);

    // Position of decimal point relative to start of `digits` (0 = before digits[0]).
    const point: i32 = dot_offset + exp;
    // n = position of leading digit in ECMAScript terms (10^(n-1) <= |v| < 10^n).
    const n: i32 = point;

    const sign_prefix: []const u8 = if (neg) "-" else "";

    var out = std.ArrayListUnmanaged(u8){};
    try out.appendSlice(allocator, sign_prefix);

    if (n >= 1 and n <= 21) {
        // Decimal, integer/mixed form. Place decimal point at `point`.
        const p: usize = @intCast(point);
        if (p >= digits.len) {
            try out.appendSlice(allocator, digits);
            try out.appendNTimes(allocator, '0', p - digits.len);
            try out.appendSlice(allocator, ".0");
        } else {
            try out.appendSlice(allocator, digits[0..p]);
            try out.append(allocator, '.');
            try out.appendSlice(allocator, digits[p..]);
        }
    } else if (n >= -5 and n <= 0) {
        // Decimal, pure fraction form: 0.<zeros><digits>
        try out.appendSlice(allocator, "0.");
        const leading_zeros: usize = @intCast(-point);
        try out.appendNTimes(allocator, '0', leading_zeros);
        try out.appendSlice(allocator, digits);
    } else {
        // Scientific: <d>.<rest>e<exp>  (always include '.0' when mantissa is single digit)
        try out.append(allocator, digits[0]);
        if (digits.len > 1) {
            try out.append(allocator, '.');
            try out.appendSlice(allocator, digits[1..]);
        } else {
            try out.appendSlice(allocator, ".0");
        }
        try out.append(allocator, 'e');
        try std.fmt.format(out.writer(allocator), "{d}", .{n - 1});
    }

    return out.toOwnedSlice(allocator);
}

/// Default value for speculative branch narrowing.
pub fn defaultValueForType(type_name: []const u8) Value {
    if (std.mem.eql(u8, type_name, "string")) return Value.str("");
    if (std.mem.eql(u8, type_name, "bool")) return Value.boolean(false);
    if (std.mem.eql(u8, type_name, "null")) return .null_val;
    if (parseIntegerTypeName(type_name)) |t| return Value{ .integer = .{ .value = 0, .type_ann = t, .explicit = true } };
    if (parseFloatTypeName(type_name)) |t| return Value{ .float_val = .{ .value = 0.0, .type_ann = t, .explicit = true } };
    if (std.mem.eql(u8, type_name, "integer")) return Value{ .integer = .{ .value = 0 } };
    if (std.mem.eql(u8, type_name, "float")) return Value{ .float_val = .{ .value = 0.0 } };
    return .undefined;
}

/// Parse member name as numeric index or named ordinal (first=0..tenth=9).
pub fn parseOrdinalOrIndex(member: []const u8) ?usize {
    const ordinals = [_][]const u8{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth" };
    for (ordinals, 0..) |name, i| {
        if (std.mem.eql(u8, member, name)) return i;
    }
    return std.fmt.parseInt(usize, member, 10) catch null;
}
