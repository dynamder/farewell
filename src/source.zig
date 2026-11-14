//! Pixel sources: concrete frames and procedural samplers.

const std = @import("std");
const types = @import("types.zig");
const RGB = types.RGB;

pub const Fmt = enum { rgb8, rgba8, gray8 };

fn bytesPerPixel(fmt: Fmt) usize {
    return switch (fmt) {
        .rgb8 => 3,
        .rgba8 => 4,
        .gray8 => 1,
    };
}

/// A concrete pixel buffer, rows top-down. `uv` is clamped to [0, 1).
pub const Frame = struct {
    w: u32,
    h: u32,
    stride: usize,
    pix: []const u8,
    fmt: Fmt = .rgb8,

    pub fn init(w: u32, h: u32, pix: []const u8, fmt: Fmt) Frame {
        return .{ .w = w, .h = h, .stride = @as(usize, w) * bytesPerPixel(fmt), .pix = pix, .fmt = fmt };
    }

    /// Nearest neighbour for M0. Bilinear arrives with the scaling work.
    pub fn at(f: *const Frame, u: f32, v: f32) RGB {
        if (f.w == 0 or f.h == 0) return RGB.black;
        const xf = std.math.clamp(u, 0.0, 0.999_999) * @as(f32, @floatFromInt(f.w));
        const yf = std.math.clamp(v, 0.0, 0.999_999) * @as(f32, @floatFromInt(f.h));
        const x: u32 = @intFromFloat(xf);
        const y: u32 = @intFromFloat(yf);
        const off = @as(usize, y) * f.stride + @as(usize, x) * bytesPerPixel(f.fmt);
        return switch (f.fmt) {
            .rgb8 => .{ .r = f.pix[off], .g = f.pix[off + 1], .b = f.pix[off + 2] },
            .rgba8 => .{ .r = f.pix[off], .g = f.pix[off + 1], .b = f.pix[off + 2] },
            .gray8 => .{ .r = f.pix[off], .g = f.pix[off], .b = f.pix[off] },
        };
    }
};

/// A procedural source: the callee decides what (u, v) means. No frame buffer.
pub const Sampler = struct {
    ctx: *const anyopaque,
    call: *const fn (ctx: *const anyopaque, u: f32, v: f32) RGB,

    pub inline fn at(s: Sampler, u: f32, v: f32) RGB {
        return s.call(s.ctx, u, v);
    }
};

/// Wrap `&thing` into a Sampler, where `thing` declares
/// `pub fn sample(self: *const T, u: f32, v: f32) RGB`.
pub fn sampler(ptr: anytype) Sampler {
    const P = @TypeOf(ptr);
    const info = @typeInfo(P);
    if (info != .pointer) @compileError("sampler() wants a pointer; pass &scene");
    const T = info.pointer.child;

    const Binder = struct {
        fn call(ctx: *const anyopaque, u: f32, v: f32) RGB {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return self.sample(u, v);
        }
    };
    return .{ .ctx = @ptrCast(ptr), .call = Binder.call };
}

/// True when `T` (or the type it points at) exposes `at(u, v) RGB`.
pub fn isSource(comptime T: type) bool {
    const U = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    return switch (@typeInfo(U)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(U, "at"),
        else => false,
    };
}

const TestScene = struct {
    pub fn sample(_: *const TestScene, u: f32, v: f32) RGB {
        return .{
            .r = @intFromFloat(u * 255.0),
            .g = @intFromFloat(v * 255.0),
            .b = 64,
        };
    }
};

test "frame samples corners and clamps" {
    const pix = [_]u8{
        255, 0, 0,   0,   255, 0,
        0,   0, 255, 255, 255, 255,
    };
    var f = Frame.init(2, 2, &pix, .rgb8);
    try std.testing.expect(f.at(0.0, 0.0).eql(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expect(f.at(0.99, 0.0).eql(.{ .r = 0, .g = 255, .b = 0 }));
    try std.testing.expect(f.at(0.0, 0.99).eql(.{ .r = 0, .g = 0, .b = 255 }));
    try std.testing.expect(f.at(5.0, 5.0).eql(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expect(f.at(-1.0, -1.0).eql(.{ .r = 255, .g = 0, .b = 0 }));
}

test "sampler binder reaches the scene" {
    const scene = TestScene{};
    const s = sampler(&scene);
    const c = s.at(0.5, 0.25);
    try std.testing.expectEqual(@as(u8, 127), c.r);
    try std.testing.expectEqual(@as(u8, 63), c.g);
    try std.testing.expectEqual(@as(u8, 64), c.b);
}

test "isSource accepts frame and sampler" {
    try std.testing.expect(isSource(Frame));
    try std.testing.expect(isSource(*const Frame));
    try std.testing.expect(isSource(Sampler));
    try std.testing.expect(!isSource(u32));
}
