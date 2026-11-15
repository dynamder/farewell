//! Raymarched solid rendered as truecolour half blocks.

const std = @import("std");
const farewell = @import("farewell");
const Host = @import("host.zig").Host;

const builtin = @import("builtin");

const console = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) i32;

    fn utf8() u32 {
        const previous = GetConsoleOutputCP();
        _ = SetConsoleOutputCP(65001);
        return previous;
    }

    fn restore(cp: u32) void {
        _ = SetConsoleOutputCP(cp);
    }
} else struct {
    fn utf8() u32 {
        return 0;
    }

    fn restore(_: u32) void {}
};

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

const Kind = enum { raymarch, gradient };

const Scene = struct {
    t: f32,
    kind: Kind = .raymarch,

    pub fn sample(self: *const Scene, u: f32, v: f32) farewell.RGB {
        if (self.kind == .gradient) {
            return .{
                .r = @intFromFloat(u * 255.0),
                .g = @intFromFloat(v * 255.0),
                .b = @intFromFloat((1.0 - u) * 200.0),
            };
        }
        return self.march(u, v);
    }

    fn march(self: *const Scene, u: f32, v: f32) farewell.RGB {
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

const mode_count = @typeInfo(farewell.Mode).@"enum".field_names.len;

const Colour = enum { auto, truecolor, indexed256 };

const Dither = enum { off, bayer2, bayer4, bayer8 };

const Options = struct {
    frames: ?usize = null,
    fps: u16 = 60,
    caps: ?[]const u8 = null,
    mode: farewell.Mode = .half,
    colour: Colour = .auto,
    dither: Dither = .off,
    kind: Kind = .raymarch,
    size: farewell.Size = .{ .cols = 80, .rows = 24 },

    fn parse(args: std.process.Args, arena: std.mem.Allocator) ?Options {
        const list = args.toSlice(arena) catch return null;
        var o: Options = .{};
        for (list[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--frames=")) {
                o.frames = std.fmt.parseInt(usize, arg["--frames=".len..], 10) catch return null;
            } else if (std.mem.startsWith(u8, arg, "--fps=")) {
                o.fps = std.fmt.parseInt(u16, arg["--fps=".len..], 10) catch return null;
            } else if (std.mem.startsWith(u8, arg, "--caps=")) {
                o.caps = arg["--caps=".len..];
            } else if (std.mem.startsWith(u8, arg, "--mode=")) {
                o.mode = std.meta.stringToEnum(farewell.Mode, arg["--mode=".len..]) orelse return null;
            } else if (std.mem.startsWith(u8, arg, "--color=")) {
                const v = arg["--color=".len..];
                o.colour = if (std.mem.eql(u8, v, "256"))
                    .indexed256
                else if (std.mem.eql(u8, v, "truecolor"))
                    .truecolor
                else if (std.mem.eql(u8, v, "auto"))
                    .auto
                else
                    return null;
            } else if (std.mem.startsWith(u8, arg, "--dither=")) {
                o.dither = std.meta.stringToEnum(Dither, arg["--dither=".len..]) orelse return null;
            } else if (std.mem.startsWith(u8, arg, "--scene=")) {
                o.kind = std.meta.stringToEnum(Kind, arg["--scene=".len..]) orelse return null;
            } else if (std.mem.startsWith(u8, arg, "--size=")) {
                const v = arg["--size=".len..];
                const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
                o.size = .{
                    .cols = std.fmt.parseInt(u16, v[0..x], 10) catch return null,
                    .rows = std.fmt.parseInt(u16, v[x + 1 ..], 10) catch return null,
                };
            } else return null;
        }
        return o;
    }
};

const Meter = struct {
    frames: usize = 0,
    bytes: usize = 0,
    sgr: usize = 0,
    render_ns: i96 = 0,
    write_ns: i96 = 0,
    late: usize = 0,
};

fn usage() noreturn {
    std.debug.print("usage: raymarch [--frames=N] [--fps=N] [--caps=SPEC] [--mode=NAME] [--color=auto|truecolor|256] [--dither=off|bayer2|bayer4|bayer8] [--size=COLSxROWS] [--scene=raymarch|gradient]\n", .{});
    std.process.exit(2);
}

fn capsEnv(map: *std.process.Environ.Map) farewell.caps.Env {
    const term = map.get("TERM");
    return .{
        .term = term,
        .colorterm = map.get("COLORTERM"),
        .term_program = map.get("TERM_PROGRAM"),
        .wt_session = map.get("WT_SESSION"),
        .lang = map.get("LANG"),
        .multiplexer = map.get("TMUX") != null or
            (term != null and
                (std.mem.startsWith(u8, term.?, "screen") or std.mem.startsWith(u8, term.?, "tmux"))),
    };
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const opts = Options.parse(init.minimal.args, init.arena.allocator()) orelse usage();
    if (opts.colour == .truecolor and opts.dither != .off) usage();

    const saved_codepage = console.utf8();
    defer console.restore(saved_codepage);

    var host = try Host.open(io, opts.size);
    errdefer host.deinit();

    var caps = farewell.caps.resolve(capsEnv(init.environ_map), .{});
    if (opts.caps) |spec| farewell.caps.applySpec(&caps, spec) catch return usage();

    const use_palette = if (opts.dither != .off) true else switch (opts.colour) {
        .indexed256 => true,
        .truecolor => false,
        .auto => !caps.terminal.rgb,
    };
    const quantised = farewell.quant.Fixed{ .table = .xterm256 };
    const bayer2 = farewell.dither.Bayer{ .table = .xterm256, .matrix = .x2 };
    const bayer4 = farewell.dither.Bayer{ .table = .xterm256, .matrix = .x4 };
    const bayer8 = farewell.dither.Bayer{ .table = .xterm256, .matrix = .x8 };

    var presenter = try farewell.Presenter.init(gpa, host.refreshSize(), caps, opts.mode);
    errdefer presenter.deinit();
    presenter.options = .{ .uv = .square };

    var supported: [mode_count]farewell.Mode = undefined;
    var supported_n: usize = 0;
    for (0..mode_count) |i| {
        const want: farewell.Mode = @fromBackingInt(@intCast(i));
        if (farewell.select(caps, want) == want) {
            supported[supported_n] = want;
            supported_n += 1;
        }
    }
    const modes = supported[0..supported_n];

    var at: usize = 0;
    for (modes, 0..) |m, i| {
        if (m == presenter.mode) {
            at = i;
            break;
        }
    }

    const pacing = opts.fps != 0;
    var pacer = farewell.Pacer.init(.{
        .fps = opts.fps,
        .levels = @intCast(modes.len),
        .level = @intCast(at),
    }, caps.terminal.sync_output);

    var meter: Meter = .{};
    var scene: Scene = .{ .t = 0, .kind = opts.kind };
    var paused = false;
    var frame_ns: i96 = if (pacing) @intCast(pacer.budgetNs()) else 0;
    var last = now(io);
    const started = last;

    while (opts.frames == null or meter.frames < opts.frames.?) {
        if (host.readKey()) |k| switch (k) {
            'q', 0x03, 0x1b => break,
            ' ' => paused = !paused,
            '+', '=' => if (at + 1 < modes.len) {
                at += 1;
                presenter.want = modes[at];
                presenter.mode = modes[at];
                pacer.level = @intCast(at);
            },
            '-', '_' => if (at > 0) {
                at -= 1;
                presenter.want = modes[at];
                presenter.mode = modes[at];
                pacer.level = @intCast(at);
            },
            else => {},
        };

        try presenter.resize(host.refreshSize());
        if (!paused) scene.t += @as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s) * 0.7;

        const t0 = now(io);
        const bytes = if (!use_palette)
            try presenter.drawDiff(farewell.sampler(&scene), .{})
        else switch (opts.dither) {
            .off => try presenter.drawDiff(farewell.sampler(&scene), .{&quantised}),
            .bayer2 => try presenter.drawDiff(farewell.sampler(&scene), .{&bayer2}),
            .bayer4 => try presenter.drawDiff(farewell.sampler(&scene), .{&bayer4}),
            .bayer8 => try presenter.drawDiff(farewell.sampler(&scene), .{&bayer8}),
        };
        const t1 = now(io);
        if (bytes.len > 0) try host.write(bytes);
        const t2 = now(io);

        meter.frames += 1;
        meter.bytes += bytes.len;
        meter.sgr += presenter.last.sgr;
        meter.render_ns += t1 - t0;
        meter.write_ns += t2 - t1;

        const spent = t2 - t0;
        if (pacing) {
            const budget: i96 = @intCast(pacer.budgetNs());
            if (spent < budget) {
                std.Io.sleep(io, .{ .nanoseconds = budget - spent }, .awake) catch {};
            } else {
                meter.late += 1;
            }
            switch (pacer.observe(.{ .render_ns = @intCast(t1 - t0), .write_ns = @intCast(t2 - t1) })) {
                .coarser, .finer => {
                    at = pacer.level;
                    presenter.want = modes[at];
                    presenter.mode = modes[at];
                },
                .keep, .slower, .faster => {},
            }
        }

        const seen = now(io);
        frame_ns = seen - last;
        last = seen;
    }

    const size = presenter.size;
    const mode = presenter.mode.name();
    const rate: u16 = if (pacing) pacer.fps else 0;
    presenter.deinit();
    host.deinit();

    const elapsed: f64 = @floatFromInt(now(io) - started);
    const frames: f64 = @floatFromInt(@max(meter.frames, 1));
    const cells: f64 = @as(f64, @floatFromInt(size.cols)) * @as(f64, @floatFromInt(size.rows));

    var description: [512]u8 = undefined;
    std.debug.print("{s}frames {d}  {d:.1} fps  render {d:.2} ms  write {d:.2} ms  {d:.0} bytes/frame  {d:.1} bytes/cell  {d:.0} sgr/frame  mode {s}  {d}x{d}  late {d}  rate {d}  ink {s}\n", .{
        farewell.caps.describe(caps, &description),
        meter.frames,
        frames / (elapsed / @as(f64, std.time.ns_per_s)),
        @as(f64, @floatFromInt(meter.render_ns)) / 1e6 / frames,
        @as(f64, @floatFromInt(meter.write_ns)) / 1e6 / frames,
        @as(f64, @floatFromInt(meter.bytes)) / frames,
        @as(f64, @floatFromInt(meter.bytes)) / frames / cells,
        @as(f64, @floatFromInt(meter.sgr)) / frames,
        mode,
        size.cols,
        size.rows,
        meter.late,
        rate,
        if (use_palette) "256" else "truecolour",
    });
}
