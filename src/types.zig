//! Core value types: colour, cell, grid, blitter density.

const std = @import("std");

/// 24-bit colour.
pub const RGB = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const black: RGB = .{};
    pub const white: RGB = .{ .r = 255, .g = 255, .b = 255 };

    pub fn eql(a: RGB, b: RGB) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// Rec.709 luma in [0, 1].
    pub fn luma(c: RGB) f32 {
        return (@as(f32, @floatFromInt(c.r)) * 0.2126 +
            @as(f32, @floatFromInt(c.g)) * 0.7152 +
            @as(f32, @floatFromInt(c.b)) * 0.0722) / 255.0;
    }

    /// Linear blend, `t` clamped to [0, 1].
    pub fn mix(a: RGB, b: RGB, t: f32) RGB {
        const k = std.math.clamp(t, 0.0, 1.0);
        const inv = 1.0 - k;
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * inv + @as(f32, @floatFromInt(b.r)) * k),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * inv + @as(f32, @floatFromInt(b.g)) * k),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * inv + @as(f32, @floatFromInt(b.b)) * k),
        };
    }

    /// Multiply by `k`, clamped.
    pub fn scale(c: RGB, k: f32) RGB {
        const f = std.math.clamp(k, 0.0, 1.0);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c.r)) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(c.g)) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(c.b)) * f),
        };
    }
};

pub const Attr = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strike: bool = false,
    _pad: u1 = 0,

    pub const none: Attr = .{};
    pub fn any(a: Attr) bool {
        return @as(u8, @bitCast(a)) != 0;
    }
};

/// One terminal cell. `cp` is a codepoint, not a string: M0 only emits
/// single-codepoint glyphs (blocks, braille, ascii ramp).
///
/// `cp` is a `u21`, so the struct carries undefined padding: compare cells field
/// by field, never by hashing or comparing their bytes.
pub const Cell = struct {
    cp: u21 = ' ',
    fg: RGB = .{ .r = 200, .g = 200, .b = 200 },
    bg: RGB = .black,
    attr: Attr = .{},
};

/// Samples taken per cell, horizontally and vertically.
pub const Dims = struct {
    nx: u3,
    ny: u3,

    pub fn samples(d: Dims) u4 {
        return @as(u4, d.nx) * @as(u4, d.ny);
    }
};

pub const Mode = enum {
    /// 1x1 — ink coverage via an ascii ramp.
    ascii,
    /// 1x4 — eight vertical bars (half of the block ladder).
    bars,
    /// 1x2 — upper half block, fg above bg. The default workhorse.
    half,
    /// 2x2 — quadrant blocks.
    quad,
    /// 2x3 — legacy computing sextants (needs a font that has them).
    sextant,
    /// 2x4 — braille dots. Denser than sextant and far better supported.
    braille,

    pub fn density(m: Mode) Dims {
        return switch (m) {
            .ascii => .{ .nx = 1, .ny = 1 },
            .bars => .{ .nx = 1, .ny = 4 },
            .half => .{ .nx = 1, .ny = 2 },
            .quad => .{ .nx = 2, .ny = 2 },
            .sextant => .{ .nx = 2, .ny = 3 },
            .braille => .{ .nx = 2, .ny = 4 },
        };
    }

    pub fn name(m: Mode) []const u8 {
        return @tagName(m);
    }
};

/// Grid dimensions in cells.
pub const Size = struct { cols: u16, rows: u16 };

/// A cell buffer.
pub const Grid = struct {
    w: u16,
    h: u16,
    cells: []Cell,

    pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !Grid {
        const n = @as(usize, w) * @as(usize, h);
        const cells = try alloc.alloc(Cell, n);
        @memset(cells, Cell{});
        return .{ .w = w, .h = h, .cells = cells };
    }

    pub fn deinit(self: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        self.* = undefined;
    }

    pub fn fill(self: *Grid, c: Cell) void {
        @memset(self.cells, c);
    }

    pub fn size(self: Grid) Size {
        return .{ .cols = self.w, .rows = self.h };
    }

    pub fn at(self: *Grid, x: u16, y: u16) *Cell {
        return &self.cells[@as(usize, y) * self.w + x];
    }

    /// Copies `c` into the cell at (x, y).
    pub fn put(self: *Grid, x: u16, y: u16, c: Cell) void {
        self.at(x, y).* = c;
    }

    /// Read-only access for callers holding a `*const Grid`.
    pub fn get(self: *const Grid, x: u16, y: u16) Cell {
        return self.cells[@as(usize, y) * self.w + x];
    }
};

test "mode density ladder" {
    try std.testing.expectEqual(@as(u4, 1), Mode.ascii.density().samples());
    try std.testing.expectEqual(@as(u4, 2), Mode.half.density().samples());
    try std.testing.expectEqual(@as(u4, 4), Mode.quad.density().samples());
    try std.testing.expectEqual(@as(u4, 6), Mode.sextant.density().samples());
    try std.testing.expectEqual(@as(u4, 8), Mode.braille.density().samples());
}

test "rgb luma and mix" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), RGB.black.luma(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), RGB.white.luma(), 1e-6);
    const mid = RGB.mix(RGB.black, RGB.white, 0.5);
    try std.testing.expectEqual(@as(u8, 127), mid.r);
    try std.testing.expect(RGB.mix(RGB.black, RGB.white, 2.0).eql(RGB.white));
}

test "grid indexing and fill" {
    var g = try Grid.init(std.testing.allocator, 4, 3);
    defer g.deinit(std.testing.allocator);
    g.fill(.{ .cp = 'x' });
    g.at(3, 2).*.cp = 'y';
    try std.testing.expectEqual(@as(u21, 'x'), g.cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'y'), g.at(3, 2).cp);
    try std.testing.expectEqual(@as(usize, 12), g.cells.len);
}
