//! Raymarched solid rendered as truecolour half blocks.

const std = @import("std");
const farewell = @import("farewell");

const V3 = @Vector(3, f32);

fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}

fn norm(a: V3) V3 {
    return a / @as(V3, @splat(@sqrt(dot(a, a))));
}

/// Rounded box, rotated about Y, with a sphere scooped out of it.
fn sdf(p: V3, t: f32) f32 {
    const c = @cos(t * 0.7);
    const s = @sin(t * 0.7);
    const q = V3{ c * p[0] - s * p[2], p[1], s * p[0] + c * p[2] };
    const b = @as(V3, @splat(0.62));
    const d = @abs(q) - b;
    const outside = @max(d, @as(V3, @splat(0.0)));
    const box = @sqrt(dot(outside, outside)) + @min(@max(d[0], @max(d[1], d[2])), 0.0) - 0.08;
    const sphere = @sqrt(dot(p, p)) - 0.72;
    return @max(box, -sphere);
}

fn normal(p: V3, t: f32) V3 {
    const e: V3 = @splat(0.002);
    return norm(V3{
        sdf(p + V3{ e[0], 0, 0 }, t) - sdf(p - V3{ e[0], 0, 0 }, t),
        sdf(p + V3{ 0, e[1], 0 }, t) - sdf(p - V3{ 0, e[1], 0 }, t),
        sdf(p + V3{ 0, 0, e[2] }, t) - sdf(p - V3{ 0, 0, e[2] }, t),
    });
}

const Scene = struct {
    t: f32,

    pub fn sample(self: *const Scene, u: f32, v: f32) farewell.RGB {
        const ro = V3{ 0, 0, -4.0 };
        const rd = norm(V3{ (u - 0.5) * 1.45, (0.5 - v) * 1.45, 1.0 });

        var dist: f32 = 0;
        var p: V3 = ro;
        var i: usize = 0;
        while (i < 48) : (i += 1) {
            p = ro + rd * @as(V3, @splat(dist));
            const d = sdf(p, self.t);
            if (d < 0.002 or dist > 12) break;
            dist += d;
        }

        if (dist >= 12) {
            const g = 0.10 + 0.55 * (1.0 - v) * (1.0 - v);
            return farewell.RGB{
                .r = @intFromFloat(g * 90.0),
                .g = @intFromFloat(g * 120.0),
                .b = @intFromFloat(g * 190.0),
            };
        }

        const n = normal(p, self.t);
        const light = norm(V3{ @sin(self.t * 1.3) * 1.5, 1.0, -1.0 });
        const diff = @max(dot(n, light), 0.0);
        const fog = std.math.clamp(1.0 - dist / 16.0, 0.0, 1.0);
        const lum = (0.25 + 0.75 * diff) * fog;
        const rim = std.math.clamp(1.0 - @max(dot(n, V3{ 0, 0, -1 }), 0.0), 0.0, 1.0);
        const spec = std.math.pow(f32, @max(dot(n, norm(light + V3{ 0, 0, -1 })), 0.0), 32.0);

        const k = std.math.clamp(lum * lum, 0.0, 1.0);
        const cold = V3{ 0.10, 0.22, 0.55 };
        const warm = V3{ 0.98, 0.86, 0.62 };
        const c = cold * @as(V3, @splat(1.0 - k)) + warm * @as(V3, @splat(k)) +
            @as(V3, @splat(0.35 * rim)) + @as(V3, @splat(0.9 * spec));

        return farewell.RGB{
            .r = @intFromFloat(std.math.clamp(c[0], 0.0, 1.0) * 255.0),
            .g = @intFromFloat(std.math.clamp(c[1], 0.0, 1.0) * 255.0),
            .b = @intFromFloat(std.math.clamp(c[2], 0.0, 1.0) * 255.0),
        };
    }
};

pub fn main() !void {
    const w: u16 = 120;
    const h: u16 = 36;
    const frames: usize = 3;

    var grid = try farewell.Grid.init(std.heap.page_allocator, w, h);
    defer grid.deinit(std.heap.page_allocator);

    const buf = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(buf);

    var scene = Scene{ .t = 0 };

    var f: usize = 0;
    while (f < frames) : (f += 1) {
        scene.t = @as(f32, @floatFromInt(f)) * 0.45;
        farewell.render(farewell.sampler(&scene), .half, &grid, .{ .uv = .square });
        const st = try farewell.emit(&grid, buf, .{});
        std.debug.print("{s}", .{buf[0..st.bytes]});
    }
}
