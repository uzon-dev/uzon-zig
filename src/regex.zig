// Minimal anchored regex engine for §5.16.7 std.matches.
//
// Supports: literal chars, `.`, `*`, `+`, `?`, `{n}` / `{n,m}` quantifiers
// (greedy), `|` alternation, `(...)` grouping, `[...]` and `[^...]` char
// classes, and backslash escapes. No backreferences, no lookarounds.
const std = @import("std");
const val = @import("Value.zig");
const Value = val.Value;

pub const Error = error{ OutOfMemory, MalformedPattern, UnsupportedFeature };

const Node = union(enum) {
    literal: u21,
    any,
    char_class: struct { negate: bool, ranges: []const Range },
    concat: []const Node,
    alt: []const Node,
    star: *const Node,
    plus: *const Node,
    opt: *const Node,
    exact: struct { inner: *const Node, n: u32 },
    between: struct { inner: *const Node, min: u32, max: u32 },
};

const Range = struct { lo: u21, hi: u21 };

const Parser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    fn advance(p: *Parser) void {
        p.pos += 1;
    }

    fn parseAlt(p: *Parser) Error!Node {
        var branches = std.ArrayListUnmanaged(Node){};
        try branches.append(p.alloc, try p.parseConcat());
        while (p.peek() == @as(u8, '|')) {
            p.advance();
            try branches.append(p.alloc, try p.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return Node{ .alt = try branches.toOwnedSlice(p.alloc) };
    }

    fn parseConcat(p: *Parser) Error!Node {
        var parts = std.ArrayListUnmanaged(Node){};
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(p.alloc, try p.parseAtomQuantified());
        }
        if (parts.items.len == 0) return Node{ .concat = &.{} };
        if (parts.items.len == 1) return parts.items[0];
        return Node{ .concat = try parts.toOwnedSlice(p.alloc) };
    }

    fn parseAtomQuantified(p: *Parser) Error!Node {
        const atom = try p.parseAtom();
        const q = p.peek() orelse return atom;
        const result: Node = switch (q) {
            '*' => blk: {
                p.advance();
                const boxed = try p.alloc.create(Node);
                boxed.* = atom;
                break :blk Node{ .star = boxed };
            },
            '+' => blk: {
                p.advance();
                const boxed = try p.alloc.create(Node);
                boxed.* = atom;
                break :blk Node{ .plus = boxed };
            },
            '?' => blk: {
                p.advance();
                const boxed = try p.alloc.create(Node);
                boxed.* = atom;
                break :blk Node{ .opt = boxed };
            },
            '{' => blk: {
                p.advance();
                const n = try p.parseNumber();
                if (p.peek() == @as(u8, ',')) {
                    p.advance();
                    const m: u32 = if (p.peek() == @as(u8, '}')) std.math.maxInt(u32) else try p.parseNumber();
                    if (p.peek() != @as(u8, '}')) return error.MalformedPattern;
                    p.advance();
                    const boxed = try p.alloc.create(Node);
                    boxed.* = atom;
                    break :blk Node{ .between = .{ .inner = boxed, .min = n, .max = m } };
                }
                if (p.peek() != @as(u8, '}')) return error.MalformedPattern;
                p.advance();
                const boxed = try p.alloc.create(Node);
                boxed.* = atom;
                break :blk Node{ .exact = .{ .inner = boxed, .n = n } };
            },
            else => return atom,
        };
        // §5.16.7: non-greedy marker `?` after a quantifier. Because
        // std.matches is fully anchored, greedy and non-greedy admit the
        // same accept/reject decisions — consume and ignore.
        if (p.peek() == @as(u8, '?')) p.advance();
        return result;
    }

    fn parseNumber(p: *Parser) Error!u32 {
        var n: u32 = 0;
        var any: bool = false;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = n * 10 + (c - '0');
            any = true;
            p.advance();
        }
        if (!any) return error.MalformedPattern;
        return n;
    }

    fn parseAtom(p: *Parser) Error!Node {
        const c = p.peek() orelse return error.MalformedPattern;
        switch (c) {
            '.' => {
                p.advance();
                return Node.any;
            },
            '(' => {
                p.advance();
                // §5.16.7: accept non-capturing groups `(?:...)`. We don't
                // track capture groups, so the prefix is ignored.
                if (p.peek() == @as(u8, '?') and p.pos + 1 < p.src.len and p.src[p.pos + 1] == ':') {
                    p.advance();
                    p.advance();
                }
                const inner = try p.parseAlt();
                if (p.peek() != @as(u8, ')')) return error.MalformedPattern;
                p.advance();
                return inner;
            },
            '[' => return p.parseCharClass(),
            '\\' => return p.parseEscape(),
            // §5.16.7: std.matches is anchored on both ends, so `^` at start
            // and `$` at end are redundant but accepted. Treat as an empty
            // concat so subsequent atoms continue from the same position.
            '^', '$' => {
                p.advance();
                return Node{ .concat = &.{} };
            },
            '*', '+', '?', '{', '}', ')', '|' => return error.MalformedPattern,
            else => return p.parseLiteralCodepoint(),
        }
    }

    fn parseLiteralCodepoint(p: *Parser) Error!Node {
        const cp = try p.decodeCodepoint();
        return Node{ .literal = cp };
    }

    fn decodeCodepoint(p: *Parser) Error!u21 {
        const rest = p.src[p.pos..];
        if (rest.len == 0) return error.MalformedPattern;
        const clen = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.MalformedPattern;
        if (clen > rest.len) return error.MalformedPattern;
        const cp = std.unicode.utf8Decode(rest[0..clen]) catch return error.MalformedPattern;
        p.pos += clen;
        return cp;
    }

    fn parseEscape(p: *Parser) Error!Node {
        p.advance(); // consume backslash
        const c = p.peek() orelse return error.MalformedPattern;
        switch (c) {
            'n' => {
                p.advance();
                return Node{ .literal = '\n' };
            },
            't' => {
                p.advance();
                return Node{ .literal = '\t' };
            },
            'r' => {
                p.advance();
                return Node{ .literal = '\r' };
            },
            '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '\\' => {
                p.advance();
                return Node{ .literal = @intCast(c) };
            },
            'd' => {
                p.advance();
                const ranges = try p.alloc.alloc(Range, 1);
                ranges[0] = .{ .lo = '0', .hi = '9' };
                return Node{ .char_class = .{ .negate = false, .ranges = ranges } };
            },
            'D' => {
                p.advance();
                const ranges = try p.alloc.alloc(Range, 1);
                ranges[0] = .{ .lo = '0', .hi = '9' };
                return Node{ .char_class = .{ .negate = true, .ranges = ranges } };
            },
            'w' => {
                p.advance();
                const ranges = try p.alloc.alloc(Range, 4);
                ranges[0] = .{ .lo = 'a', .hi = 'z' };
                ranges[1] = .{ .lo = 'A', .hi = 'Z' };
                ranges[2] = .{ .lo = '0', .hi = '9' };
                ranges[3] = .{ .lo = '_', .hi = '_' };
                return Node{ .char_class = .{ .negate = false, .ranges = ranges } };
            },
            's' => {
                p.advance();
                const ranges = try p.alloc.alloc(Range, 4);
                ranges[0] = .{ .lo = ' ', .hi = ' ' };
                ranges[1] = .{ .lo = '\t', .hi = '\t' };
                ranges[2] = .{ .lo = '\n', .hi = '\n' };
                ranges[3] = .{ .lo = '\r', .hi = '\r' };
                return Node{ .char_class = .{ .negate = false, .ranges = ranges } };
            },
            else => return error.MalformedPattern,
        }
    }

    fn parseCharClass(p: *Parser) Error!Node {
        p.advance(); // [
        var negate = false;
        if (p.peek() == @as(u8, '^')) {
            negate = true;
            p.advance();
        }
        var ranges = std.ArrayListUnmanaged(Range){};
        while (p.peek()) |c| {
            if (c == ']') {
                p.advance();
                if (ranges.items.len == 0) return error.MalformedPattern;
                return Node{ .char_class = .{ .negate = negate, .ranges = try ranges.toOwnedSlice(p.alloc) } };
            }
            const lo = try p.decodeClassChar();
            var hi = lo;
            if (p.peek() == @as(u8, '-') and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.advance();
                hi = try p.decodeClassChar();
            }
            try ranges.append(p.alloc, .{ .lo = lo, .hi = hi });
        }
        return error.MalformedPattern;
    }

    fn decodeClassChar(p: *Parser) Error!u21 {
        if (p.peek() == @as(u8, '\\')) {
            p.advance();
            const c = p.peek() orelse return error.MalformedPattern;
            p.advance();
            return switch (c) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => @as(u21, @intCast(c)),
            };
        }
        return p.decodeCodepoint();
    }
};

fn matchNode(node: Node, text: []const u8, pos: usize, rest: []const Node) bool {
    switch (node) {
        .literal => |cp| {
            const r = decodeAt(text, pos) orelse return false;
            if (r.cp != cp) return false;
            return matchConcat(rest, text, pos + r.len);
        },
        .any => {
            const r = decodeAt(text, pos) orelse return false;
            return matchConcat(rest, text, pos + r.len);
        },
        .char_class => |cc| {
            const r = decodeAt(text, pos) orelse return false;
            var hit = false;
            for (cc.ranges) |rg| {
                if (r.cp >= rg.lo and r.cp <= rg.hi) {
                    hit = true;
                    break;
                }
            }
            if (hit == cc.negate) return false;
            return matchConcat(rest, text, pos + r.len);
        },
        .concat => |parts| {
            // Build a chained rest.
            if (parts.len == 0) return matchConcat(rest, text, pos);
            var merged = std.heap.page_allocator.alloc(Node, parts.len - 1 + rest.len) catch return false;
            defer std.heap.page_allocator.free(merged);
            @memcpy(merged[0 .. parts.len - 1], parts[1..]);
            @memcpy(merged[parts.len - 1 ..], rest);
            return matchNode(parts[0], text, pos, merged);
        },
        .alt => |branches| {
            for (branches) |b| {
                if (matchNode(b, text, pos, rest)) return true;
            }
            return false;
        },
        .star => |inner| return matchGreedy(inner.*, text, pos, rest, 0, std.math.maxInt(u32)),
        .plus => |inner| return matchGreedy(inner.*, text, pos, rest, 1, std.math.maxInt(u32)),
        .opt => |inner| return matchGreedy(inner.*, text, pos, rest, 0, 1),
        .exact => |e| return matchGreedy(e.inner.*, text, pos, rest, e.n, e.n),
        .between => |b| return matchGreedy(b.inner.*, text, pos, rest, b.min, b.max),
    }
}

fn matchConcat(parts: []const Node, text: []const u8, pos: usize) bool {
    if (parts.len == 0) return pos == text.len;
    return matchNode(parts[0], text, pos, parts[1..]);
}

fn matchGreedy(inner: Node, text: []const u8, pos: usize, rest: []const Node, min: u32, max: u32) bool {
    // Collect greedy positions.
    var positions = std.ArrayListUnmanaged(usize){};
    defer positions.deinit(std.heap.page_allocator);
    positions.append(std.heap.page_allocator, pos) catch return false;
    var cur = pos;
    var count: u32 = 0;
    while (count < max) {
        const next = matchOnce(inner, text, cur) orelse break;
        if (next == cur) break;
        cur = next;
        count += 1;
        positions.append(std.heap.page_allocator, cur) catch return false;
    }
    // Try from longest to shortest, but not below min.
    var i: usize = positions.items.len;
    while (i > 0) {
        i -= 1;
        const took: u32 = @intCast(i);
        if (took < min) break;
        if (matchConcat(rest, text, positions.items[i])) return true;
    }
    return false;
}

fn matchOnce(node: Node, text: []const u8, pos: usize) ?usize {
    // Try to match `node` exactly once at pos. Returns end pos or null.
    switch (node) {
        .literal => |cp| {
            const r = decodeAt(text, pos) orelse return null;
            if (r.cp != cp) return null;
            return pos + r.len;
        },
        .any => {
            const r = decodeAt(text, pos) orelse return null;
            return pos + r.len;
        },
        .char_class => |cc| {
            const r = decodeAt(text, pos) orelse return null;
            var hit = false;
            for (cc.ranges) |rg| {
                if (r.cp >= rg.lo and r.cp <= rg.hi) {
                    hit = true;
                    break;
                }
            }
            if (hit == cc.negate) return null;
            return pos + r.len;
        },
        .concat => |parts| {
            var p = pos;
            for (parts) |part| {
                const np = matchOnce(part, text, p) orelse return null;
                p = np;
            }
            return p;
        },
        .alt => |branches| {
            for (branches) |b| if (matchOnce(b, text, pos)) |np| return np;
            return null;
        },
        .star, .plus, .opt, .exact, .between => {
            // Nested quantifiers: use backtracking via matchNode with empty rest.
            // Find the longest position such that matchConcat(&.{}, text, end) = (end == text.len).
            // But we need just "one match that extends as far as possible". Use matchGreedy.
            const empty_rest: []const Node = &.{};
            // We need to report a single matching endpoint. Try lengths from longest.
            // Simpler: iterate all possible ends by running matchGreedy on pos and using success.
            _ = empty_rest;
            // Fallback: try all endpoints
            var end: usize = text.len;
            while (end >= pos) : (end -= 1) {
                // Build sub-text view and try to match exactly.
                if (matchExactRange(node, text, pos, end)) return end;
                if (end == 0) break;
            }
            return null;
        },
    }
}

fn matchExactRange(node: Node, text: []const u8, start: usize, end: usize) bool {
    // Try to match `node` against text[start..end] exactly.
    // Simplification: use matchNode with a sentinel rest that requires pos == end.
    return matchNode(node, text[0..end], start, &.{});
}

const DecodeResult = struct { cp: u21, len: usize };

fn decodeAt(text: []const u8, pos: usize) ?DecodeResult {
    if (pos >= text.len) return null;
    const clen = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + clen > text.len) return null;
    const cp = std.unicode.utf8Decode(text[pos .. pos + clen]) catch return null;
    return .{ .cp = cp, .len = clen };
}

pub fn matchAnchored(alloc: std.mem.Allocator, pattern: []const u8, input: []const u8) Error!Value {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var parser = Parser{ .src = pattern, .pos = 0, .alloc = arena.allocator() };
    const root = try parser.parseAlt();
    if (parser.pos != pattern.len) return error.MalformedPattern;
    const ok = matchConcat(&[_]Node{root}, input, 0);
    return Value.boolean(ok);
}
