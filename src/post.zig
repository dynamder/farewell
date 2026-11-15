//! Post-processing: effects run on every cell, and once on the finished grid.

const std = @import("std");
const types = @import("types.zig");

const Cell = types.Cell;

/// True when `E` (or what it points at) declares `cell(self, c, x, y) Cell`.
pub fn hasCell(comptime E: type) bool {
    return @hasDecl(target(E), "cell");
}

/// True when `E` (or what it points at) declares `grid(self, g, shown) void`.
pub fn hasGrid(comptime E: type) bool {
    return @hasDecl(target(E), "grid");
}

/// True when the effect list is empty, which lets the render path skip the
/// wrapper entirely.
pub fn isEmpty(comptime Effects: type) bool {
    return @typeInfo(Effects).@"struct".field_types.len == 0;
}

/// Rejects, at compile time, an effect that is not a pointer or declares
/// neither method: a typo must not turn into a stage that silently does nothing.
pub fn check(comptime Effects: type) void {
    inline for (@typeInfo(Effects).@"struct".field_types) |E| {
        if (@typeInfo(E) != .pointer)
            @compileError("post effects go in by pointer: .{ &effect }");
        if (!hasCell(E) and !hasGrid(E))
            @compileError(@typeName(target(E)) ++ " declares neither cell() nor grid()");
    }
}

fn target(comptime E: type) type {
    return switch (@typeInfo(E)) {
        .pointer => |p| p.child,
        else => E,
    };
}

/// Wraps a sink so every cell passes through the effects that declare `cell`,
/// in list order, before reaching `inner`.
pub fn Sink(comptime Inner: type, comptime Effects: type) type {
    return struct {
        /// Must be a pointer type: `*Grid`, or a host's own cell container.
        inner: Inner,
        effects: Effects,

        pub fn size(self: @This()) types.Size {
            return self.inner.size();
        }

        pub fn put(self: *@This(), x: u16, y: u16, c: Cell) void {
            var out = c;
            inline for (self.effects) |e| {
                if (comptime hasCell(@TypeOf(e))) out = e.cell(out, x, y);
            }
            self.inner.put(x, y, out);
        }
    };
}

const Recorder = struct {
    w: u16,
    h: u16,
    seen: [4]Cell = @splat(.{}),

    pub fn size(self: Recorder) types.Size {
        return .{ .cols = self.w, .rows = self.h };
    }

    pub fn put(self: *Recorder, x: u16, y: u16, c: Cell) void {
        self.seen[@as(usize, y) * self.w + x] = c;
    }
};

const Shift = struct {
    by: u8,
    pub fn cell(self: *Shift, c: Cell, _: u16, _: u16) Cell {
        var out = c;
        out.fg.r +%= self.by;
        return out;
    }
};

const Counter = struct {
    calls: usize = 0,
    pub fn cell(self: *Counter, c: Cell, _: u16, _: u16) Cell {
        self.calls += 1;
        return c;
    }
};

test "effects reach the inner sink in list order" {
    var inner = Recorder{ .w = 2, .h = 1 };
    var first = Shift{ .by = 10 };
    var second = Shift{ .by = 1 };
    var sink = Sink(*Recorder, @TypeOf(.{ &first, &second })){ .inner = &inner, .effects = .{ &first, &second } };

    sink.put(0, 0, .{ .cp = 'a', .fg = .{ .r = 5, .g = 0, .b = 0 } });

    try std.testing.expectEqual(@as(u8, 16), inner.seen[0].fg.r);
    try std.testing.expectEqual(@as(u21, 'a'), inner.seen[0].cp);
}

test "an empty effect list forwards the cell untouched" {
    var inner = Recorder{ .w = 1, .h = 1 };
    const Effects = @TypeOf(.{});
    var sink = Sink(*Recorder, Effects){ .inner = &inner, .effects = .{} };

    sink.put(0, 0, .{ .cp = 'z', .fg = .{ .r = 7, .g = 8, .b = 9 } });

    try std.testing.expectEqual(@as(u8, 7), inner.seen[0].fg.r);
    try std.testing.expectEqual(@as(u21, 'z'), inner.seen[0].cp);
}

test "only the effects that declare cell run" {
    var inner = Recorder{ .w = 1, .h = 1 };
    var counter = Counter{};
    const Whole = struct {
        pub fn grid(_: *@This(), _: *types.Grid, _: *const types.Grid) void {}
    };
    var whole = Whole{};
    var sink = Sink(*Recorder, @TypeOf(.{ &counter, &whole })){ .inner = &inner, .effects = .{ &counter, &whole } };

    sink.put(0, 0, .{});
    _ = sink.size();

    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expect(hasGrid(Whole));
    try std.testing.expect(!hasCell(Whole));
}

test "the effect list is classified by declaration" {
    try std.testing.expect(hasCell(*Shift));
    try std.testing.expect(!hasGrid(*Shift));
    try std.testing.expect(isEmpty(@TypeOf(.{})));
    try std.testing.expect(!isEmpty(@TypeOf(.{&Counter{}})));
}
