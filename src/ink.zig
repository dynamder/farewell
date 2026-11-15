//! Symbol ink matching: the glyph whose 8x8 ink best fits a cell's silhouette.

const std = @import("std");
const types = @import("types.zig");
const quant = @import("quant.zig");
const ascii = @import("ink-ascii.zig");

const Cell = types.Cell;
const RGB = types.RGB;

/// Upper bound on the exact scoring pass after the shortlist.
pub const work_max = 8;

/// One glyph as the matcher sees it.
pub const Glyph = struct {
    cp: u21,
    /// Row-major from the top-left corner of the cell: bit 63 is the first
    /// sub-cell, bit 0 the last.
    mask: u64,

    /// How many of the 64 sub-cells this glyph inks.
    pub fn ink(self: Glyph) u8 {
        return @popCount(self.mask);
    }
};

pub const Options = struct {
    /// Glyphs the matcher may use; null means `table`. A host with an unusual
    /// font can generate its own with `tools/inkmap.py`.
    glyphs: ?[]const Glyph = null,
    /// Candidates scored exactly after the Hamming shortlist, clamped to 1..8.
    /// One is the pure "closest silhouette" answer; eight costs eight passes.
    work: u4 = 4,
};

/// The glyph whose two colours and ink pattern rebuild `block` most closely.
///
/// Pure in `block`: the same 64 samples always give the same cell, which is what
/// keeps the row diff honest.
pub fn choose(block: *const [64]RGB, o: Options) Cell {
    const glyphs = o.glyphs orelse &table;
    if (glyphs.len == 0) return .{};

    const pair = splitPair(block);
    const target = silhouette(block, pair);

    var short: [work_max]Candidate = @splat(.{ .hd = 255, .index = 0 });
    const work = std.math.clamp(@as(usize, o.work), 1, work_max);

    for (glyphs, 0..) |g, i| {
        const hd: u8 = @popCount(target ^ g.mask);
        var at = work;
        while (at > 0 and short[at - 1].hd > hd) at -= 1;
        if (at == work) continue;
        var k = work - 1;
        while (k > at) : (k -= 1) short[k] = short[k - 1];
        short[at] = .{ .hd = hd, .index = @intCast(i) };
    }

    var best_index = short[0].index;
    var best = score(block, glyphs[best_index]);
    for (short[1..work]) |c| {
        const s = score(block, glyphs[c.index]);
        if (s.err < best.err) {
            best = s;
            best_index = c.index;
        }
    }

    const g = glyphs[best_index];
    return .{ .cp = g.cp, .fg = best.fg, .bg = best.bg };
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
fn splitPair(block: *const [64]RGB) Pair {
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

/// 64 bits, one per sample: set where the sample is nearer the foreground.
fn silhouette(block: *const [64]RGB, pair: Pair) u64 {
    var m: u64 = 0;
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
fn score(block: *const [64]RGB, g: Glyph) Scored {
    var sum: [2][3]u32 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var count: [2]u32 = @splat(0);
    var energy: u32 = 0;

    for (block, 0..) |p, i| {
        const side: usize = @intFromBool(bitAt(g.mask, i) == 1);
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

fn bitAt(mask: u64, i: usize) u1 {
    return @intCast((mask >> @intCast(63 - i)) & 1);
}

/// The rows `[top, bottom)` filled, counted in eighths of the cell.
///
/// The grid is 8x8 so that the block ladder's own step -- one eighth -- is
/// exactly one row. Changing the grid changes this contract, not just a number.
fn rows(comptime top: u4, comptime bottom: u4) u64 {
    var m: u64 = 0;
    for (top..bottom) |r| m |= @as(u64, 0xFF) << @as(u6, @intCast((7 - r) * 8));
    return m;
}

/// The columns `[left, right)` filled, counted in eighths of the cell.
fn cols(comptime left: u4, comptime right: u4) u64 {
    var m: u64 = 0;
    for (left..right) |c| m |= @as(u64, 0x0101010101010101) << @as(u6, @intCast(7 - c));
    return m;
}

fn quarter(comptime top: bool, comptime left: bool) u64 {
    return (if (top) rows(0, 4) else rows(4, 8)) & (if (left) cols(0, 4) else cols(4, 8));
}

/// Glyphs whose mask follows from the codepoint rather than from a font. The
/// block elements are defined as fractions of a cell, so measuring them would
/// only add the font's rounding error -- and at 8x8 it would also collapse
/// neighbouring steps onto the same mask.
const blocks = [_]Glyph{
    .{ .cp = 0x2580, .mask = rows(0, 4) },
    // U+2581..U+2588: lower one eighth through full.
    .{ .cp = 0x2581, .mask = rows(7, 8) },
    .{ .cp = 0x2582, .mask = rows(6, 8) },
    .{ .cp = 0x2583, .mask = rows(5, 8) },
    .{ .cp = 0x2584, .mask = rows(4, 8) },
    .{ .cp = 0x2585, .mask = rows(3, 8) },
    .{ .cp = 0x2586, .mask = rows(2, 8) },
    .{ .cp = 0x2587, .mask = rows(1, 8) },
    .{ .cp = 0x2588, .mask = rows(0, 8) },
    // U+2589..U+258F: left seven eighths through left one eighth.
    .{ .cp = 0x2589, .mask = cols(0, 7) },
    .{ .cp = 0x258A, .mask = cols(0, 6) },
    .{ .cp = 0x258B, .mask = cols(0, 5) },
    .{ .cp = 0x258C, .mask = cols(0, 4) },
    .{ .cp = 0x258D, .mask = cols(0, 3) },
    .{ .cp = 0x258E, .mask = cols(0, 2) },
    .{ .cp = 0x258F, .mask = cols(0, 1) },
    .{ .cp = 0x2590, .mask = cols(4, 8) },
    .{ .cp = 0x2594, .mask = rows(0, 1) },
    .{ .cp = 0x2595, .mask = cols(7, 8) },
    // U+2596..U+259F: quadrants, one per combination the block set names.
    // U+2599 is left out: upper left plus lower left is U+258C's left half.
    .{ .cp = 0x2596, .mask = quarter(false, true) },
    .{ .cp = 0x2597, .mask = quarter(false, false) },
    .{ .cp = 0x2598, .mask = quarter(true, true) },
    .{ .cp = 0x259A, .mask = quarter(true, true) | quarter(false, false) },
    .{ .cp = 0x259B, .mask = quarter(true, true) | quarter(true, false) | quarter(false, true) },
    .{ .cp = 0x259C, .mask = quarter(true, true) | quarter(true, false) | quarter(false, false) },
    .{ .cp = 0x259D, .mask = quarter(true, false) },
    .{ .cp = 0x259E, .mask = quarter(true, false) | quarter(false, true) },
    .{ .cp = 0x259F, .mask = quarter(true, false) | quarter(false, true) | quarter(false, false) },
};

/// The measured half of the table, in the same shape `blocks` is written in.
const measured = blk: {
    var t: [ascii.cps.len]Glyph = undefined;
    for (ascii.cps, ascii.masks, 0..) |cp, mask, i| t[i] = .{ .cp = cp, .mask = mask };
    break :blk t;
};

/// Every glyph the matcher knows: the computed blocks, then the measured ASCII.
pub const table = blocks ++ measured;

fn blockFrom(mask: u64, fg: RGB, bg: RGB) [64]RGB {
    var b: [64]RGB = undefined;
    for (0..64) |i| b[i] = if (bitAt(mask, i) == 1) fg else bg;
    return b;
}

fn maskOf(cp: u21) u64 {
    for (table) |g| {
        if (g.cp == cp) return g.mask;
    }
    @panic("glyph not in the table");
}

fn chosenMask(c: Cell) u64 {
    return maskOf(c.cp);
}

test "the quarter and eighth helpers fill the cells they claim" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), rows(0, 8));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_FFFF_FFFF), rows(4, 8));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_00FF), rows(7, 8));
    try std.testing.expectEqual(@as(u64, 0x0101_0101_0101_0101), cols(7, 8));
    try std.testing.expectEqual(@as(u64, 0x0F0F_0F0F_0F0F_0F0F), cols(4, 8));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0F0F_0F0F), quarter(false, false));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_F0F0_F0F0), quarter(false, true));
}

test "the block entries carry the masks their codepoints name" {
    try std.testing.expectEqual(rows(0, 4), maskOf(0x2580));
    try std.testing.expectEqual(rows(4, 8), maskOf(0x2584));
    try std.testing.expectEqual(rows(0, 8), maskOf(0x2588));
    try std.testing.expectEqual(cols(0, 4), maskOf(0x258C));
    try std.testing.expectEqual(quarter(false, true), maskOf(0x2596));
    try std.testing.expectEqual(quarter(false, false), maskOf(0x2597));
}

test "no two glyphs share a mask" {
    // The matcher cannot tell them apart, so a duplicate is a wasted slot and a
    // sign that the table was assembled twice.
    for (table, 0..) |g, i| {
        for (table[i + 1 ..]) |h| {
            try std.testing.expect(g.mask != h.mask);
        }
    }
}

test "the table spans the tonal ends" {
    var lowest: u8 = 255;
    var highest: u8 = 0;
    for (table) |g| {
        lowest = @min(lowest, g.ink());
        highest = @max(highest, g.ink());
    }
    try std.testing.expectEqual(@as(u8, 0), lowest);
    try std.testing.expectEqual(@as(u8, 64), highest);
}

test "a flat block stays flat" {
    const flat: [64]RGB = @splat(.{ .r = 137, .g = 140, .b = 150 });
    const cell = choose(&flat, .{});

    try std.testing.expectEqual(@as(u8, 137), cell.fg.r);
    try std.testing.expectEqual(@as(u8, 150), cell.fg.b);
    try std.testing.expectEqual(@as(u8, 137), cell.bg.r);
    try std.testing.expectEqual(@as(u8, 150), cell.bg.b);
    try std.testing.expect(cell.cp == ' ' or cell.cp == 0x2588);
}

test "a block built from a glyph comes back as that glyph" {
    const fg = RGB{ .r = 230, .g = 30, .b = 30 };
    const bg = RGB{ .r = 20, .g = 20, .b = 200 };

    // A block in one colour has no silhouette, so the blank and the solid glyph
    // are two ways of drawing the same flat cell and either answer is right.
    // Everything with two tones must come back exactly.
    for (table) |g| {
        if (g.ink() == 0 or g.ink() == 64) continue;
        const block = blockFrom(g.mask, fg, bg);
        const cell = choose(&block, .{});
        try std.testing.expectEqual(g.mask, chosenMask(cell));
        try std.testing.expectEqual(fg.r, cell.fg.r);
        try std.testing.expectEqual(bg.b, cell.bg.b);
    }
}

test "an edge between two colours keeps both" {
    // Upper half one colour, lower half another: the cell must show both, which
    // a brightness ramp cannot do at all. `blockFrom` takes the colour of the
    // inked side first, and rows(4, 8) inks the lower half.
    const upper = RGB{ .r = 40, .g = 90, .b = 40 };
    const lower = RGB{ .r = 210, .g = 200, .b = 60 };
    const block = blockFrom(rows(4, 8), lower, upper);

    const cell = choose(&block, .{});
    try std.testing.expectEqual(rows(4, 8), chosenMask(cell));
    try std.testing.expect((cell.fg.eql(lower) and cell.bg.eql(upper)) or
        (cell.fg.eql(upper) and cell.bg.eql(lower)));
}

test "scoring more candidates never makes the answer worse" {
    // The shortlist is a heuristic: it can miss the globally cheapest glyph, so
    // the promise is only that a wider shortlist cannot be worse. The eight
    // best by Hamming distance contain the single best, which makes it provable.
    var prng = std.Random.DefaultPrng.init(0x1a2b);
    const rand = prng.random();

    for (0..64) |_| {
        var block: [64]RGB = undefined;
        for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

        const cheap = choose(&block, .{ .work = 1 });
        const thorough = choose(&block, .{ .work = 8 });
        const a = score(&block, .{ .cp = cheap.cp, .mask = chosenMask(cheap) }).err;
        const b = score(&block, .{ .cp = thorough.cp, .mask = chosenMask(thorough) }).err;
        try std.testing.expect(b <= a);
    }
}

test "the error from the sums matches the error from the samples" {
    var prng = std.Random.DefaultPrng.init(0x5ca1e);
    const rand = prng.random();

    for (0..8) |_| {
        var block: [64]RGB = undefined;
        for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

        for (table) |g| {
            const s = score(&block, g);
            var naive: u32 = 0;
            for (block, 0..) |p, i| {
                naive += quant.distance(p, if (bitAt(g.mask, i) == 1) s.fg else s.bg);
            }
            try std.testing.expectEqual(naive, s.err);
        }
    }
}

test "the same block always gives the same cell" {
    var prng = std.Random.DefaultPrng.init(0xc311);
    const rand = prng.random();

    var block: [64]RGB = undefined;
    for (&block) |*p| p.* = .{ .r = rand.int(u8), .g = rand.int(u8), .b = rand.int(u8) };

    const a = choose(&block, .{});
    const b = choose(&block, .{});
    try std.testing.expect(std.meta.eql(a, b));
}

test "an empty glyph list falls back to a blank cell" {
    const flat: [64]RGB = @splat(RGB.black);
    const cell = choose(&flat, .{ .glyphs = &.{} });
    try std.testing.expectEqual(@as(u21, ' '), cell.cp);
}
