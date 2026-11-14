//! Terminal and font capabilities, with provenance.

const std = @import("std");
const types = @import("types.zig");

const Mode = types.Mode;

pub const Source = enum { default, env, probe, override };

pub const Terminal = struct {
    rgb: bool = false,
    indexed256: bool = true,
    sixel: bool = false,
    kitty_graphics: bool = false,
    sync_output: bool = false,
};

pub const Font = struct {
    utf8: bool = true,
    braille: bool = true,
    quadrant: bool = true,
    sextant: bool = false,
    octant: bool = false,
};

/// What the terminal itself reported. `null` means the probe could not tell —
/// distinct from a reported `false`.
pub const Probe = struct {
    rgb: ?bool = null,
    sixel: ?bool = null,
    kitty_graphics: ?bool = null,
    sync_output: ?bool = null,
};

pub const Env = struct {
    term: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    wt_session: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    multiplexer: bool = false,
};

pub const Signals = struct {
    rgb: ?bool = null,
    kitty_graphics: ?bool = null,
    sixel: ?bool = null,
    utf8: ?bool = null,
};

pub const Origins = struct {
    terminal: std.enums.EnumArray(std.meta.FieldEnum(Terminal), Source) =
        std.enums.EnumArray(std.meta.FieldEnum(Terminal), Source).initFill(.default),
    font: std.enums.EnumArray(std.meta.FieldEnum(Font), Source) =
        std.enums.EnumArray(std.meta.FieldEnum(Font), Source).initFill(.default),
};

pub const Caps = struct {
    terminal: Terminal = .{},
    font: Font = .{},
    origins: Origins = .{},

    pub fn terminalSource(c: Caps, field: std.meta.FieldEnum(Terminal)) Source {
        return c.origins.terminal.get(field);
    }

    pub fn fontSource(c: Caps, field: std.meta.FieldEnum(Font)) Source {
        return c.origins.font.get(field);
    }
};

const Pick = struct { value: bool, source: Source };

/// The only sources that can be ranked. `default` and `override` are not
/// ranked: they sit at the ends.
const Rank = enum { env, probe };

fn sourceOf(r: Rank) Source {
    return switch (r) {
        .env => .env,
        .probe => .probe,
    };
}

fn pick(comptime rank: [2]Rank, override: ?bool, from_env: ?bool, from_probe: ?bool, fallback: bool) Pick {
    if (override) |v| return .{ .value = v, .source = .override };
    inline for (rank) |r| {
        const v: ?bool = switch (r) {
            .env => from_env,
            .probe => from_probe,
        };
        if (v) |b| return .{ .value = b, .source = sourceOf(r) };
    }
    return .{ .value = fallback, .source = .default };
}

fn set(
    comptime T: type,
    origins: *std.enums.EnumArray(std.meta.FieldEnum(T), Source),
    comptime field: std.meta.FieldEnum(T),
    storage: *T,
    p: Pick,
) void {
    @field(storage, @tagName(field)) = p.value;
    origins.set(field, p.source);
}

pub fn resolve(env: Env, probe: Probe) Caps {
    return if (env.multiplexer)
        rankOrder(.{ .probe, .env }, env, probe)
    else
        rankOrder(.{ .env, .probe }, env, probe);
}

fn rankOrder(comptime rank: [2]Rank, env: Env, probe: Probe) Caps {
    const sig = signals(env);
    const d = Caps{};
    var caps = d;

    set(Terminal, &caps.origins.terminal, .rgb, &caps.terminal, pick(rank, null, sig.rgb, probe.rgb, d.terminal.rgb));
    set(Terminal, &caps.origins.terminal, .indexed256, &caps.terminal, pick(rank, null, null, null, d.terminal.indexed256));
    set(Terminal, &caps.origins.terminal, .sixel, &caps.terminal, pick(rank, null, sig.sixel, probe.sixel, d.terminal.sixel));
    set(Terminal, &caps.origins.terminal, .kitty_graphics, &caps.terminal, pick(rank, null, sig.kitty_graphics, probe.kitty_graphics, d.terminal.kitty_graphics));
    set(Terminal, &caps.origins.terminal, .sync_output, &caps.terminal, pick(rank, null, null, probe.sync_output, d.terminal.sync_output));

    set(Font, &caps.origins.font, .utf8, &caps.font, pick(rank, null, sig.utf8, null, d.font.utf8));
    set(Font, &caps.origins.font, .braille, &caps.font, pick(rank, null, null, null, d.font.braille));
    set(Font, &caps.origins.font, .quadrant, &caps.font, pick(rank, null, null, null, d.font.quadrant));
    set(Font, &caps.origins.font, .sextant, &caps.font, pick(rank, null, null, null, d.font.sextant));
    set(Font, &caps.origins.font, .octant, &caps.font, pick(rank, null, null, null, d.font.octant));

    return caps;
}

pub fn signals(env: Env) Signals {
    var s = Signals{};

    if (env.colorterm) |v| {
        if (eqlAny(v, &.{ "truecolor", "24bit" })) s.rgb = true;
    }
    if (env.term) |v| {
        if (std.mem.find(u8, v, "kitty") != null) {
            s.kitty_graphics = true;
            s.rgb = true;
        }
    }
    if (env.term_program) |v| {
        if (eqlAny(v, &.{ "ghostty", "WezTerm" })) s.kitty_graphics = true;
    }
    if (env.wt_session != null) {
        s.sixel = true;
        s.rgb = true;
    }
    if (env.lang) |v| {
        if (!isUtf8Locale(v)) s.utf8 = false;
    }
    return s;
}

fn eqlAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.eql(u8, haystack, n)) return true;
    }
    return false;
}

fn isUtf8Locale(v: []const u8) bool {
    return std.mem.find(u8, v, "UTF-8") != null or
        std.mem.find(u8, v, "utf8") != null or
        std.mem.find(u8, v, "utf-8") != null;
}

pub const SpecError = error{ UnknownCapability, MalformedSpec };

/// `"+sixel,-sextant"`: `,` separated, `+` on, `-` off. Unknown names are an
/// error so a typo cannot silently do nothing.
pub fn applySpec(caps: *Caps, spec: []const u8) SpecError!void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        const on = switch (item[0]) {
            '+' => true,
            '-' => false,
            else => return error.MalformedSpec,
        };
        if (!setByName(caps, item[1..], on)) return error.UnknownCapability;
    }
}

fn setByName(caps: *Caps, name: []const u8, on: bool) bool {
    inline for (@typeInfo(Terminal).@"struct".field_names) |field| {
        if (std.mem.eql(u8, name, field)) {
            @field(caps.terminal, field) = on;
            caps.origins.terminal.set(@field(std.meta.FieldEnum(Terminal), field), .override);
            return true;
        }
    }
    inline for (@typeInfo(Font).@"struct".field_names) |field| {
        if (std.mem.eql(u8, name, field)) {
            @field(caps.font, field) = on;
            caps.origins.font.set(@field(std.meta.FieldEnum(Font), field), .override);
            return true;
        }
    }
    return false;
}

/// Nearest supported mode to `want`. Braille is preferred over half when a
/// denser font mode is unavailable, because it is denser and widely supported.
pub fn select(caps: Caps, want: Mode) Mode {
    if (!caps.font.utf8) return .ascii;
    return switch (want) {
        .sextant => if (caps.font.sextant) .sextant else select(caps, .braille),
        .braille => if (caps.font.braille) .braille else select(caps, .half),
        .quad => if (caps.font.quadrant) .quad else select(caps, .half),
        .half, .bars, .ascii => want,
    };
}

const Cursor = struct {
    buf: []u8,
    i: usize = 0,

    fn print(c: *Cursor, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(c.buf[c.i..], fmt, args) catch return;
        c.i += s.len;
    }

    fn line(c: *Cursor, comptime T: type, head: []const u8, values: T, sources: std.enums.EnumArray(std.meta.FieldEnum(T), Source)) void {
        c.print("{s}", .{head});
        inline for (@typeInfo(T).@"struct".field_names, 0..) |field, idx| {
            const v: bool = @field(values, field);
            const s = sources.get(@field(std.meta.FieldEnum(T), field));
            c.print("{s}{s} {s}({s})", .{
                if (idx == 0) "" else "  ",
                field,
                if (v) "on" else "off",
                @tagName(s),
            });
        }
        c.print("\n", .{});
    }
};

/// Two lines, one per axis, each flag with the source that decided it.
pub fn describe(caps: Caps, buf: []u8) []const u8 {
    var c = Cursor{ .buf = buf };
    c.line(Terminal, "terminal  ", caps.terminal, caps.origins.terminal);
    c.line(Font, "font      ", caps.font, caps.origins.font);
    return buf[0..c.i];
}

test "windows terminal: sixel comes from WT_SESSION" {
    const caps = resolve(.{ .wt_session = "abc", .colorterm = "truecolor" }, .{});
    try std.testing.expect(caps.terminal.sixel);
    try std.testing.expect(caps.terminal.rgb);
    try std.testing.expectEqual(Source.env, caps.terminalSource(.sixel));
}

test "wezterm: env evidence beats a negative probe" {
    const caps = resolve(.{ .term_program = "WezTerm" }, .{ .kitty_graphics = false });
    try std.testing.expect(caps.terminal.kitty_graphics);
    try std.testing.expectEqual(Source.env, caps.terminalSource(.kitty_graphics));
}

test "alacritty: no bitmap, braille still the default density" {
    const caps = resolve(.{ .term_program = "alacritty" }, .{});
    try std.testing.expect(!caps.terminal.sixel);
    try std.testing.expect(!caps.terminal.kitty_graphics);
    try std.testing.expectEqual(Mode.braille, select(caps, .braille));
}

test "inside a multiplexer the probe wins" {
    const caps = resolve(.{ .term_program = "WezTerm", .multiplexer = true }, .{ .kitty_graphics = false });
    try std.testing.expect(!caps.terminal.kitty_graphics);
    try std.testing.expectEqual(Source.probe, caps.terminalSource(.kitty_graphics));
}

test "non-utf8 locale degrades to ascii" {
    const caps = resolve(.{ .lang = "C" }, .{});
    try std.testing.expect(!caps.font.utf8);
    try std.testing.expectEqual(Mode.ascii, select(caps, .braille));
    try std.testing.expectEqual(Source.env, caps.fontSource(.utf8));
}

test "spec overrides every other source" {
    var caps = resolve(.{ .wt_session = "abc" }, .{ .sixel = false });
    try std.testing.expect(caps.terminal.sixel);
    try applySpec(&caps, "-sixel,+sextant");
    try std.testing.expect(!caps.terminal.sixel);
    try std.testing.expect(caps.font.sextant);
    try std.testing.expectEqual(Source.override, caps.terminalSource(.sixel));
    try std.testing.expectEqual(Mode.sextant, select(caps, .sextant));
}

test "spec rejects typos and malformed items" {
    var caps = Caps{};
    try std.testing.expectError(error.UnknownCapability, applySpec(&caps, "+sixle"));
    try std.testing.expectError(error.MalformedSpec, applySpec(&caps, "sixel"));
}

test "describe reports provenance" {
    var buf: [512]u8 = undefined;
    const caps = resolve(.{ .wt_session = "abc" }, .{ .sync_output = true });
    const out = describe(caps, &buf);
    try std.testing.expect(std.mem.find(u8, out, "sixel on(env)") != null);
    try std.testing.expect(std.mem.find(u8, out, "sync_output on(probe)") != null);
    try std.testing.expect(std.mem.find(u8, out, "octant off(default)") != null);
}
