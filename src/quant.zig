//! Colour quantisation: palettes and nearest-colour lookup.

const std = @import("std");
const types = @import("types.zig");

const RGB = types.RGB;

/// A colour table to snap colours to.
pub const Palette = union(enum) {
    /// The xterm 256-colour table. Only slots 16..255 are ever returned: 0..15
    /// are theme colours, and a terminal is free to remap them.
    xterm256,
    /// A caller-supplied table; every slot is a candidate.
    fixed: []const RGB,
};

/// The nearest slot in `p` to `c`.
pub fn nearest(p: Palette, c: RGB) u8 {
    return switch (p) {
        .xterm256 => nearestXterm(c),
        .fixed => |table| nearestFixed(table, c),
    };
}

/// The colour held by slot `idx`.
pub fn rgb(p: Palette, idx: u8) RGB {
    return switch (p) {
        .xterm256 => xtermRgb(idx),
        .fixed => |table| table[idx],
    };
}

/// Snaps every cell colour to a table. Declares `cell`, so it runs while cells
/// are produced and costs no extra pass over the grid.
pub const Fixed = struct {
    table: Palette,

    pub fn cell(self: *const Fixed, c: types.Cell, _: u16, _: u16) types.Cell {
        var out = c;
        out.fg = rgb(self.table, nearest(self.table, c.fg));
        out.bg = rgb(self.table, nearest(self.table, c.bg));
        return out;
    }

    /// Tells the encoder these colours are slots in `table`.
    pub fn palette(self: *const Fixed) ?Palette {
        return self.table;
    }
};

/// The six levels of the xterm colour cube.
const CUBE = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// The first grey ramp slot (232) holds 8, then 18, and so on in steps of ten.
const GREY_BASE = 8;
const GREY_STEP = 10;
const GREY_SLOTS = 24;

fn nearestXterm(c: RGB) u8 {
    const ri = cubeLevel(c.r);
    const gi = cubeLevel(c.g);
    const bi = cubeLevel(c.b);
    const cube = RGB{ .r = CUBE[ri], .g = CUBE[gi], .b = CUBE[bi] };

    const mean = (@as(u32, c.r) + c.g + c.b) / 3;
    const slot = std.math.clamp(
        @divFloor(@as(i32, @intCast(mean)) - GREY_BASE + GREY_STEP / 2, GREY_STEP),
        0,
        GREY_SLOTS - 1,
    );
    const grey_value: u8 = GREY_BASE + GREY_STEP * @as(u8, @intCast(slot));
    const grey = RGB{ .r = grey_value, .g = grey_value, .b = grey_value };

    if (distance(c, grey) <= distance(c, cube)) {
        return @as(u8, 232) + @as(u8, @intCast(slot));
    }
    return @intCast(16 + 36 * ri + 6 * gi + bi);
}

fn cubeLevel(v: u8) usize {
    if (v < 48) return 0;
    if (v < 115) return 1;
    return @min(@as(usize, 5), (@as(usize, v) - 35) / 40);
}

fn nearestFixed(table: []const RGB, c: RGB) u8 {
    var best: u8 = 0;
    var best_d: u32 = std.math.maxInt(u32);
    for (table, 0..) |candidate, i| {
        const d = distance(c, candidate);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn distance(a: RGB, b: RGB) u32 {
    const dr = @as(i32, a.r) - @as(i32, b.r);
    const dg = @as(i32, a.g) - @as(i32, b.g);
    const db = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

fn xtermRgb(idx: u8) RGB {
    if (idx < 16) {
        return .{};
    }
    if (idx < 232) {
        const i = idx - 16;
        return .{
            .r = CUBE[i / 36],
            .g = CUBE[(i / 6) % 6],
            .b = CUBE[i % 6],
        };
    }
    const v: u8 = GREY_BASE + GREY_STEP * (idx - 232);
    return .{ .r = v, .g = v, .b = v };
}

/// The smallest distance any slot in 16..255 can reach.
fn minXtermDistance(c: RGB) u32 {
    var best: u32 = std.math.maxInt(u32);
    var idx: u8 = 16;
    while (true) : (idx +%= 1) {
        best = @min(best, distance(c, xtermRgb(idx)));
        if (idx == 255) break;
    }
    return best;
}

test "spot checks land on the documented slots" {
    try std.testing.expectEqual(@as(u8, 196), nearest(.xterm256, .{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 21), nearest(.xterm256, .{ .r = 0, .g = 0, .b = 255 }));
    try std.testing.expectEqual(@as(u8, 16), nearest(.xterm256, RGB.black));
    try std.testing.expectEqual(@as(u8, 231), nearest(.xterm256, RGB.white));
    try std.testing.expectEqual(@as(u8, 244), nearest(.xterm256, .{ .r = 128, .g = 128, .b = 128 }));
}

test "the theme slots are never returned" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    for (0..2000) |_| {
        const c = RGB{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };
        try std.testing.expect(nearest(.xterm256, c) >= 16);
    }
}

test "fuzz: the analytic lookup is as near as a full scan" {
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const rand = prng.random();
    for (0..5000) |_| {
        const c = RGB{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };
        const got = distance(c, xtermRgb(nearest(.xterm256, c)));
        try std.testing.expectEqual(minXtermDistance(c), got);
    }
}

test "edge colours land on their own slot" {
    try std.testing.expectEqual(@as(u8, 16), nearest(.xterm256, .{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 231), nearest(.xterm256, .{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(@as(u8, 232), nearest(.xterm256, .{ .r = 8, .g = 8, .b = 8 }));
    try std.testing.expectEqual(@as(u8, 255), nearest(.xterm256, .{ .r = 238, .g = 238, .b = 238 }));
}

test "every cube and grey slot maps back to itself" {
    var idx: u8 = 16;
    while (true) : (idx +%= 1) {
        try std.testing.expectEqual(idx, nearest(.xterm256, xtermRgb(idx)));
        if (idx == 255) break;
    }
}

test "snapping a cell keeps its glyph and lands on palette colours" {
    const f = Fixed{ .table = .xterm256 };
    const out = f.cell(.{ .cp = 'x', .fg = .{ .r = 250, .g = 10, .b = 10 }, .bg = .{ .r = 0, .g = 0, .b = 255 } }, 3, 4);

    try std.testing.expectEqual(@as(u21, 'x'), out.cp);
    try std.testing.expect(out.fg.eql(xtermRgb(196)));
    try std.testing.expect(out.bg.eql(xtermRgb(21)));
    try std.testing.expectEqual(@as(u8, 196), nearest(.xterm256, out.fg));
    try std.testing.expectEqual(@as(u8, 21), nearest(.xterm256, out.bg));
}

test "snapping twice changes nothing" {
    const f = Fixed{ .table = .xterm256 };
    const once = f.cell(.{ .fg = .{ .r = 17, .g = 200, .b = 44 }, .bg = .{ .r = 250, .g = 250, .b = 3 } }, 0, 0);
    const twice = f.cell(once, 0, 0);
    try std.testing.expect(twice.fg.eql(once.fg));
    try std.testing.expect(twice.bg.eql(once.bg));
}

test "a caller supplied table picks the closer slot" {
    const table = [_]RGB{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 128, .b = 0 },
    };
    try std.testing.expectEqual(@as(u8, 1), nearest(.{ .fixed = &table }, .{ .r = 200, .g = 200, .b = 200 }));
    try std.testing.expectEqual(@as(u8, 2), nearest(.{ .fixed = &table }, .{ .r = 10, .g = 120, .b = 10 }));
    try std.testing.expectEqual(@as(u8, 0), nearest(.{ .fixed = &table }, .{ .r = 5, .g = 5, .b = 5 }));
}
