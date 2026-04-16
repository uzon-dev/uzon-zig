const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Ast = @import("Ast.zig");
const val = @import("Value.zig");
const Value = val.Value;
const Scope = @import("Scope.zig");
const h = @import("eval_helpers.zig");

const EvalError = Evaluator.EvalError;

pub fn isBuiltinTypeName(name: []const u8) bool {
    const builtins = [_][]const u8{ "bool", "string", "null", "integer", "float", "list", "tuple", "struct", "function" };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    if (h.parseIntegerTypeName(name) != null) return true;
    if (h.parseFloatTypeName(name) != null) return true;
    return false;
}

// ── Type annotation (`as`) ───────────────────────────────────

pub fn evalTypeAnnotation(self: *Evaluator, expr_node: *const Ast.Node, type_expr: *const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(expr_node, scope, exclude);

    const type_name = switch (type_expr.data) {
        .name => |n| n,
        .list => |inner_type| return annotateList(self, expr_node, inner_type, value, scope, span),
        .path => |segments| return annotatePath(self, expr_node, segments, type_expr, value, scope, exclude, span),
        else => {
            if (value.isUndefined()) return .undefined;
            return value;
        },
    };

    // Enum variant resolution for undefined identifiers
    if (value.isUndefined()) {
        if (scope.getType(type_name)) |td| {
            switch (td.kind) {
                .enum_type => |et| {
                    if (expr_node.kind == .identifier) {
                        const name = expr_node.kind.identifier.name;
                        for (et.variants) |v| {
                            if (std.mem.eql(u8, v, name))
                                return Value{ .enum_val = .{ .value = name, .variants = et.variants, .type_name = type_name } };
                        }
                        return self.typeErr("not a variant of the enum type", span.line, span.col);
                    }
                },
                .tagged_union_type => |tut| {
                    if (expr_node.kind == .identifier) {
                        const name = expr_node.kind.identifier.name;
                        for (tut.variants) |v| {
                            if (std.mem.eql(u8, v.name, name)) {
                                const inner = try self.allocator.create(Value);
                                inner.* = .null_val;
                                return Value{ .tagged_union = .{ .value = inner, .tag = name, .variants = tut.variants, .type_name = type_name } };
                            }
                        }
                        return self.typeErr("not a variant of the tagged union type", span.line, span.col);
                    }
                },
                else => {},
            }
            return .undefined;
        }
        if (!isBuiltinTypeName(type_name))
            return self.typeErr("unknown type name in annotation", span.line, span.col);
        return .undefined;
    }

    // Numeric type annotations
    if (h.parseIntegerTypeName(type_name)) |int_type| {
        return switch (value) {
            .integer => |iv| blk: {
                if (!h.intFitsType(iv.value, int_type))
                    return self.typeErr("integer value out of range for type annotation", span.line, span.col);
                break :blk Value{ .integer = .{ .value = iv.value, .type_ann = int_type, .explicit = true } };
            },
            else => self.typeErr("cannot annotate non-integer as integer type", span.line, span.col),
        };
    }
    if (h.parseFloatTypeName(type_name)) |float_type| {
        return switch (value) {
            .float_val => |fv| Value{ .float_val = .{ .value = fv.value, .type_ann = float_type, .explicit = true } },
            .integer => |iv| blk: {
                if (!iv.explicit)
                    break :blk Value{ .float_val = .{ .value = @floatFromInt(iv.value), .type_ann = float_type, .explicit = true } };
                return self.typeErr("cannot annotate explicitly-typed integer as float", span.line, span.col);
            },
            else => self.typeErr("cannot annotate non-numeric as float type", span.line, span.col),
        };
    }

    // Built-in type names
    if (std.mem.eql(u8, type_name, "bool")) {
        if (value != .bool_val) return self.typeErr("value is not bool", span.line, span.col);
        return value;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        if (value != .string) return self.typeErr("value is not string", span.line, span.col);
        return value;
    }
    if (std.mem.eql(u8, type_name, "null")) {
        if (value != .null_val) return self.typeErr("value is not null", span.line, span.col);
        return value;
    }

    // Named type annotation (from `called` registry)
    if (scope.getType(type_name)) |td|
        return stampNamedType(self, expr_node, td, type_name, value, span);

    return self.typeErr("unknown type name in annotation", span.line, span.col);
}

fn annotateList(self: *Evaluator, expr_node: *const Ast.Node, inner_type: *const Ast.TypeExpr, value: Value, scope: *Scope, span: Ast.Span) EvalError!Value {
    if (value.isUndefined()) return .undefined;
    if (value != .list) return value;

    const et = try typeExprToString(self, inner_type.*);

    const inner_type_name: ?[]const u8 = switch (inner_type.data) {
        .name => |n| n,
        .path => |segments| resolvePathTypeName(self, segments, inner_type.*, scope),
        else => null,
    };

    // Enum variant resolution for list elements
    if (inner_type_name) |itn| {
        if (scope.getType(itn)) |td| {
            if (td.kind == .enum_type and expr_node.kind == .list_literal) {
                const ev = td.kind.enum_type;
                const ast_elems = expr_node.kind.list_literal.elements;
                const new_elems = try self.allocator.alloc(Value, ast_elems.len);
                for (ast_elems, value.list.elements, 0..) |ast_e, val_e, j| {
                    if (val_e.isUndefined() and ast_e.kind == .identifier) {
                        const name = ast_e.kind.identifier.name;
                        var resolved = false;
                        for (ev.variants) |v| {
                            if (std.mem.eql(u8, v, name)) {
                                new_elems[j] = Value{ .enum_val = .{ .value = name, .variants = ev.variants, .type_name = itn } };
                                resolved = true;
                                break;
                            }
                        }
                        if (!resolved) new_elems[j] = val_e;
                    } else if (val_e == .enum_val) {
                        new_elems[j] = Value{ .enum_val = .{ .value = val_e.enum_val.value, .variants = ev.variants, .type_name = itn } };
                    } else {
                        new_elems[j] = val_e;
                    }
                }
                return Value{ .list = .{ .elements = new_elems, .element_type = et } };
            }
        }
    }

    // Validate and adopt list elements
    if (inner_type_name) |itn| {
        const adopted = try self.allocator.alloc(Value, value.list.elements.len);
        if (scope.getType(itn) != null) {
            for (value.list.elements, 0..) |elem, j| {
                if (elem.isUndefined() or elem.isNull()) {
                    adopted[j] = elem;
                } else {
                    var a = h.adoptToType(elem, itn);
                    if (a == .struct_val and a.struct_val.type_name == null)
                        a = Value{ .struct_val = .{ .keys = a.struct_val.keys, .values = a.struct_val.values, .type_name = itn } };
                    if (!h.valueMatchesType(a, itn))
                        return self.typeErr("list element does not match declared element type", span.line, span.col);
                    adopted[j] = a;
                }
            }
        } else {
            for (value.list.elements, 0..) |elem, j| adopted[j] = h.adoptToType(elem, itn);
        }
        return Value{ .list = .{ .elements = adopted, .element_type = et } };
    }

    return Value{ .list = .{ .elements = value.list.elements, .element_type = et } };
}

fn annotatePath(self: *Evaluator, expr_node: *const Ast.Node, segments: []const []const u8, type_expr: *const Ast.TypeExpr, value: Value, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    if (resolvePathTypeName(self, segments, type_expr.*, scope)) |rn| {
        const name_te = Ast.TypeExpr{ .data = .{ .name = rn }, .span = span };
        return evalTypeAnnotation(self, expr_node, &name_te, scope, exclude, span);
    }
    if (value.isUndefined()) return .undefined;
    return value;
}

fn resolvePathTypeName(self: *Evaluator, segments: []const []const u8, te: Ast.TypeExpr, scope: *Scope) ?[]const u8 {
    if (typeExprToString(self, te) catch null) |pn|
        if (scope.getType(pn) != null) return pn;
    const final_seg = segments[segments.len - 1];
    var i: usize = 0;
    while (i < segments.len - 1) : (i += 1) {
        const prefix = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ segments[i], final_seg }) catch continue;
        if (scope.getType(prefix) != null) return prefix;
    }
    if (scope.getType(final_seg) != null) return final_seg;
    return null;
}

fn stampNamedType(self: *Evaluator, expr_node: *const Ast.Node, td: *const val.TypeDef, type_name: []const u8, value: Value, span: Ast.Span) EvalError!Value {
    // Enum variant resolution: identifier shadowed by variant name
    if (td.kind == .enum_type) {
        if (expr_node.kind == .identifier) {
            const name = expr_node.kind.identifier.name;
            for (td.kind.enum_type.variants) |v| {
                if (std.mem.eql(u8, v, name))
                    return Value{ .enum_val = .{ .value = name, .variants = td.kind.enum_type.variants, .type_name = type_name } };
            }
        }
    }

    var result = value;
    switch (result) {
        .enum_val => |e| {
            if (td.kind == .enum_type) {
                const et = td.kind.enum_type;
                var found = false;
                for (et.variants) |v| if (std.mem.eql(u8, v, e.value)) {
                    found = true;
                    break;
                };
                if (!found) return self.typeErr("not a variant of the named enum type", span.line, span.col);
                result = Value{ .enum_val = .{ .value = e.value, .variants = et.variants, .type_name = type_name } };
            }
        },
        .tagged_union => |tu| result = Value{ .tagged_union = .{ .value = tu.value, .tag = tu.tag, .variants = tu.variants, .type_name = type_name } },
        .union_val => |u| result = Value{ .union_val = .{ .value = u.value, .types = u.types, .type_name = type_name } },
        .struct_val => |s| {
            var final_values = s.values;
            if (td.kind == .struct_type) {
                const st = td.kind.struct_type;
                if (s.keys.len != st.fields.len) return self.typeErr("struct shape does not match named type", span.line, span.col);
                const new_values = try self.allocator.alloc(Value, s.values.len);
                @memcpy(new_values, s.values);
                for (st.fields) |f| {
                    const fi = for (s.keys, 0..) |k, ki| {
                        if (std.mem.eql(u8, k, f.name)) break ki;
                    } else return self.typeErr("struct missing field for named type", span.line, span.col);
                    const fval = s.values[fi];
                    if (!fval.isNull() and !fval.isUndefined()) {
                        if (!std.mem.eql(u8, fval.typeName(), f.type_category))
                            return self.typeErr("struct field type does not match named type definition", span.line, span.col);
                        if (f.type_annotation) |ta| try validateFieldTypeAnnotation(self, fval, ta, fi, new_values, span);
                    }
                }
                final_values = new_values;
            }
            result = Value{ .struct_val = .{ .keys = s.keys, .values = final_values, .type_name = type_name } };
        },
        .function => |f| result = Value{ .function = .{ .params = f.params, .return_type = f.return_type, .body_bindings = f.body_bindings, .body_expr = f.body_expr, .captured_keys = f.captured_keys, .captured_values = f.captured_values, .captured_types = f.captured_types, .type_name = type_name } },
        .list => |l| result = Value{ .list = .{ .elements = l.elements, .element_type = l.element_type, .type_name = type_name } },
        else => {},
    }
    return result;
}

fn validateFieldTypeAnnotation(self: *Evaluator, fval: Value, ta: []const u8, fi: usize, new_values: []Value, span: Ast.Span) EvalError!void {
    if (fval == .integer and !fval.integer.explicit) {
        if (h.parseIntegerTypeName(ta)) |it| {
            if (!h.intFitsType(fval.integer.value, it))
                return self.rtErr("struct field value out of range for named type", span.line, span.col);
            new_values[fi] = Value{ .integer = .{ .value = fval.integer.value, .type_ann = it, .explicit = true } };
        }
    } else if (fval == .float_val and !fval.float_val.explicit) {
        if (h.parseFloatTypeName(ta)) |ft|
            new_values[fi] = Value{ .float_val = .{ .value = fval.float_val.value, .type_ann = ft, .explicit = true } };
    } else if (fval == .integer and fval.integer.explicit) {
        if (h.intTypeNameAlloc(self.allocator, fval.integer.type_ann)) |ftn|
            if (!std.mem.eql(u8, ftn, ta))
                return self.typeErr("struct field numeric type does not match named type definition", span.line, span.col);
    } else if (fval == .float_val and fval.float_val.explicit) {
        if (h.floatTypeName(fval.float_val.type_ann)) |ftn|
            if (!std.mem.eql(u8, ftn, ta))
                return self.typeErr("struct field numeric type does not match named type definition", span.line, span.col);
    }
}

// ── Type conversion (`to`) ───────────────────────────────────

pub fn evalConversion(self: *Evaluator, expr_node: *const Ast.Node, type_expr: *const Ast.TypeExpr, scope: *Scope, exclude: ?[]const u8, span: Ast.Span) EvalError!Value {
    const value = try self.evalNode(expr_node, scope, exclude);

    const type_name = switch (type_expr.data) {
        .name => |n| n,
        .path => |segments| resolvePathTypeName(self, segments, type_expr.*, scope) orelse
            return self.typeErr("unknown type in conversion", span.line, span.col),
        else => return self.typeErr("complex type conversions not yet supported", span.line, span.col),
    };

    if (value.isUndefined()) return .undefined;

    if (std.mem.eql(u8, type_name, "bool"))
        return if (value == .bool_val) value else self.typeErr("cannot convert to bool", span.line, span.col);
    if (std.mem.eql(u8, type_name, "null"))
        return if (value == .null_val) value else self.typeErr("cannot convert to null", span.line, span.col);

    if (h.parseIntegerTypeName(type_name)) |it| return convertToInteger(self, value, it, span);
    if (h.parseFloatTypeName(type_name)) |ft| return convertToFloat(self, value, ft, span);
    if (std.mem.eql(u8, type_name, "string")) return convertToString(self, value, span);

    // Named enum: string → enum
    if (scope.getType(type_name)) |td| {
        return switch (td.kind) {
            .enum_type => |et| switch (value) {
                .string => |s| blk: {
                    for (et.variants) |v| if (std.mem.eql(u8, s, v))
                        break :blk Value{ .enum_val = .{ .value = s, .variants = et.variants, .type_name = type_name } };
                    return self.rtErr("string does not match any enum variant", span.line, span.col);
                },
                else => self.typeErr("cannot convert to enum type", span.line, span.col),
            },
            else => self.typeErr("cannot convert to this named type", span.line, span.col),
        };
    }
    return self.typeErr("unknown conversion target type", span.line, span.col);
}

fn convertToInteger(self: *Evaluator, value: Value, int_type: val.IntegerType, span: Ast.Span) EvalError!Value {
    const result: i128 = switch (value) {
        .integer => |iv| iv.value,
        .float_val => |fv| blk: {
            if (std.math.isNan(fv.value) or std.math.isInf(fv.value))
                return self.rtErr("cannot convert inf/nan to integer", span.line, span.col);
            const max_i128: f64 = @floatFromInt(@as(i128, std.math.maxInt(i128)));
            const min_i128: f64 = @floatFromInt(@as(i128, std.math.minInt(i128)));
            if (fv.value > max_i128 or fv.value < min_i128)
                return self.rtErr("float value out of range for integer conversion", span.line, span.col);
            break :blk @intFromFloat(fv.value);
        },
        .string => |s| h.parseIntegerText(self.allocator, s) catch return self.rtErr("string is not a valid integer", span.line, span.col),
        .union_val, .tagged_union => return self.typeErr("union can only convert to string", span.line, span.col),
        .struct_val, .tuple, .list, .function => return self.typeErr("cannot convert compound type to integer", span.line, span.col),
        else => return self.typeErr("cannot convert to integer", span.line, span.col),
    };
    if (!h.intFitsType(result, int_type))
        return self.rtErr("value out of range for target integer type", span.line, span.col);
    return Value{ .integer = .{ .value = result, .type_ann = int_type, .explicit = true } };
}

fn convertToFloat(self: *Evaluator, value: Value, float_type: val.FloatType, span: Ast.Span) EvalError!Value {
    const result: f64 = switch (value) {
        .integer => |iv| @floatFromInt(iv.value),
        .float_val => |fv| fv.value,
        .string => |s| h.parseFloatText(self.allocator, s) catch return self.rtErr("string is not a valid float", span.line, span.col),
        .union_val, .tagged_union => return self.typeErr("union can only convert to string", span.line, span.col),
        .struct_val, .tuple, .list, .function => return self.typeErr("cannot convert compound type to float", span.line, span.col),
        else => return self.typeErr("cannot convert to float", span.line, span.col),
    };
    if (!std.math.isNan(result) and !std.math.isInf(result)) {
        switch (float_type) {
            .f16 => if (result != 0.0 and @abs(result) > 65504.0)
                return self.rtErr("value out of range for f16", span.line, span.col),
            .f32 => if (result != 0.0 and @abs(result) > 3.4028235e+38)
                return self.rtErr("value out of range for f32", span.line, span.col),
            else => {},
        }
    }
    return Value{ .float_val = .{ .value = result, .type_ann = float_type, .explicit = true } };
}

fn convertToString(self: *Evaluator, value: Value, span: Ast.Span) EvalError!Value {
    return switch (value) {
        .string => value,
        .bool_val => |b| Value.str(if (b) "true" else "false"),
        .null_val => Value.str("null"),
        .integer => |i| blk: {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i.value}) catch return error.OutOfMemory;
            break :blk Value.str(try self.allocator.dupe(u8, s));
        },
        .float_val => |f| Value.str(try h.formatFloat(self.allocator, f.value)),
        .enum_val => |e| Value.str(e.value),
        .union_val => |u| convertToString(self, u.value.*, span),
        .tagged_union => |tu| convertToString(self, tu.value.*, span),
        .struct_val, .tuple, .list => self.typeErrSug("cannot convert compound type to string", "use string interpolation instead", span.line, span.col),
        .function => self.typeErr("cannot convert function to string", span.line, span.col),
        .undefined => .undefined,
    };
}

// ── Type expression → string ────────────────────────────────

pub fn typeExprToString(self: *Evaluator, te: Ast.TypeExpr) !?[]const u8 {
    return switch (te.data) {
        .name => |n| n,
        .null_type => "null",
        .path => |segments| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            for (segments, 0..) |seg, i| {
                if (i > 0) try buf.append(self.allocator, '.');
                try buf.appendSlice(self.allocator, seg);
            }
            break :blk try buf.toOwnedSlice(self.allocator);
        },
        .list => |inner| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.append(self.allocator, '[');
            if (try typeExprToString(self, inner.*)) |inner_str| try buf.appendSlice(self.allocator, inner_str);
            try buf.append(self.allocator, ']');
            break :blk try buf.toOwnedSlice(self.allocator);
        },
        .tuple => |elems| blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            try buf.append(self.allocator, '(');
            for (elems, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                if (try typeExprToString(self, elem)) |es| try buf.appendSlice(self.allocator, es);
            }
            if (elems.len == 1) try buf.append(self.allocator, ',');
            try buf.append(self.allocator, ')');
            break :blk try buf.toOwnedSlice(self.allocator);
        },
    };
}

/// Build a TypeDef from a value and its `called` name.
pub fn buildTypeDef(self: *Evaluator, name: []const u8, value: Value) ?val.TypeDef {
    return switch (value) {
        .enum_val => |e| val.TypeDef{ .name = name, .kind = .{ .enum_type = .{ .variants = e.variants } } },
        .union_val => |u| val.TypeDef{ .name = name, .kind = .{ .union_type = .{ .types = u.types } } },
        .tagged_union => |tu| val.TypeDef{ .name = name, .kind = .{ .tagged_union_type = .{ .variants = tu.variants } } },
        .struct_val => |s| blk: {
            const fields = self.allocator.alloc(val.TypeDef.FieldInfo, s.keys.len) catch break :blk val.TypeDef{ .name = name, .kind = .{ .struct_type = .{ .fields = &.{} } } };
            for (s.keys, s.values, 0..) |key, fv, fi| {
                fields[fi] = .{
                    .name = key,
                    .type_category = fv.typeName(),
                    .type_annotation = switch (fv) {
                        .integer => |iv| if (iv.explicit) h.intTypeNameAlloc(self.allocator, iv.type_ann) else null,
                        .float_val => |fvv| if (fvv.explicit) h.floatTypeName(fvv.type_ann) else null,
                        else => null,
                    },
                };
            }
            break :blk val.TypeDef{ .name = name, .kind = .{ .struct_type = .{ .fields = fields } } };
        },
        .list => |l| val.TypeDef{ .name = name, .kind = .{ .list_type = .{ .element_type = l.element_type } } },
        .function => |f| blk: {
            const ptypes = self.allocator.alloc([]const u8, f.params.len) catch break :blk val.TypeDef{ .name = name, .kind = .{ .function_type = .{ .param_types = &.{}, .return_type = "unknown" } } };
            for (f.params, 0..) |p, pi| {
                ptypes[pi] = switch (p.type_expr.data) {
                    .name => |n| n,
                    else => "unknown",
                };
            }
            const rtype: []const u8 = switch (f.return_type.data) {
                .name => |n| n,
                else => "unknown",
            };
            break :blk val.TypeDef{ .name = name, .kind = .{ .function_type = .{ .param_types = ptypes, .return_type = rtype } } };
        },
        else => null,
    };
}
