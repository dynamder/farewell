//! Sub-cell packing: samples to Cell, and the render entry points.

const std = @import("std");
const types = @import("types.zig");
const source = @import("source.zig");
const ink = @import("ink.zig");

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
    /// Table and budget for `.ink`.
    ink: ink.Options = .{},
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
        .ink => ink.choose(.x8, s[0..64], o.ink),
        .ink16 => ink.choose(.tall, s[0..128], o.ink),
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

/// True when `T` (or the type it points at) can fill a whole row of samples at
/// once, through `rowAt(us, v, out) bool`.
pub fn hasRow(comptime T: type) bool {
    const U = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    return switch (@typeInfo(U)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(U, "rowAt"),
        else => false,
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

/// Grid-to-uv mapping for one render; nothing in here changes per cell.
const Geometry = struct {
    cw: f32,
    ch: f32,
    pw: f32,
    ph: f32,
    side: f32,
    offx: f32,
    offy: f32,

    fn init(size: types.Size, o: Options) Geometry {
        const pw: f32 = @floatFromInt(@as(u32, size.cols) * o.cell_px.w);
        const ph: f32 = @floatFromInt(@as(u32, size.rows) * o.cell_px.h);
        const side: f32 = @max(pw, ph);
        return .{
            .cw = @floatFromInt(o.cell_px.w),
            .ch = @floatFromInt(o.cell_px.h),
            .pw = pw,
            .ph = ph,
            .side = side,
            .offx = (side - pw) * 0.5,
            .offy = (side - ph) * 0.5,
        };
    }

    /// Samples one cell and packs it. `mode` and `uv` are comptime, so the
    /// sample count, the uv mapping and the packing all fold away.
    inline fn cell(self: Geometry, src: anytype, comptime mode: Mode, comptime uv: Uv, o: Options, x: usize, y: usize) Cell {
        const d = comptime mode.density();
        const nx: usize = d.nx;
        const ny: usize = d.ny;

        const n: usize = @as(usize, d.nx) * @as(usize, d.ny);
        var samples: [n]RGB = @splat(RGB.black);
        inline for (0..ny) |sy| {
            const py = (@as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(ny))) * self.ch;
            const v: f32 = switch (uv) {
                .stretch => py / self.ph,
                .square => (py + self.offy) / self.side,
            };

            // The u values for this row are computed once, so the row hook and
            // the one-at-a-time path feed the source the same numbers.
            var us: [nx]f32 = undefined;
            inline for (0..nx) |sx| {
                const px = (@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(nx))) * self.cw;
                us[sx] = switch (uv) {
                    .stretch => px / self.pw,
                    .square => (px + self.offx) / self.side,
                };
            }

            const row = samples[sy * nx ..][0..nx];
            const filled = if (comptime hasRow(@TypeOf(src))) src.rowAt(us[0..], v, row) else false;
            if (!filled) {
                inline for (0..nx) |sx| row[sx] = src.at(us[sx], v);
            }
        }
        return pack(mode, samples[0..n], o);
    }
};

/// Renders `src` into any sink: a `Grid`, or a foreign cell container that
/// declares `size() Size` and `put(x, y, Cell)`. `mode` is comptime and `uv` is
/// split into its own instantiation, so the sampling loop carries no branch.
pub fn render(src: anytype, comptime mode: Mode, sink: anytype, o: Options) void {
    comptime if (!source.isSource(@TypeOf(src)))
        @compileError("render(): source must provide at(u, v) RGB");
    comptime if (!isSink(@TypeOf(sink)))
        @compileError("render(): sink must provide size() Size and put(x, y, Cell)");

    switch (o.uv) {
        inline else => |uv| renderUv(src, mode, sink, o, uv),
    }
}

fn renderUv(src: anytype, comptime mode: Mode, sink: anytype, o: Options, comptime uv: Uv) void {
    const size = sink.size();
    const geo = Geometry.init(size, o);

    for (0..size.rows) |y| {
        for (0..size.cols) |x| {
            sink.put(@intCast(x), @intCast(y), geo.cell(src, mode, uv, o, x, y));
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

test "ink packs a two colour block as the block that matches it" {
    var s: [64]RGB = undefined;
    for (0..64) |i| s[i] = if (i / 8 >= 4) RGB.white else RGB.black;

    const cell = pack(.ink, &s, .{});
    try std.testing.expectEqual(@as(u21, 0x2584), cell.cp);
    try std.testing.expect(cell.fg.eql(RGB.white));
    try std.testing.expect(cell.bg.eql(RGB.black));
}

var row_calls: usize = 0;

fn encode(u: f32, v: f32) RGB {
    return .{
        .r = @intFromFloat(u * 255.0),
        .g = @intFromFloat(v * 255.0),
        .b = 7,
    };
}

const ScalarScene = struct {
    pub fn sample(_: *const ScalarScene, u: f32, v: f32) RGB {
        return encode(u, v);
    }
};

/// The same colours, computed four lanes at a time, to stand in for a scene
/// that marches several rays per vector.
const RowScene = struct {
    pub fn sample(_: *const RowScene, u: f32, v: f32) RGB {
        return encode(u, v);
    }

    pub fn row(_: *const RowScene, us: []const f32, v: f32, out: []RGB) void {
        row_calls += 1;
        var i: usize = 0;
        while (i + 4 <= us.len) : (i += 4) {
            const lane: @Vector(4, f32) = us[i..][0..4].*;
            const r = lane * @as(@Vector(4, f32), @splat(255.0));
            inline for (0..4) |k| out[i + k] = .{ .r = @intFromFloat(r[k]), .g = @intFromFloat(v * 255.0), .b = 7 };
        }
        while (i < us.len) : (i += 1) out[i] = encode(us[i], v);
    }
};

test "a row hook gives the same cells as one sample at a time" {
    const scalar = ScalarScene{};
    const rowed = RowScene{};

    inline for ([_]Mode{ .half, .braille, .ink }) |mode| {
        var a = try Grid.init(std.testing.allocator, 5, 3);
        defer a.deinit(std.testing.allocator);
        var b = try Grid.init(std.testing.allocator, 5, 3);
        defer b.deinit(std.testing.allocator);

        row_calls = 0;
        render(source.sampler(&scalar), mode, &a, .{ .uv = .square });
        try std.testing.expectEqual(@as(usize, 0), row_calls);

        render(source.sampler(&rowed), mode, &b, .{ .uv = .square });
        try std.testing.expect(row_calls > 0);

        for (a.cells, b.cells) |x, y| {
            try std.testing.expectEqual(x.cp, y.cp);
            try std.testing.expect(x.fg.eql(y.fg));
            try std.testing.expect(x.bg.eql(y.bg));
        }
    }
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

test "render walks all 64 samples in ink mode" {
    // A flat frame must come out flat: blank glyph, both colours the same. This
    // is the only test that runs the 8x8 sampling loop end to end.
    var pix: [8 * 8 * 3]u8 = undefined;
    @memset(&pix, 200);
    const f = source.Frame.init(8, 8, &pix, .rgb8);

    var g = try Grid.init(std.testing.allocator, 1, 1);
    defer g.deinit(std.testing.allocator);

    render(&f, .ink, &g, .{});
    try std.testing.expectEqual(@as(u21, ' '), g.cells[0].cp);
    try std.testing.expectEqual(@as(u8, 200), g.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 200), g.cells[0].bg.r);
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
