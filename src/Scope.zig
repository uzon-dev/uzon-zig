const std = @import("std");
const val = @import("Value.zig");
const Value = val.Value;
const TypeDef = val.TypeDef;

const Scope = @This();

bindings: std.StringHashMapUnmanaged(*const Value),
types: std.StringHashMapUnmanaged(*const TypeDef),
parent: ?*const Scope,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Scope {
    return .{
        .bindings = .{},
        .types = .{},
        .parent = null,
        .allocator = allocator,
    };
}

pub fn withParent(allocator: std.mem.Allocator, parent: *const Scope) Scope {
    return .{
        .bindings = .{},
        .types = .{},
        .parent = parent,
        .allocator = allocator,
    };
}

/// Define a binding in the current scope.
pub fn define(self: *Scope, name: []const u8, value: Value) !void {
    const v = try self.allocator.create(Value);
    v.* = value;
    try self.bindings.put(self.allocator, name, v);
}

/// Look up a binding, walking the scope chain.
/// `exclude` implements self-exclusion (§5.12): the binding being defined
/// cannot reference itself in the innermost scope.
pub fn get(self: *const Scope, name: []const u8, exclude: ?[]const u8) ?*const Value {
    if (exclude) |exc| {
        if (!std.mem.eql(u8, name, exc)) {
            if (self.bindings.get(name)) |v| return v;
        }
    } else {
        if (self.bindings.get(name)) |v| return v;
    }
    if (self.parent) |p| return p.get(name, null);
    return null;
}

/// Register a type definition.
pub fn defineType(self: *Scope, name: []const u8, typedef: TypeDef) !void {
    const td = try self.allocator.create(TypeDef);
    td.* = typedef;
    try self.types.put(self.allocator, name, td);
}

/// Look up a type definition, walking the scope chain.
pub fn getType(self: *const Scope, name: []const u8) ?*const TypeDef {
    if (self.types.get(name)) |td| return td;
    if (self.parent) |p| return p.getType(name);
    return null;
}
