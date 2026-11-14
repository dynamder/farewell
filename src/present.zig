//! Frame assembly: grid, mode, buffer, one write per frame.

const std = @import("std");
const types = @import("types.zig");
const caps_mod = @import("caps.zig");
const blit = @import("blit.zig");
const ansi = @import("ansi.zig");
const source = @import("source.zig");

const Grid = types.Grid;
const Mode = types.Mode;
const Caps = caps_mod.Caps;

pub const Size = struct { cols: u16, rows: u16 };

/// Worst case per cell: merged truecolour SGR plus a four-byte glyph.
pub fn bytesNeeded(size: Size) usize {
    const cells = @as(usize, size.cols) * @as(usize, size.rows);
    return cells * 48 + @as(usize, size.rows) * 2 + 64;
}

pub const Presenter = struct {
    alloc: std.mem.Allocator,
    size: Size,
    caps: Caps,
    want: Mode,
    mode: Mode,
    options: blit.Options = .{},
    grid: Grid,
    prev: Grid,
    tint: []u8,

    pub fn init(alloc: std.mem.Allocator, size: Size, caps: Caps, want: Mode) !Presenter {
        var p: Presenter = .{
            .alloc = alloc,
            .size = size,
            .caps = caps,
            .want = want,
            .mode = caps_mod.select(caps, want),
            .grid = try Grid.init(alloc, size.cols, size.rows),
            .prev = undefined,
            .tint = undefined,
        };
        errdefer p.grid.deinit(alloc);
        p.prev = try Grid.init(alloc, size.cols, size.rows);
        errdefer p.prev.deinit(alloc);
        p.tint = try alloc.alloc(u8, bytesNeeded(size));
        return p;
    }

    pub fn deinit(self: *Presenter) void {
        self.grid.deinit(self.alloc);
        self.prev.deinit(self.alloc);
        self.alloc.free(self.tint);
        self.* = undefined;
    }

    pub fn resize(self: *Presenter, size: Size) !void {
        if (size.cols == self.size.cols and size.rows == self.size.rows) return;

        var next_grid = try Grid.init(self.alloc, size.cols, size.rows);
        errdefer next_grid.deinit(self.alloc);
        var next_prev = try Grid.init(self.alloc, size.cols, size.rows);
        errdefer next_prev.deinit(self.alloc);
        const next_tint = try self.alloc.alloc(u8, bytesNeeded(size));
        errdefer self.alloc.free(next_tint);

        self.grid.deinit(self.alloc);
        self.prev.deinit(self.alloc);
        self.alloc.free(self.tint);

        self.grid = next_grid;
        self.prev = next_prev;
        self.tint = next_tint;
        self.size = size;
    }

    /// Full redraw. The returned slice is valid until the next call.
    pub fn draw(self: *Presenter, src: anytype) ![]const u8 {
        blit.renderAny(src, self.mode, &self.grid, self.options);
        const stats = try ansi.emit(&self.grid, self.payload(), .{});
        return self.assemble(stats);
    }

    /// Row-level diff against the previous frame. An unchanged frame yields an
    /// empty slice, so the caller can skip the write entirely.
    pub fn drawDiff(self: *Presenter, src: anytype) ![]const u8 {
        blit.renderAny(src, self.mode, &self.grid, self.options);
        const stats = try ansi.emit(&self.grid, self.payload(), .{ .redraw = .row_skip, .prev = &self.prev });
        std.mem.swap(Grid, &self.grid, &self.prev);
        if (stats.rows == 0) return self.tint[0..0];
        return self.assemble(stats);
    }

    fn payload(self: *Presenter) []u8 {
        return self.tint[self.head()..];
    }

    fn head(self: *Presenter) usize {
        return if (self.caps.terminal.sync_output) ansi.sync_on.len else 0;
    }

    fn assemble(self: *Presenter, stats: ansi.Stats) []const u8 {
        const offset = self.head();
        if (offset == 0) return self.tint[0..stats.bytes];
        @memcpy(self.tint[0..offset], ansi.sync_on);
        const tail = offset + stats.bytes;
        @memcpy(self.tint[tail..][0..ansi.sync_off.len], ansi.sync_off);
        return self.tint[0 .. tail + ansi.sync_off.len];
    }
};

const Solid = struct {
    color: types.RGB,
    pub fn sample(self: *const Solid, _: f32, _: f32) types.RGB {
        return self.color;
    }
};

fn capsWithSync(sync: bool) Caps {
    var c = Caps{};
    c.terminal.sync_output = sync;
    return c;
}

test "every cell at worst case still fits the buffer" {
    const size = Size{ .cols = 120, .rows = 36 };
    var p = try Presenter.init(std.testing.allocator, size, capsWithSync(false), .half);
    defer p.deinit();

    for (p.grid.cells) |*c| {
        c.* = .{ .cp = 0x1F600, .fg = .{ .r = 255, .g = 255, .b = 255 }, .bg = .{ .r = 1, .g = 2, .b = 3 } };
    }
    _ = try ansi.emit(&p.grid, p.payload(), .{});
}

test "sync markers wrap the frame only when supported" {
    var solid = Solid{ .color = .{ .r = 10, .g = 20, .b = 30 } };

    var on = try Presenter.init(std.testing.allocator, .{ .cols = 4, .rows = 2 }, capsWithSync(true), .half);
    defer on.deinit();
    const wrapped = try on.draw(source.sampler(&solid));
    try std.testing.expect(std.mem.startsWith(u8, wrapped, ansi.sync_on));
    try std.testing.expect(std.mem.endsWith(u8, wrapped, ansi.sync_off));

    var off = try Presenter.init(std.testing.allocator, .{ .cols = 4, .rows = 2 }, capsWithSync(false), .half);
    defer off.deinit();
    const plain = try off.draw(source.sampler(&solid));
    try std.testing.expect(std.mem.find(u8, plain, "2026") == null);
}

test "requested mode falls back through caps" {
    var p = try Presenter.init(std.testing.allocator, .{ .cols = 4, .rows = 2 }, capsWithSync(false), .sextant);
    defer p.deinit();
    try std.testing.expectEqual(Mode.braille, p.mode);
}

test "unchanged frame produces no bytes" {
    var solid = Solid{ .color = .{ .r = 200, .g = 100, .b = 50 } };
    var p = try Presenter.init(std.testing.allocator, .{ .cols = 6, .rows = 3 }, capsWithSync(true), .half);
    defer p.deinit();

    const first = try p.drawDiff(source.sampler(&solid));
    try std.testing.expect(first.len > 0);
    const second = try p.drawDiff(source.sampler(&solid));
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "resize keeps the presenter usable" {
    var solid = Solid{ .color = .{ .r = 1, .g = 2, .b = 3 } };
    var p = try Presenter.init(std.testing.allocator, .{ .cols = 4, .rows = 2 }, capsWithSync(false), .half);
    defer p.deinit();
    try p.resize(.{ .cols = 9, .rows = 5 });
    try std.testing.expectEqual(@as(u16, 9), p.size.cols);
    try std.testing.expectEqual(@as(usize, 45), p.grid.cells.len);
    try std.testing.expect((try p.draw(source.sampler(&solid))).len > 0);
}
