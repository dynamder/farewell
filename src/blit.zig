//! Sub-cell packing: samples to Cell, and the render entry points.

const std = @import("std");
const types = @import("types.zig");
const source = @import("source.zig");

const RGB = types.RGB;
const Cell = types.Cell;
const Grid = types.Grid;
const Mode = types.Mode;

pub const Uv = enum {
    /// (u, v) covers the grid, aspect ignored. Right for images.
    stretch,
    /// (u, v) covers a centred square, aspect corrected by `cell_px`. Right for
    /// procedural scenes that expect a circle to look like a circle.
    square,
};

pub const Options = struct {
    uv: Uv = .stretch,
    /// Physical cell size in pixels. Only used for `.square` uv.
    cell_px: struct { w: u16 = 10, h: u16 = 20 } = .{},
    /// Ink ramp for `.ascii`, light to heavy.
    ramp: []const u8 = " .:-=+*#%@",
    /// Luma cut for dot/quadrant masks.
    threshold: f32 = 0.5,
};

const QUAD: [16]u21 = .{
    ' ',    0x2598, 0x259D, 0x2580,
    0x2596, 0x258C, 0x259E, 0x259B,
    0x2597, 0x259A, 0x2590, 0x259C,
    0x2584, 0x2599, 0x259F, 0x2588,
};

const BAR: [5]u21 = .{ ' ', 0x2582, 0x2584, 0x2586, 0x2588 };

/// Braille dot order inside a sample row-major 2x4 block: (col, row) -> bit.
const BRAILLE_BIT: [8]u3 = .{ 0, 3, 1, 4, 2, 5, 6, 7 };

pub fn pack(comptime mode: Mode, s: []const RGB, o: Options) Cell {
    return switch (mode) {
        .ascii => packAscii(s[0], o),
        .bars => packBars(s, o),
        .half => .{ .cp = 0x2580, .fg = s[0], .bg = s[1] },
        .quad => packSplit(s, 4, o, true),
        .sextant => packSplit(s, 6, o, false),
        .braille => packBraille(s, o),
    };
}

fn toIdx(l: f32, n: usize) usize {
    const f = std.math.clamp(l, 0.0, 0.9999);
    return @intFromFloat(f * @as(f32, @floatFromInt(n)));
}

fn packAscii(c: RGB, o: Options) Cell {
    if (o.ramp.len == 0) return .{ .cp = ' ', .fg = c };
    const i = toIdx(c.luma(), o.ramp.len);
    return .{ .cp = o.ramp[i], .fg = c };
}

fn packBars(s: []const RGB, o: Options) Cell {
    var lit: usize = 0;
    var sum: [3]u32 = .{ 0, 0, 0 };
    for (s) |c| {
        if (c.luma() > o.threshold) {
            lit += 1;
            sum[0] += c.r;
            sum[1] += c.g;
            sum[2] += c.b;
        }
    }
    const n: u32 = @intCast(s.len);
    const avg = if (lit > 0)
        RGB{ .r = @intCast(sum[0] / @as(u32, @intCast(lit))), .g = @intCast(sum[1] / @as(u32, @intCast(lit))), .b = @intCast(sum[2] / @as(u32, @intCast(lit))) }
    else
        RGB.black;
    const level = toIdx(@as(f32, @floatFromInt(lit)) / @as(f32, @floatFromInt(n)), 5);
    return .{ .cp = BAR[level], .fg = avg };
}

/// Two-colour split: brightest sample becomes fg, darkest becomes bg, and every
/// sample above the midpoint is inked. Works for quadrant (4) and sextant (6).
fn packSplit(s: []const RGB, comptime n: usize, o: Options, comptime is_quad: bool) Cell {
    _ = o;
    var lo: usize = 0;
    var hi: usize = 0;
    var lmin: f32 = 2.0;
    var lmax: f32 = -1.0;
    inline for (0..n) |i| {
        const l = s[i].luma();
        if (l < lmin) {
            lmin = l;
            lo = i;
        }
        if (l > lmax) {
            lmax = l;
            hi = i;
        }
    }
    const thr = (lmin + lmax) * 0.5;
    var mask: u8 = 0;
    inline for (0..n) |i| {
        if (s[i].luma() > thr) mask |= @as(u8, 1) << @intCast(i);
    }
    const cp: u21 = if (is_quad)
        QUAD[mask]
    else if (mask == 0)
        ' '
    else
        @as(u21, 0x1FB00) + @as(u21, mask) - 1;
    return .{ .cp = cp, .fg = s[hi], .bg = s[lo] };
}

fn packBraille(s: []const RGB, o: Options) Cell {
    var mask: u8 = 0;
    var sum: [3]u32 = .{ 0, 0, 0 };
    for (s, 0..) |c, i| {
        if (c.luma() > o.threshold) mask |= @as(u8, 1) << BRAILLE_BIT[i];
        sum[0] += c.r;
        sum[1] += c.g;
        sum[2] += c.b;
    }
    const n: u32 = @intCast(s.len);
    return .{
        .cp = @as(u21, 0x2800) + @as(u21, mask),
        .fg = .{ .r = @intCast(sum[0] / n), .g = @intCast(sum[1] / n), .b = @intCast(sum[2] / n) },
        .bg = RGB.black,
    };
}

/// True when `T` (or the type it points at) can receive cells: it declares
/// `size() Size` and `put(x, y, Cell)`.
pub fn isSink(comptime T: type) bool {
    const U = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    return switch (@typeInfo(U)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(U, "size") and @hasDecl(U, "put"),
        else => false,
    };
}

/// Renders `src` into any sink: a `Grid`, or a foreign cell container that
/// declares `size() Size` and `put(x, y, Cell)`. `mode` is comptime so the
/// sample count, the packing and the whole loop body specialise away.
pub fn render(src: anytype, comptime mode: Mode, sink: anytype, o: Options) void {
    comptime if (!source.isSource(@TypeOf(src)))
        @compileError("render(): source must provide at(u, v) RGB");
    comptime if (!isSink(@TypeOf(sink)))
        @compileError("render(): sink must provide size() Size and put(x, y, Cell)");

    const size = sink.size();
    const w: u32 = size.cols;
    const h: u32 = size.rows;

    const d = mode.density();
    const nx: usize = d.nx;
    const ny: usize = d.ny;

    const pw: f32 = @floatFromInt(w * o.cell_px.w);
    const ph: f32 = @floatFromInt(h * o.cell_px.h);
    const side: f32 = @max(pw, ph);
    const offx: f32 = (side - pw) * 0.5;
    const offy: f32 = (side - ph) * 0.5;
    const cw: f32 = @floatFromInt(o.cell_px.w);
    const ch: f32 = @floatFromInt(o.cell_px.h);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var samples: [8]RGB = @splat(RGB.black);
            var sy: usize = 0;
            while (sy < ny) : (sy += 1) {
                var sx: usize = 0;
                while (sx < nx) : (sx += 1) {
                    const px = (@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(nx))) * cw;
                    const py = (@as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(ny))) * ch;
                    var u: f32 = undefined;
                    var v: f32 = undefined;
                    switch (o.uv) {
                        .stretch => {
                            u = px / pw;
                            v = py / ph;
                        },
                        .square => {
                            u = (px + offx) / side;
                            v = (py + offy) / side;
                        },
                    }
                    samples[sy * nx + sx] = src.at(u, v);
                }
            }
            sink.put(@intCast(x), @intCast(y), pack(mode, samples[0 .. nx * ny], o));
        }
    }
}

/// Runtime mode dispatch: `inline else` turns each branch back into the comptime
/// version, so this stays zero-cost while the API can take a mode from caps.
pub fn renderAny(src: anytype, mode: Mode, sink: anytype, o: Options) void {
    switch (mode) {
        inline else => |m| render(src, m, sink, o),
    }
}

const Solid = struct {
    color: RGB,
    pub fn sample(self: *const Solid, _: f32, _: f32) RGB {
        return self.color;
    }
};

test "half packs top into fg and bottom into bg" {
    const top = RGB{ .r = 10, .g = 20, .b = 30 };
    const bot = RGB{ .r = 40, .g = 50, .b = 60 };
    const cell = pack(.half, &.{ top, bot }, .{});
    try std.testing.expectEqual(@as(u21, 0x2580), cell.cp);
    try std.testing.expect(cell.fg.eql(top));
    try std.testing.expect(cell.bg.eql(bot));
}

test "ascii ramp hits both ends" {
    try std.testing.expectEqual(@as(u21, ' '), pack(.ascii, &.{RGB.black}, .{}).cp);
    try std.testing.expectEqual(@as(u21, '@'), pack(.ascii, &.{RGB.white}, .{}).cp);
}

test "braille fills and empties" {
    try std.testing.expectEqual(@as(u21, 0x2800), pack(.braille, &@as([8]RGB, @splat(RGB.black)), .{}).cp);
    try std.testing.expectEqual(@as(u21, 0x28FF), pack(.braille, &@as([8]RGB, @splat(RGB.white)), .{}).cp);
}

test "quad and sextant pick two colours" {
    const dark = RGB.black;
    const bright = RGB.white;
    const q = pack(.quad, &.{ bright, dark, dark, dark }, .{});
    try std.testing.expectEqual(@as(u21, 0x2598), q.cp);
    try std.testing.expect(q.fg.eql(bright));
    try std.testing.expect(q.bg.eql(dark));

    const s = pack(.sextant, &.{ bright, dark, dark, dark, dark, dark }, .{});
    try std.testing.expectEqual(@as(u21, 0x1FB00), s.cp);
}

test "render fills a grid from a sampler" {
    var scene = Solid{ .color = RGB.white };
    var g = try Grid.init(std.testing.allocator, 3, 2);
    defer g.deinit(std.testing.allocator);

    render(source.sampler(&scene), .half, &g, .{});
    for (g.cells) |c| {
        try std.testing.expectEqual(@as(u21, 0x2580), c.cp);
        try std.testing.expect(c.fg.eql(RGB.white));
    }
}

test "renderAny matches render" {
    const pix = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9 };
    const f = source.Frame.init(2, 2, &pix, .rgb8);
    var a = try Grid.init(std.testing.allocator, 2, 2);
    defer a.deinit(std.testing.allocator);
    var b = try Grid.init(std.testing.allocator, 2, 2);
    defer b.deinit(std.testing.allocator);

    render(&f, .braille, &a, .{});
    renderAny(&f, .braille, &b, .{});
    for (a.cells, b.cells) |x, y| try std.testing.expectEqual(x.cp, y.cp);
}

/// A sink that is not a `Grid`, shaped like the adapter a TUI host would write.
const Plain = struct {
    w: u16,
    h: u16,
    cells: [16]Cell,

    pub fn size(self: Plain) types.Size {
        return .{ .cols = self.w, .rows = self.h };
    }

    pub fn put(self: *Plain, x: u16, y: u16, c: Cell) void {
        self.cells[@as(usize, y) * self.w + x] = c;
    }
};

test "a foreign sink receives the same cells as the grid" {
    const pix = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9, 30, 60, 90, 120, 150, 180 };
    const f = source.Frame.init(3, 2, &pix, .rgb8);
    var g = try Grid.init(std.testing.allocator, 3, 2);
    defer g.deinit(std.testing.allocator);
    var p = Plain{ .w = 3, .h = 2, .cells = undefined };

    render(&f, .quad, &g, .{ .uv = .square });
    render(&f, .quad, &p, .{ .uv = .square });

    for (g.cells, 0..) |c, i| try std.testing.expect(std.meta.eql(c, p.cells[i]));
}

test "isSink accepts the grid and rejects plain values" {
    try std.testing.expect(isSink(Grid));
    try std.testing.expect(isSink(*Grid));
    try std.testing.expect(isSink(Plain));
    try std.testing.expect(!isSink(u32));
    try std.testing.expect(!isSink(*const source.Frame));
}
