//! Cells to ANSI bytes: merged truecolour SGR, CRLF rows, row-level diff.

const std = @import("std");
const types = @import("types.zig");

const RGB = types.RGB;
const Cell = types.Cell;
const Grid = types.Grid;

pub const Redraw = enum { full, row_skip };

pub const Options = struct {
    redraw: Redraw = .full,
    /// Required for `.row_skip`; ignored for `.full`.
    prev: ?*const Grid = null,
};

pub const Stats = struct {
    bytes: usize = 0,
    cells: usize = 0,
    rows: usize = 0,

    /// Bytes spent per emitted cell, the number the pacer budgets against.
    pub fn bytesPerCell(s: Stats) f32 {
        if (s.cells == 0) return 0;
        return @as(f32, @floatFromInt(s.bytes)) / @as(f32, @floatFromInt(s.cells));
    }
};

pub const Error = error{NoSpaceLeft};

/// Take over the screen: alt screen, hide cursor, no autowrap, reset attrs.
pub const enter = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[0m\x1b[2J\x1b[H";
/// Hand the screen back.
pub const leave = "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l";
/// Stop autowrap and hide the cursor, without taking over the screen.
pub const quiet_on = "\x1b[?7l\x1b[?25l\x1b[0m";
/// Undo `quiet_on`.
pub const quiet_off = "\x1b[?7h\x1b[?25h\x1b[0m";
/// Per-frame prefix.
pub const home = "\x1b[H";
/// Frame atomicity, emitted only when the terminal supports it.
pub const sync_on = "\x1b[?2026h";
pub const sync_off = "\x1b[?2026l";

pub fn emit(g: *const Grid, buf: []u8, o: Options) Error!Stats {
    var w = Writer{ .buf = buf };
    try w.put(home);

    var last_fg: ?RGB = null;
    var last_bg: ?RGB = null;
    var stats = Stats{};

    var y: usize = 0;
    while (y < g.h) : (y += 1) {
        const row_dirty = switch (o.redraw) {
            .full => true,
            .row_skip => if (o.prev) |p| !rowEqual(g, p, @intCast(y)) else true,
        };

        if (row_dirty) {
            var x: usize = 0;
            while (x < g.w) : (x += 1) {
                const c = g.get(@intCast(x), @intCast(y));
                try w.sgr(c.fg, c.bg, &last_fg, &last_bg);
                try w.cp(c.cp);
                stats.cells += 1;
            }
            stats.rows += 1;
        }
        if (y + 1 < g.h) try w.put("\r\n");
    }

    stats.bytes = w.i;
    return stats;
}

fn rowEqual(a: *const Grid, b: *const Grid, y: u16) bool {
    if (a.w != b.w) return false;
    const n = @as(usize, a.w);
    const off = @as(usize, y) * n;
    for (a.cells[off .. off + n], b.cells[off .. off + n]) |x, y2| {
        if (x.cp != y2.cp) return false;
        if (!x.fg.eql(y2.fg) or !x.bg.eql(y2.bg)) return false;
    }
    return true;
}

const Writer = struct {
    buf: []u8,
    i: usize = 0,

    fn put(w: *Writer, bytes: []const u8) Error!void {
        if (w.i + bytes.len > w.buf.len) return error.NoSpaceLeft;
        @memcpy(w.buf[w.i .. w.i + bytes.len], bytes);
        w.i += bytes.len;
    }

    fn u8dec(w: *Writer, v: u8) Error!void {
        if (v >= 100) {
            try w.put(&.{'0' + v / 100});
            try w.put(&.{'0' + (v / 10) % 10});
            try w.put(&.{'0' + v % 10});
        } else if (v >= 10) {
            try w.put(&.{'0' + v / 10});
            try w.put(&.{'0' + v % 10});
        } else {
            try w.put(&.{'0' + v});
        }
    }

    fn rgb(w: *Writer, c: RGB) Error!void {
        try w.u8dec(c.r);
        try w.put(";");
        try w.u8dec(c.g);
        try w.put(";");
        try w.u8dec(c.b);
    }

    /// Emit the smallest SGR that gets us to (fg, bg).
    fn sgr(w: *Writer, fg: RGB, bg: RGB, last_fg: *?RGB, last_bg: *?RGB) Error!void {
        const fg_changed = last_fg.* == null or !last_fg.*.?.eql(fg);
        const bg_changed = last_bg.* == null or !last_bg.*.?.eql(bg);
        if (!fg_changed and !bg_changed) return;

        try w.put("\x1b[");
        if (fg_changed and bg_changed) {
            try w.put("38;2;");
            try w.rgb(fg);
            try w.put(";48;2;");
            try w.rgb(bg);
        } else if (fg_changed) {
            try w.put("38;2;");
            try w.rgb(fg);
        } else {
            try w.put("48;2;");
            try w.rgb(bg);
        }
        try w.put("m");
        last_fg.* = fg;
        last_bg.* = bg;
    }

    /// UTF-8 encode a single codepoint.
    fn cp(w: *Writer, c: u21) Error!void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &tmp) catch {
            try w.put("?");
            return;
        };
        try w.put(tmp[0..n]);
    }
};

var scratch: [1]Cell = undefined;

fn oneCell(c: Cell) Grid {
    scratch[0] = c;
    return .{ .w = 1, .h = 1, .cells = scratch[0..] };
}

test "emits merged sgr and the glyph" {
    var buf: [128]u8 = undefined;
    const g = oneCell(.{ .cp = 'A', .fg = .{ .r = 255, .g = 0, .b = 0 }, .bg = .{ .r = 0, .g = 0, .b = 255 } });
    const st = try emit(&g, &buf, .{});
    const out = buf[0..st.bytes];
    try std.testing.expect(std.mem.find(u8, out, "\x1b[38;2;255;0;0;48;2;0;0;255m") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "A"));
    try std.testing.expectEqual(@as(usize, 1), st.cells);
}

test "unchanged colour costs no sgr" {
    var buf: [256]u8 = undefined;
    var g = try Grid.init(std.testing.allocator, 3, 1);
    defer g.deinit(std.testing.allocator);
    g.fill(.{ .cp = '#', .fg = .{ .r = 1, .g = 2, .b = 3 }, .bg = RGB.black });

    const st = try emit(&g, &buf, .{});
    const out = buf[0..st.bytes];
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, out, i, "\x1b[")) |p| {
        count += 1;
        i = p + 2;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.find(u8, out, "###") != null);
}

test "row_skip only sends dirty rows" {
    var a = try Grid.init(std.testing.allocator, 2, 2);
    defer a.deinit(std.testing.allocator);
    var b = try Grid.init(std.testing.allocator, 2, 2);
    defer b.deinit(std.testing.allocator);

    a.fill(.{ .cp = '.', .fg = RGB.white, .bg = RGB.black });
    b.fill(.{ .cp = '.', .fg = RGB.white, .bg = RGB.black });
    a.at(0, 1).*.cp = 'X';

    var buf: [256]u8 = undefined;
    const st = try emit(&a, &buf, .{ .redraw = .row_skip, .prev = &b });
    const out = buf[0..st.bytes];
    try std.testing.expectEqual(@as(usize, 1), st.rows);
    try std.testing.expectEqual(@as(usize, 2), st.cells);
    try std.testing.expect(std.mem.find(u8, out, "X.") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[H\r\n"));
}

test "reports no space instead of overflowing" {
    var buf: [4]u8 = undefined;
    const g = oneCell(.{ .cp = 'A', .fg = RGB.white, .bg = RGB.black });
    try std.testing.expectError(error.NoSpaceLeft, emit(&g, &buf, .{}));
}

test "utf8 encodes multi-byte glyphs" {
    var buf: [64]u8 = undefined;
    const g = oneCell(.{ .cp = 0x2580, .fg = RGB.white, .bg = RGB.black });
    const st = try emit(&g, &buf, .{});
    try std.testing.expect(std.mem.endsWith(u8, buf[0..st.bytes], "\xe2\x96\x80"));
}
