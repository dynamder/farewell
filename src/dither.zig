//! Ordered dithering: a positional threshold spreads a mix over a tile.

const std = @import("std");
const types = @import("types.zig");
const quant = @import("quant.zig");

const Cell = types.Cell;
const RGB = types.RGB;

/// Bayer's recursive thresholds, applied per cell to the mix `quant.mix` finds.
///
/// A cell takes the second slot of that mix when its threshold falls below the
/// fraction `mix` asks for, so a tile averages to the colour that was drawn and
/// no further. The threshold depends only on `(x, y)`, which is what lets it
/// live in the per-cell stage: `prev` holds post-processed cells, and a
/// position-only effect cannot make the row diff lie about what is on screen.
pub const Bayer = struct {
    table: quant.Palette,
    /// Thresholds across one tile. The tile holds `n * n` thresholds, so the mix
    /// is resolved to that many steps.
    matrix: Matrix = .x4,

    pub fn cell(self: *const Bayer, c: Cell, x: u16, y: u16) Cell {
        const t = self.threshold(x, y);
        var out = c;
        out.fg = self.snap(c.fg, t);
        out.bg = self.snap(c.bg, t);
        return out;
    }

    /// Tells the encoder these colours are slots in `table`.
    pub fn palette(self: *const Bayer) ?quant.Palette {
        return self.table;
    }

    fn snap(self: *const Bayer, c: RGB, t: f32) RGB {
        const m = quant.mix(self.table, c);
        return quant.rgb(self.table, if (m.fraction > 0 and t < m.fraction) m.alt else m.slot);
    }

    fn threshold(self: *const Bayer, x: u16, y: u16) f32 {
        return switch (self.matrix) {
            .x2 => at(2, TWO, x, y),
            .x4 => at(4, FOUR, x, y),
            .x8 => at(8, EIGHT, x, y),
        };
    }
};

/// The width of one tile, in cells.
pub const Matrix = enum { x2, x4, x8 };

fn MatrixOf(comptime n: u16) type {
    return [n][n]u16;
}

fn thresholds(comptime n: u16) MatrixOf(n) {
    if (n == 2) return .{ .{ 0, 2 }, .{ 3, 1 } };

    const half = n / 2;
    const sub = thresholds(half);
    const off = [2][2]u16{ .{ 0, 2 }, .{ 3, 1 } };

    var m: MatrixOf(n) = undefined;
    for (0..half) |i| {
        for (0..half) |j| {
            for (0..2) |a| {
                for (0..2) |b| {
                    m[half * a + i][half * b + j] = 4 * sub[i][j] + off[a][b];
                }
            }
        }
    }
    return m;
}

const TWO = thresholds(2);
const FOUR = thresholds(4);
const EIGHT = thresholds(8);

fn at(comptime n: u16, m: MatrixOf(n), x: u16, y: u16) f32 {
    const v = m[y % n][x % n];
    return (@as(f32, @floatFromInt(v)) + 0.5) / @as(f32, @floatFromInt(n * n));
}

fn complete(comptime n: u16, m: MatrixOf(n)) !void {
    var seen: [n * n]bool = @splat(false);
    for (m) |row| {
        for (row) |v| {
            try std.testing.expect(v < n * n);
            try std.testing.expect(!seen[v]);
            seen[v] = true;
        }
    }
}

test "every threshold appears once per tile" {
    try complete(2, TWO);
    try complete(4, FOUR);
    try complete(8, EIGHT);
}

test "the recursion keeps bayer's offsets" {
    try std.testing.expectEqual([2][2]u16{ .{ 0, 2 }, .{ 3, 1 } }, TWO);
    try std.testing.expectEqual([4][4]u16{
        .{ 0, 8, 2, 10 },
        .{ 12, 4, 14, 6 },
        .{ 3, 11, 1, 9 },
        .{ 15, 7, 13, 5 },
    }, FOUR);
}

test "a colour already on a slot keeps the whole tile" {
    const b = Bayer{ .table = .xterm256, .matrix = .x8 };
    const red = quant.rgb(.xterm256, 196);
    for (0..8) |y| {
        for (0..8) |x| {
            const out = b.cell(.{ .cp = 'x', .fg = red, .bg = types.RGB.black }, @intCast(x), @intCast(y));
            try std.testing.expect(out.fg.eql(red));
            try std.testing.expectEqual(@as(u21, 'x'), out.cp);
        }
    }
}

test "a colour between two slots stipples across them and keeps the mean" {
    const b = Bayer{ .table = .xterm256, .matrix = .x8 };
    const lo = quant.nearest(.xterm256, .{ .r = 148, .g = 148, .b = 148 });
    const hi = quant.nearest(.xterm256, .{ .r = 158, .g = 158, .b = 158 });

    var sum: usize = 0;
    var seen_lo: usize = 0;
    var seen_hi: usize = 0;
    for (0..8) |y| {
        for (0..8) |x| {
            const out = b.cell(.{ .fg = .{ .r = 153, .g = 153, .b = 153 } }, @intCast(x), @intCast(y));
            const slot = quant.nearest(.xterm256, out.fg);
            if (slot == lo) seen_lo += 1;
            if (slot == hi) seen_hi += 1;
            sum += out.fg.r;
        }
    }

    // 153 is the midpoint of grey 148..158, so half the tile lands on each side
    // and the average comes back to the colour that was drawn.
    try std.testing.expectEqual(@as(usize, 64), seen_lo + seen_hi);
    try std.testing.expectEqual(@as(usize, 32), seen_lo);
    try std.testing.expectEqual(@as(usize, 32), seen_hi);
    try std.testing.expect(@abs(@as(i32, @intCast(sum / 64)) - 153) <= 1);
}

test "every cell comes out on a slot" {
    const b = Bayer{ .table = .xterm256, .matrix = .x4 };
    var prng = std.Random.DefaultPrng.init(0xd17);
    const rand = prng.random();
    for (0..500) |i| {
        const c = RGB{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };
        const out = b.cell(.{ .fg = c }, @intCast(i % 4), @intCast((i / 4) % 4));
        try std.testing.expect(quant.rgb(.xterm256, quant.nearest(.xterm256, out.fg)).eql(out.fg));
    }
}

test "the threshold follows the position only" {
    const b = Bayer{ .table = .xterm256, .matrix = .x4 };
    const c = Cell{ .fg = .{ .r = 153, .g = 153, .b = 153 } };

    const first = b.cell(c, 0, 0);
    const again = b.cell(c, 0, 0);
    const next = b.cell(c, 1, 0);

    try std.testing.expect(first.fg.eql(again.fg));
    try std.testing.expect(!first.fg.eql(next.fg));
}

test "a caller supplied table stipples between its own slots" {
    const table = [_]RGB{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
    };
    const b = Bayer{ .table = .{ .fixed = &table }, .matrix = .x4 };

    var sum: usize = 0;
    for (0..4) |y| {
        for (0..4) |x| {
            const out = b.cell(.{ .fg = .{ .r = 64, .g = 64, .b = 64 } }, @intCast(x), @intCast(y));
            try std.testing.expect(out.fg.eql(table[0]) or out.fg.eql(table[1]));
            sum += out.fg.r;
        }
    }
    try std.testing.expect(@abs(@as(i32, @intCast(sum / 16)) - 64) <= 2);
}
