//! Symbol ink matching: the glyph whose ink mask best fits a cell's silhouette.

const std = @import("std");
const types = @import("types.zig");
const quant = @import("quant.zig");
const ascii8 = @import("ink-ascii-8x8.zig");
const ascii16 = @import("ink-ascii-8x16.zig");

const Cell = types.Cell;
const RGB = types.RGB;

/// Upper bound on the exact scoring pass after the shortlist.
pub const work_max = 8;

/// How a cell is cut up for matching. Both grids are eight columns wide so the
/// block ladder's eighths stay one column per step; they differ in rows, which
/// is where a 1:2 terminal cell has room to spare.
pub const Grid = enum {
    /// 8x8: one sub-cell per 1.25x2.5 px of a 10x20 cell. Enough for the block
    /// ladder, coarse for letters.
    x8,
    /// 8x16: square sub-cells, twice the vertical detail. Letters stop
    /// collapsing onto each other here.
    tall,

    pub fn cols(_: Grid) u4 {
        return 8;
    }

    pub fn rows(g: Grid) u5 {
        return switch (g) {
            .x8 => 8,
            .tall => 16,
        };
    }

    pub fn samples(g: Grid) usize {
        return @as(usize, g.cols()) * @as(usize, g.rows());
    }

    pub fn bits(g: Grid) usize {
        return g.samples();
    }
};

/// The mask type a grid needs: one bit per sub-cell, most significant first.
pub fn Mask(comptime g: Grid) type {
    return switch (g) {
        .x8 => u64,
        .tall => u128,
    };
}

/// One glyph as the matcher sees it.
pub fn Glyph(comptime g: Grid) type {
    return struct {
        const Self = @This();

        cp: u21,
        /// Row-major from the top-left corner: the most significant bit is the
        /// first sub-cell, the least significant bit the last.
        mask: Mask(g),

        /// How many sub-cells this glyph inks.
        pub fn ink(self: Self) u8 {
            return @popCount(self.mask);
        }
    };
}

pub const Options = struct {
    /// Candidates scored exactly after the Hamming shortlist, clamped to 1..8.
    /// One is the pure "closest silhouette" answer.
    work: u4 = 4,
    /// Custom tables for a host that measured its own font; null picks the
    /// built-in table for that grid.
    x8: ?[]const Glyph(.x8) = null,
    tall: ?[]const Glyph(.tall) = null,

    fn pick(self: Options, comptime g: Grid) []const Glyph(g) {
        return switch (g) {
            .x8 => self.x8 orelse &tables.x8,
            .tall => self.tall orelse &tables.tall,
        };
    }
};

/// The glyph whose two colours and ink pattern rebuild `block` most closely.
///
/// Pure in `block`: the same samples always give the same cell, which is what
/// keeps the row diff honest.
pub fn choose(comptime g: Grid, block: *const [g.samples()]RGB, o: Options) Cell {
    const glyphs = o.pick(g);
    if (glyphs.len == 0) return .{};

    const pair = splitPair(g, block);
    const target = silhouette(g, block, pair);

    var short: [work_max]Candidate = @splat(.{ .hd = 255, .index = 0 });
    const work = std.math.clamp(@as(usize, o.work), 1, work_max);

    for (glyphs, 0..) |glyph, i| {
        const hd: u8 = @popCount(target ^ glyph.mask);
        var at = work;
        while (at > 0 and short[at - 1].hd > hd) at -= 1;
        if (at == work) continue;
        var k = work - 1;
        while (k > at) : (k -= 1) short[k] = short[k - 1];
        short[at] = .{ .hd = hd, .index = @intCast(i) };
    }

    var best_index = short[0].index;
    var best = score(g, block, glyphs[best_index]);
    for (short[1..work]) |c| {
        const s = score(g, block, glyphs[c.index]);
        if (s.err < best.err) {
            best = s;
            best_index = c.index;
        }
    }

    const glyph = glyphs[best_index];
    return .{ .cp = glyph.cp, .fg = best.fg, .bg = best.bg };
}

const Candidate = struct { hd: u8, index: u16 };

const Scored = struct { err: u32, fg: RGB, bg: RGB };

const Pair = struct { fg: RGB, bg: RGB };

fn chan(c: RGB, comptime i: usize) u8 {
    return switch (i) {
        0 => c.r,
        1 => c.g,
        else => c.b,
    };
}

/// The two colours a cell is made of: the pixel at the top of the widest channel
/// range, and the one at the bottom. Endpoint pixels rather than per-channel
/// extremes, so both colours are colours that actually occur in the cell.
fn splitPair(comptime g: Grid, block: *const [g.samples()]RGB) Pair {
    var lo: [3]usize = @splat(0);
    var hi: [3]usize = @splat(0);

    for (block, 0..) |p, i| {
        inline for (0..3) |c| {
            if (chan(p, c) < chan(block[lo[c]], c)) lo[c] = i;
            if (chan(p, c) >= chan(block[hi[c]], c)) hi[c] = i;
        }
    }

    var widest: usize = 0;
    var span: u8 = 0;
    inline for (0..3) |c| {
        const s = chan(block[hi[c]], c) - chan(block[lo[c]], c);
        if (s > span) {
            span = s;
            widest = c;
        }
    }
    return .{ .fg = block[hi[widest]], .bg = block[lo[widest]] };
}

/// One bit per sample, set where the sample is nearer the foreground.
fn silhouette(comptime g: Grid, block: *const [g.samples()]RGB, pair: Pair) Mask(g) {
    var m: Mask(g) = 0;
    for (block) |p| {
        const nearer_fg = quant.distance(p, pair.fg) < quant.distance(p, pair.bg);
        m = (m << 1) | @intFromBool(nearer_fg);
    }
    return m;
}

/// The two colours this glyph would use, and what is left of the block once it
/// is drawn: the mean of the covered samples as fg, the mean of the rest as bg.
///
/// The error comes out of the sums rather than a second pass over the samples:
/// `sum |p - c|^2 = sum |p|^2 - 2 (fg.S1 + bg.S0) + n1 |fg|^2 + n0 |bg|^2`, and
/// everything in it is already accumulated. Exact for any two colours, not just
/// the means, so it equals the sample-by-sample sum to the last unit.
fn score(comptime g: Grid, block: *const [g.samples()]RGB, glyph: Glyph(g)) Scored {
    var sum: [2][3]u32 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var count: [2]u32 = @splat(0);
    var energy: u32 = 0;

    for (block, 0..) |p, i| {
        const side: usize = @intFromBool(bitAt(g, glyph.mask, i) == 1);
        count[side] += 1;
        sum[side][0] += p.r;
        sum[side][1] += p.g;
        sum[side][2] += p.b;
        energy += @as(u32, p.r) * p.r + @as(u32, p.g) * p.g + @as(u32, p.b) * p.b;
    }

    // A blank glyph has no foreground and a solid one no background: both
    // collapse to the mean of what is there, so a flat area renders flat.
    const fg = if (count[1] != 0) mean(sum[1], count[1]) else mean(sum[0], count[0]);
    const bg = if (count[0] != 0) mean(sum[0], count[0]) else fg;

    const err = @as(i64, energy) -
        2 * (@as(i64, dot(sum[1], fg)) + @as(i64, dot(sum[0], bg))) +
        @as(i64, count[1]) * dot2(fg) + @as(i64, count[0]) * dot2(bg);

    return .{ .err = @intCast(err), .fg = fg, .bg = bg };
}

fn dot(sum: [3]u32, c: RGB) u32 {
    return sum[0] * c.r + sum[1] * c.g + sum[2] * c.b;
}

fn dot2(c: RGB) u32 {
    return @as(u32, c.r) * c.r + @as(u32, c.g) * c.g + @as(u32, c.b) * c.b;
}

fn mean(sum: [3]u32, n: u32) RGB {
    return .{
        .r = @intCast((sum[0] + n / 2) / n),
        .g = @intCast((sum[1] + n / 2) / n),
        .b = @intCast((sum[2] + n / 2) / n),
    };
}

fn bitAt(comptime g: Grid, mask: Mask(g), i: usize) u1 {
    const shift: std.math.Log2Int(Mask(g)) = @intCast(g.bits() - 1 - i);
    return @intCast((mask >> shift) & 1);
}

/// The rows the eighths `[top, bottom)` cover, filled across the whole width.
///
/// Eighth coordinates are the block ladder's own step, so a grid whose row count
/// is a multiple of eight maps each step onto whole rows. A grid that is not
/// (say 12 rows) would land steps mid-row and lose the ladder's exactness.
fn rows(comptime g: Grid, comptime top: u4, comptime bottom: u4) Mask(g) {
    const r: usize = g.rows();
    const c: usize = g.cols();
    var m: Mask(g) = 0;
    for (top..bottom) |eighth| {
        const first = @as(usize, eighth) * r / 8;
        for (first..first + r / 8) |row| {
            m |= @as(Mask(g), 0xFF) << @intCast((r - 1 - row) * c);
        }
    }
    return m;
}

/// The columns the eighths `[left, right)` cover, filled down the whole height.
fn cols(comptime g: Grid, comptime left: u4, comptime right: u4) Mask(g) {
    const r: usize = g.rows();
    const c: usize = g.cols();
    var m: Mask(g) = 0;
    for (0..r) |row| {
        for (left..right) |eighth| {
            m |= @as(Mask(g), 1) << @intCast((r - 1 - row) * c + (c - 1 - @as(usize, eighth)));
        }
    }
    return m;
}

fn quarter(comptime g: Grid, comptime top: bool, comptime left: bool) Mask(g) {
    return rows(g, if (top) 0 else 4, if (top) 4 else 8) &
        cols(g, if (left) 0 else 4, if (left) 4 else 8);
}

/// Glyphs whose mask follows from the codepoint rather than from a font. The
/// block elements are defined as fractions of a cell, so measuring them only
/// imports the font's rounding error -- and at 8x8 it also collapses
/// neighbouring steps onto the same mask.
fn blocks(comptime g: Grid) [28]Glyph(g) {
    @setEvalBranchQuota(40_000);
    return .{
        .{ .cp = 0x2580, .mask = rows(g, 0, 4) },
        // U+2581..U+2588: lower one eighth through full.
        .{ .cp = 0x2581, .mask = rows(g, 7, 8) },
        .{ .cp = 0x2582, .mask = rows(g, 6, 8) },
        .{ .cp = 0x2583, .mask = rows(g, 5, 8) },
        .{ .cp = 0x2584, .mask = rows(g, 4, 8) },
        .{ .cp = 0x2585, .mask = rows(g, 3, 8) },
        .{ .cp = 0x2586, .mask = rows(g, 2, 8) },
        .{ .cp = 0x2587, .mask = rows(g, 1, 8) },
        .{ .cp = 0x2588, .mask = rows(g, 0, 8) },
        // U+2589..U+258F: left seven eighths through left one eighth.
        .{ .cp = 0x2589, .mask = cols(g, 0, 7) },
        .{ .cp = 0x258A, .mask = cols(g, 0, 6) },
        .{ .cp = 0x258B, .mask = cols(g, 0, 5) },
        .{ .cp = 0x258C, .mask = cols(g, 0, 4) },
        .{ .cp = 0x258D, .mask = cols(g, 0, 3) },
        .{ .cp = 0x258E, .mask = cols(g, 0, 2) },
        .{ .cp = 0x258F, .mask = cols(g, 0, 1) },
        .{ .cp = 0x2590, .mask = cols(g, 4, 8) },
        .{ .cp = 0x2594, .mask = rows(g, 0, 1) },
        .{ .cp = 0x2595, .mask = cols(g, 7, 8) },
        // U+2596..U+259F: quadrants, one per combination the block set names.
        // U+2599 is left out: upper left plus lower left is U+258C's left half.
        .{ .cp = 0x2596, .mask = quarter(g, false, true) },
        .{ .cp = 0x2597, .mask = quarter(g, false, false) },
        .{ .cp = 0x2598, .mask = quarter(g, true, true) },
        .{ .cp = 0x259A, .mask = quarter(g, true, true) | quarter(g, false, false) },
        .{ .cp = 0x259B, .mask = quarter(g, true, true) | quarter(g, true, false) | quarter(g, false, true) },
        .{ .cp = 0x259C, .mask = quarter(g, true, true) | quarter(g, true, false) | quarter(g, false, false) },
        .{ .cp = 0x259D, .mask = quarter(g, true, false) },
        .{ .cp = 0x259E, .mask = quarter(g, true, false) | quarter(g, false, true) },
        .{ .cp = 0x259F, .mask = quarter(g, true, false) | quarter(g, false, true) | quarter(g, false, false) },
    };
}

fn asciiFile(comptime g: Grid) type {
    return switch (g) {
        .x8 => ascii8,
        .tall => ascii16,
    };
}

/// The measured half of the table, in the same shape `blocks` is written in.
fn measured(comptime g: Grid) [asciiFile(g).cps.len]Glyph(g) {
    @setEvalBranchQuota(40_000);
    const src = asciiFile(g);
    var t: [src.cps.len]Glyph(g) = undefined;
    for (src.cps, src.masks, 0..) |cp, mask, i| t[i] = .{ .cp = cp, .mask = mask };
    return t;
}

/// The tables the library ships, one per grid: the computed blocks, then the
/// measured ASCII half.
pub const tables = struct {
    pub const x8 = blocks(.x8) ++ measured(.x8);
    pub const tall = blocks(.tall) ++ measured(.tall);
};

pub fn table(comptime g: Grid) []const Glyph(g) {
    return switch (g) {
        .x8 => &tables.x8,
        .tall => &tables.tall,
    };
}

fn blockFrom(comptime g: Grid, mask: Mask(g), fg: RGB, bg: RGB) [g.samples()]RGB {
    var b: [g.samples()]RGB = undefined;
    for (0..g.samples()) |i| b[i] = if (bitAt(g, mask, i) == 1) fg else bg;
    return b;
}

fn maskOf(comptime g: Grid, cp: u21) Mask(g) {
    for (table(g)) |glyph| {
        if (glyph.cp == cp) return glyph.mask;
    }
    @panic("glyph not in the table");
}

test "the eighth helpers fill the cells they claim" {
    inline for ([_]Grid{ .x8, .tall }) |g| {
        const all: Mask(g) = std.math.maxInt(Mask(g));
        try std.testing.expectEqual(all, rows(g, 0, 8));
        try std.testing.expectEqual(all, cols(g, 0, 8));

        // One eighth of a cell is an eighth of its sub-cells: one row at 8x8,
        // two at 8x16.
        try std.testing.expectEqual(@as(u8, @intCast(g.bits() / 8)), @as(u8, @intCast(@popCount(rows(g, 7, 8)))));
        // A column band covers one bit in every row.
        try std.testing.expectEqual(@as(u8, @intCast(g.rows())), @as(u8, @intCast(@popCount(cols(g, 7, 8)))));
        try std.testing.expectEqual(@as(u8, @intCast(4 * @as(usize, g.rows()))), @as(u8, @intCast(@popCount(cols(g, 0, 4)))));
    }

    // Spot values, so the bit order is pinned and not just the counts.
    try std.testing.expectEqual(@as(u64, 0x0000_0000_FFFF_FFFF), rows(.x8, 4, 8));
    try std.testing.expectEqual(@as(u64, 0xF0F0_F0F0_F0F0_F0F0), cols(.x8, 0, 4));
    try std.testing.expectEqual(@as(u128, 0x0000_0000_0000_0000_FFFF_FFFF_FFFF_FFFF), rows(.tall, 4, 8));
    try std.testing.expectEqual(@as(u128, 0xF0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0), cols(.tall, 0, 4));
}

test "the block entries carry the masks their codepoints name" {
    inline for ([_]Grid{ .x8, .tall }) |g| {
        try std.testing.expectEqual(rows(g, 0, 4), maskOf(g, 0x2580));
        try std.testing.expectEqual(rows(g, 4, 8), maskOf(g, 0x2584));
        try std.testing.expectEqual(rows(g, 0, 8), maskOf(g, 0x2588));
        try std.testing.expectEqual(cols(g, 0, 4), maskOf(g, 0x258C));
        try std.testing.expectEqual(quarter(g, false, true), maskOf(g, 0x2596));
        try std.testing.expectEqual(quarter(g, false, false), maskOf(g, 0x2597));
    }
}

test "no two glyphs share a mask" {
    // The matcher cannot tell them apart, so a duplicate is a wasted slot and a
    // sign that the table was assembled twice.
    inline for ([_]Grid{ .x8, .tall }) |g| {
        const t = table(g);
        for (t, 0..) |a, i| {
            for (t[i + 1 ..]) |b| try std.testing.expect(a.mask != b.mask);
        }
    }
}

test "the tables span the tonal ends" {
    inline for ([_]Grid{ .x8, .tall }) |g| {
        var lowest: u8 = 255;
        var highest: u8 = 0;
        for (table(g)) |glyph| {
            lowest = @min(lowest, glyph.ink());
            highest = @max(highest, glyph.ink());
        }
        try std.testing.expectEqual(@as(u8, 0), lowest);
        try std.testing.expectEqual(@as(u8, @intCast(g.bits())), highest);
    }
}

test "a flat block stays flat" {
    inline for ([_]Grid{ .x8, .tall }) |g| {
        const flat: [g.samples()]RGB = @splat(.{ .r = 137, .g = 140, .b = 150 });
        const cell = choose(g, &flat, .{});

        try std.testing.expectEqual(@as(u8, 137), cell.fg.r);
        try std.testing.expectEqual(@as(u8, 150), cell.fg.b);
        try std.testing.expectEqual(@as(u8, 137), cell.bg.r);
        try std.testing.expectEqual(@as(u8, 150), cell.bg.b);
        try std.testing.expect(cell.cp == ' ' or cell.cp == 0x2588);
    }
}

test "a block built from a glyph comes back as that glyph" {
    const fg = RGB{ .r = 230, .g = 30, .b = 30 };
    const bg = RGB{ .r = 20, .g = 20, .b = 200 };

    // A block in one colour has no silhouette, so the blank and the solid glyph
    // are two ways of drawing the same flat cell. Everything with two tones
    // must come back exactly.
    inline for ([_]Grid{ .x8, .tall }) |g| {
        for (table(g)) |glyph| {
            if (glyph.ink() == 0 or glyph.ink() == g.bits()) continue;
            const block = blockFrom(g, glyph.mask, fg, bg);
            const cell = choose(g, &block, .{});
            try std.testing.expectEqual(glyph.mask, maskOf(g, cell.cp));
            try std.testing.expectEqual(fg.r, cell.fg.r);
            try std.testing.expectEqual(bg.b, cell.bg.b);
        }
    }
}

test "an edge between two colours keeps both" {
    // Upper half one colour, lower half another: the cell must show both, which
    // a brightness ramp cannot do at all. `blockFrom` takes the colour of the
    // inked side first, and rows(g, 4, 8) inks the lower half.
    const upper = RGB{ .r = 40, .g = 90, .b = 40 };
    const lower = RGB{ .r = 210, .g = 200, .b = 60 };

    inline for ([_]Grid{ .x8, .tall }) |g| {
        const block = blockFrom(g, rows(g, 4, 8), lower, upper);
        const cell = choose(g, &block, .{});
        try std.testing.expectEqual(rows(g, 4, 8), maskOf(g, cell.cp));
        try std.testing.expect((cell.fg.eql(lower) and cell.bg.eql(upper)) or
            (cell.fg.eql(upper) and cell.bg.eql(lower)));
    }
}

test "the error from the sums matches the error from the samples" {
    var prng = std.Random.DefaultPrng.init(0x5ca1e);
    const rand = prng.random();

    inline for ([_]Grid{ .x8, .tall }) |g| {
        for (0..8) |_| {
            var block: [g.samples()]RGB = undefined;
            for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

            for (table(g)) |glyph| {
                const s = score(g, &block, glyph);
                var naive: u32 = 0;
                for (block, 0..) |p, i| {
                    naive += quant.distance(p, if (bitAt(g, glyph.mask, i) == 1) s.fg else s.bg);
                }
                try std.testing.expectEqual(naive, s.err);
            }
        }
    }
}

test "scoring more candidates never makes the answer worse" {
    // The shortlist is a heuristic: it can miss the globally cheapest glyph, so
    // the promise is only that a wider shortlist cannot be worse. The eight
    // best by Hamming distance contain the single best, which makes it provable.
    var prng = std.Random.DefaultPrng.init(0x1a2b);
    const rand = prng.random();

    inline for ([_]Grid{ .x8, .tall }) |g| {
        for (0..32) |_| {
            var block: [g.samples()]RGB = undefined;
            for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

            const cheap = choose(g, &block, .{ .work = 1 });
            const thorough = choose(g, &block, .{ .work = 8 });
            const a = score(g, &block, .{ .cp = cheap.cp, .mask = maskOf(g, cheap.cp) }).err;
            const b = score(g, &block, .{ .cp = thorough.cp, .mask = maskOf(g, thorough.cp) }).err;
            try std.testing.expect(b <= a);
        }
    }
}

test "the same block always gives the same cell" {
    var prng = std.Random.DefaultPrng.init(0xc311);
    const rand = prng.random();

    inline for ([_]Grid{ .x8, .tall }) |g| {
        var block: [g.samples()]RGB = undefined;
        for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

        try std.testing.expect(std.meta.eql(choose(g, &block, .{}), choose(g, &block, .{})));
    }
}

test "an empty glyph list falls back to a blank cell" {
    const flat8: [64]RGB = @splat(RGB.black);
    const flat16: [128]RGB = @splat(RGB.black);
    try std.testing.expectEqual(@as(u21, ' '), choose(.x8, &flat8, .{ .x8 = &.{} }).cp);
    try std.testing.expectEqual(@as(u21, ' '), choose(.tall, &flat16, .{ .tall = &.{} }).cp);
}
