const std = @import("std");
const Ast = @import("Ast.zig");
const Scope = @import("Scope.zig");

/// Compute topological evaluation order for bindings (Kahn's algorithm).
/// Returns indices into `bindings` in evaluation order.
/// Returns error.UzonCircular if a cycle is detected (§11.2).
/// On cycle, `cycle_indices` is populated with all binding indices participating in cycles.
pub fn topologicalSort(
    allocator: std.mem.Allocator,
    bindings: []const Ast.Binding,
    scope: *const Scope,
    cycle_indices: *std.ArrayListUnmanaged(usize),
) ![]usize {
    const n = bindings.len;
    if (n == 0) return &.{};

    var name_to_idx = std.StringHashMapUnmanaged(usize){};
    var called_to_idx = std.StringHashMapUnmanaged(usize){};

    for (bindings, 0..) |b, i| {
        try name_to_idx.put(allocator, b.name, i);
        if (b.called) |c| try called_to_idx.put(allocator, c, i);
    }

    var in_degree = try allocator.alloc(usize, n);
    @memset(in_degree, 0);
    var dependents = try allocator.alloc(std.ArrayListUnmanaged(usize), n);
    for (dependents) |*d| d.* = .{};

    for (bindings, 0..) |b, i| {
        var deps = std.AutoHashMapUnmanaged(usize, void){};
        collectBindingDeps(allocator, b.value, &name_to_idx, &deps);
        collectTypeAnnotationDeps(allocator, b.value, &called_to_idx, &deps);
        if (b.list_type_annotation) |lta| collectTypeExprDeps(allocator, &lta, &called_to_idx, &deps);
        _ = deps.remove(i); // self-exclusion
        _ = scope; // scope reserved for outer-scope filtering

        var it = deps.keyIterator();
        while (it.next()) |dep_idx| {
            try dependents[dep_idx.*].append(allocator, i);
            in_degree[i] += 1;
        }
    }

    // Kahn's algorithm
    var queue = std.ArrayListUnmanaged(usize){};
    for (0..n) |i| {
        if (in_degree[i] == 0) try queue.append(allocator, i);
    }

    var result = std.ArrayListUnmanaged(usize){};
    while (queue.items.len > 0) {
        const idx = queue.orderedRemove(0);
        try result.append(allocator, idx);
        for (dependents[idx].items) |dep| {
            in_degree[dep] -= 1;
            if (in_degree[dep] == 0) try queue.append(allocator, dep);
        }
    }

    if (result.items.len != n) {
        for (0..n) |i| {
            if (in_degree[i] > 0) try cycle_indices.append(allocator, i);
        }
    }
    return result.items;
}

/// Check that the function call graph is a DAG (no recursion, §3.8).
/// On cycle, `cycle_names` is populated with all function names participating in cycles.
pub fn checkFunctionCallDag(
    allocator: std.mem.Allocator,
    bindings: []const Ast.Binding,
    cycle_names: *std.ArrayListUnmanaged([]const u8),
) !void {
    var func_names = std.StringHashMapUnmanaged(void){};
    for (bindings) |b| {
        if (b.value.kind == .function_expr) try func_names.put(allocator, b.name, {});
    }
    if (func_names.count() == 0) return;

    var graph = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)){};
    for (bindings) |b| {
        if (b.value.kind == .function_expr) {
            var calls = std.StringHashMapUnmanaged(void){};
            collectFunctionCalls(allocator, b.value, &func_names, &calls);
            try graph.put(allocator, b.name, calls);
        }
    }

    // DFS cycle detection: 0=white, 1=gray, 2=black
    var color = std.StringHashMapUnmanaged(u8){};
    var it = func_names.keyIterator();
    while (it.next()) |name| try color.put(allocator, name.*, 0);

    it = func_names.keyIterator();
    while (it.next()) |name| {
        if ((color.get(name.*) orelse 0) == 0) {
            if (dfsCycle(name.*, &graph, &color, allocator)) {
                // Collect all gray (cycle-participating) nodes
                var color_it = color.iterator();
                while (color_it.next()) |entry| {
                    if (entry.value_ptr.* == 1) {
                        try cycle_names.append(allocator, entry.key_ptr.*);
                        entry.value_ptr.* = 2; // mark black to avoid re-reporting
                    }
                }
            }
        }
    }
}

// ── Generic AST child visitor ───────────────────────────────

/// Calls `visitor` on every child node of `node`, passing through `ctx`.
fn visitChildren(node: *const Ast.Node, ctx: anytype, visitor: anytype) void {
    switch (node.kind) {
        .identifier, .integer_literal, .float_literal, .bool_literal, .null_literal, .undefined_literal, .inf_literal, .nan_literal, .env_ref, .struct_import, .type_pattern => {},
        .binary_op => |bo| {
            visitor(bo.left, ctx);
            visitor(bo.right, ctx);
        },
        .unary_op => |uo| visitor(uo.operand, ctx),
        .or_else => |oe| {
            visitor(oe.left, ctx);
            visitor(oe.right, ctx);
        },
        .if_expr => |ie| {
            visitor(ie.condition, ctx);
            visitor(ie.then_branch, ctx);
            visitor(ie.else_branch, ctx);
        },
        .case_expr => |ce| {
            visitor(ce.scrutinee, ctx);
            for (ce.when_clauses) |wc| {
                visitor(wc.value, ctx);
                visitor(wc.result, ctx);
            }
            visitor(ce.else_branch, ctx);
        },
        .member_access => |ma| visitor(ma.object, ctx),
        .function_call => |fc| {
            visitor(fc.callee, ctx);
            for (fc.args) |arg| visitor(arg, ctx);
        },
        .type_annotation => |ta| visitor(ta.expr, ctx),
        .conversion => |cv| visitor(cv.expr, ctx),
        .struct_override => |so| {
            visitor(so.base, ctx);
            visitor(so.overrides, ctx);
        },
        .struct_extension => |se| {
            visitor(se.base, ctx);
            visitor(se.extension, ctx);
        },
        .from_enum => |fe| visitor(fe.value, ctx),
        .from_union => |fu| visitor(fu.value, ctx),
        .named_variant => |nv| visitor(nv.value, ctx),
        .struct_literal => |sl| {
            for (sl.fields) |f| visitor(f.value, ctx);
        },
        .list_literal => |ll| {
            for (ll.elements) |e| visitor(e, ctx);
        },
        .tuple_literal => |tl| {
            for (tl.elements) |e| visitor(e, ctx);
        },
        .grouping => |g| visitor(g.expr, ctx),
        .function_expr => |fe| {
            for (fe.body_bindings) |bb| visitor(bb.value, ctx);
            visitor(fe.body_expr, ctx);
        },
        .field_extraction => |fx| visitor(fx.source, ctx),
        .string_literal => |sl| {
            for (sl.parts) |part| switch (part) {
                .interpolation => |expr| visitor(expr, ctx),
                .literal => {},
            };
        },
    }
}

// ── Binding dependency collection ───────────────────────────

const BindingDepCtx = struct {
    allocator: std.mem.Allocator,
    name_to_idx: *const std.StringHashMapUnmanaged(usize),
    deps: *std.AutoHashMapUnmanaged(usize, void),
};

fn collectBindingDeps(allocator: std.mem.Allocator, node: *const Ast.Node, name_to_idx: *const std.StringHashMapUnmanaged(usize), deps: *std.AutoHashMapUnmanaged(usize, void)) void {
    const ctx = BindingDepCtx{ .allocator = allocator, .name_to_idx = name_to_idx, .deps = deps };
    bindingDepVisitor(node, ctx);
}

fn bindingDepVisitor(node: *const Ast.Node, ctx: BindingDepCtx) void {
    if (node.kind == .identifier) {
        if (ctx.name_to_idx.get(node.kind.identifier.name)) |idx| {
            ctx.deps.put(ctx.allocator, idx, {}) catch {};
        }
        return;
    }
    visitChildren(node, ctx, bindingDepVisitor);
}

// ── Type annotation dependency collection ───────────────────

const TypeDepCtx = struct {
    allocator: std.mem.Allocator,
    called_to_idx: *const std.StringHashMapUnmanaged(usize),
    deps: *std.AutoHashMapUnmanaged(usize, void),
};

fn collectTypeAnnotationDeps(allocator: std.mem.Allocator, node: *const Ast.Node, called_to_idx: *const std.StringHashMapUnmanaged(usize), deps: *std.AutoHashMapUnmanaged(usize, void)) void {
    const ctx = TypeDepCtx{ .allocator = allocator, .called_to_idx = called_to_idx, .deps = deps };
    typeDepVisitor(node, ctx);
}

fn typeDepVisitor(node: *const Ast.Node, ctx: TypeDepCtx) void {
    switch (node.kind) {
        .type_annotation => |ta| {
            collectTypeExprDeps(ctx.allocator, &ta.type_expr, ctx.called_to_idx, ctx.deps);
            typeDepVisitor(ta.expr, ctx);
        },
        .conversion => |cv| {
            collectTypeExprDeps(ctx.allocator, &cv.type_expr, ctx.called_to_idx, ctx.deps);
            typeDepVisitor(cv.expr, ctx);
        },
        else => visitChildren(node, ctx, typeDepVisitor),
    }
}

fn collectTypeExprDeps(allocator: std.mem.Allocator, te: *const Ast.TypeExpr, called_to_idx: *const std.StringHashMapUnmanaged(usize), deps: *std.AutoHashMapUnmanaged(usize, void)) void {
    switch (te.data) {
        .name => |n| {
            if (called_to_idx.get(n)) |idx| deps.put(allocator, idx, {}) catch {};
        },
        .path => |p| {
            if (p.len > 0) {
                if (called_to_idx.get(p[0])) |idx| deps.put(allocator, idx, {}) catch {};
            }
        },
        .list => |inner| collectTypeExprDeps(allocator, inner, called_to_idx, deps),
        .tuple => |types| {
            for (types) |*t| collectTypeExprDeps(allocator, t, called_to_idx, deps);
        },
        .null_type => {},
    }
}

// ── Function call collection ────────────────────────────────

const FnCallCtx = struct {
    allocator: std.mem.Allocator,
    func_names: *const std.StringHashMapUnmanaged(void),
    calls: *std.StringHashMapUnmanaged(void),
};

fn collectFunctionCalls(allocator: std.mem.Allocator, node: *const Ast.Node, func_names: *const std.StringHashMapUnmanaged(void), calls: *std.StringHashMapUnmanaged(void)) void {
    const ctx = FnCallCtx{ .allocator = allocator, .func_names = func_names, .calls = calls };
    fnCallVisitor(node, ctx);
}

fn fnCallVisitor(node: *const Ast.Node, ctx: FnCallCtx) void {
    if (node.kind == .function_call) {
        const fc = node.kind.function_call;
        if (fc.callee.kind == .identifier) {
            const name = fc.callee.kind.identifier.name;
            if (ctx.func_names.contains(name)) ctx.calls.put(ctx.allocator, name, {}) catch {};
        }
    }
    visitChildren(node, ctx, fnCallVisitor);
}

// ── DFS cycle detection ─────────────────────────────────────

fn dfsCycle(
    node: []const u8,
    graph: *const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
    color: *std.StringHashMapUnmanaged(u8),
    allocator: std.mem.Allocator,
) bool {
    color.put(allocator, node, 1) catch return false;
    if (graph.get(node)) |neighbors| {
        var it = neighbors.keyIterator();
        while (it.next()) |neighbor| {
            const c = color.get(neighbor.*) orelse 0;
            if (c == 1) return true;
            if (c == 0 and dfsCycle(neighbor.*, graph, color, allocator)) return true;
        }
    }
    color.put(allocator, node, 2) catch return false;
    return false;
}
