//! Colour quantisation: palettes, nearest-colour lookup, two-slot mixes.

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

/// A two-slot stand-in for a colour: `alt` in `fraction` of the cells, `slot` in
/// the rest. `fraction` never exceeds one half — `slot` is the nearer of the two
/// — and zero means `slot` alone is the answer.
pub const Mix = struct {
    slot: u8,
    alt: u8,
    fraction: f32,
};

/// The pair of slots whose average lands closest to `c`, and never farther from
/// it than the nearest slot alone. `slot` is always `nearest(p, c)`; `alt` is
/// `slot` again when nothing beats snapping. Pairs that land equally close are
/// separated by which stipples more quietly: `fraction * (1 - fraction)` of the
/// squared distance between them.
pub fn mix(p: Palette, c: RGB) Mix {
    const base = nearest(p, c);
    var search = Search{ .c = c, .base = base, .base_rgb = rgb(p, base), .best = base };
    switch (p) {
        .xterm256 => offerXterm(&search, c),
        .fixed => |table| {
            for (table, 0..) |col, i| search.offer(@intCast(i), col);
        },
    }
    return .{ .slot = base, .alt = search.best, .fraction = search.fraction };
}

const Search = struct {
    c: RGB,
    base: u8,
    base_rgb: RGB,
    best: u8,
    best_err: f32 = std.math.floatMax(f32),
    best_spread: f32 = std.math.floatMax(f32),
    fraction: f32 = 0,

    /// Keeps `slot` when the line from `base` to it passes nearer to `c` than
    /// anything offered before. `fraction` is the clamped projection of `c` onto
    /// that line, and `best_err` is what is left of `c` off it.
    fn offer(self: *Search, slot: u8, col: RGB) void {
        if (slot == self.base) return;

        const vx = asF32(col.r) - asF32(self.base_rgb.r);
        const vy = asF32(col.g) - asF32(self.base_rgb.g);
        const vz = asF32(col.b) - asF32(self.base_rgb.b);
        const denom = vx * vx + vy * vy + vz * vz;
        if (denom == 0) return;

        const dx = asF32(self.c.r) - asF32(self.base_rgb.r);
        const dy = asF32(self.c.g) - asF32(self.base_rgb.g);
        const dz = asF32(self.c.b) - asF32(self.base_rgb.b);

        const p = std.math.clamp((dx * vx + dy * vy + dz * vz) / denom, 0, 0.5);
        const ex = dx - p * vx;
        const ey = dy - p * vy;
        const ez = dz - p * vz;
        const err = ex * ex + ey * ey + ez * ez;
        const spread = p * (1 - p) * denom;

        if (err < self.best_err or (err == self.best_err and spread < self.best_spread)) {
            self.best_err = err;
            self.best_spread = spread;
            self.best = slot;
            self.fraction = p;
        }
    }
};

/// The candidates that can bracket a colour in the 256 table: the cube slot it
/// sits in, the six cube slots across a face, and the grey ramp on either side.
/// A face neighbour is always nearer than a corner one, so the second nearest
/// slot is among these.
fn offerXterm(s: *Search, c: RGB) void {
    const idx = [3]usize{ cubeLevel(c.r), cubeLevel(c.g), cubeLevel(c.b) };
    s.offer(cubeSlot(idx), xtermRgb(cubeSlot(idx)));

    inline for (0..3) |axis| {
        if (idx[axis] + 1 < CUBE.len) {
            var up = idx;
            up[axis] += 1;
            s.offer(cubeSlot(up), xtermRgb(cubeSlot(up)));
        }
        if (idx[axis] > 0) {
            var down = idx;
            down[axis] -= 1;
            s.offer(cubeSlot(down), xtermRgb(cubeSlot(down)));
        }
    }

    const g = greySlot(c);
    s.offer(232 + g, xtermRgb(232 + g));
    if (g > 0) s.offer(231 + g, xtermRgb(231 + g));
    if (g + 1 < GREY_SLOTS) s.offer(233 + g, xtermRgb(233 + g));
}

fn asF32(v: u8) f32 {
    return @floatFromInt(v);
}

fn cubeSlot(idx: [3]usize) u8 {
    return @intCast(16 + 36 * idx[0] + 6 * idx[1] + idx[2]);
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

/// Which candidate family the table offers for a colour: the 6x6x6 cube, or the
/// 24-step grey ramp. The nearer one wins.
const Family = enum { cube, grey };

const Pick = struct {
    family: Family,
    cube: [3]usize,
    grey: u8,
};

fn pick(c: RGB) Pick {
    const idx = [3]usize{ cubeLevel(c.r), cubeLevel(c.g), cubeLevel(c.b) };
    const cube = RGB{ .r = CUBE[idx[0]], .g = CUBE[idx[1]], .b = CUBE[idx[2]] };

    const grey = greySlot(c);
    const v: u8 = GREY_BASE + GREY_STEP * grey;
    const grey_rgb = RGB{ .r = v, .g = v, .b = v };

    return .{
        .family = if (distance(c, grey_rgb) <= distance(c, cube)) .grey else .cube,
        .cube = idx,
        .grey = grey,
    };
}

fn nearestXterm(c: RGB) u8 {
    const p = pick(c);
    return switch (p.family) {
        .grey => @as(u8, 232) + p.grey,
        .cube => cubeSlot(p.cube),
    };
}

fn greySlot(c: RGB) u8 {
    const mean = (@as(u32, c.r) + c.g + c.b) / 3;
    return @intCast(std.math.clamp(
        @divFloor(@as(i32, @intCast(mean)) - GREY_BASE + GREY_STEP / 2, GREY_STEP),
        0,
        GREY_SLOTS - 1,
    ));
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

test "a colour already on a slot has nothing to mix" {
    var idx: u8 = 16;
    while (true) : (idx +%= 1) {
        const m = mix(.xterm256, xtermRgb(idx));
        try std.testing.expectEqual(idx, m.slot);
        try std.testing.expectEqual(@as(f32, 0), m.fraction);
        if (idx == 255) break;
    }
}

test "black is not stippled" {
    // The cube's first band is 95 wide, but the grey ramp sits right next to
    // black: any mix there would light the whole area up.
    const m = mix(.xterm256, RGB.black);
    try std.testing.expectEqual(@as(f32, 0), m.fraction);
}

test "a midpoint splits evenly between its neighbouring greys" {
    // 153 is exactly between grey 148 and 158, which nearest breaks upwards.
    const m = mix(.xterm256, .{ .r = 153, .g = 153, .b = 153 });
    try std.testing.expectEqual(@as(u8, 247), m.slot);
    try std.testing.expectEqual(@as(u8, 246), m.alt);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m.fraction, 0.01);
}

test "a colour on the grey axis mixes along it" {
    // (1,1,1) is one eighth of the way from black to grey 8 and nothing else is
    // near, so the mix is exact and the fraction is that eighth.
    const m = mix(.xterm256, .{ .r = 1, .g = 1, .b = 1 });
    try std.testing.expectEqual(@as(u8, 16), m.slot);
    try std.testing.expectEqual(@as(u8, 232), m.alt);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), m.fraction, 0.01);
}

test "a saturated colour mixes along its own channel" {
    // 200 on red sits between cube 175 and 215; mixing greys there would lose red.
    const m = mix(.xterm256, .{ .r = 200, .g = 0, .b = 0 });
    try std.testing.expectEqual(@as(u8, 160), m.slot);
    try std.testing.expectEqual(@as(u8, 124), m.alt);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), m.fraction, 0.01);
}

test "fuzz: the mix is never a worse guess than the snap alone" {
    var prng = std.Random.DefaultPrng.init(0xbeef);
    const rand = prng.random();
    for (0..3000) |_| {
        const c = RGB{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };
        const m = mix(.xterm256, c);
        try std.testing.expect(m.fraction >= 0 and m.fraction <= 0.5);

        const base = xtermRgb(m.slot);
        const alt = xtermRgb(m.alt);
        const mixed = RGB{
            .r = @intFromFloat(@round(@as(f32, @floatFromInt(base.r)) + m.fraction * (@as(f32, @floatFromInt(alt.r)) - @as(f32, @floatFromInt(base.r))))),
            .g = @intFromFloat(@round(@as(f32, @floatFromInt(base.g)) + m.fraction * (@as(f32, @floatFromInt(alt.g)) - @as(f32, @floatFromInt(base.g))))),
            .b = @intFromFloat(@round(@as(f32, @floatFromInt(base.b)) + m.fraction * (@as(f32, @floatFromInt(alt.b)) - @as(f32, @floatFromInt(base.b))))),
        };
        try std.testing.expect(distance(mixed, c) <= distance(base, c));
    }
}

test "a two colour table mixes between the only slot it has" {
    const table = [_]RGB{ RGB.black, RGB.white };
    const m = mix(.{ .fixed = &table }, .{ .r = 64, .g = 64, .b = 64 });
    try std.testing.expectEqual(@as(u8, 0), m.slot);
    try std.testing.expectEqual(@as(u8, 1), m.alt);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), m.fraction, 0.01);
}
