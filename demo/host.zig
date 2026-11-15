//! Terminal as a device: one write per frame, size on demand, one key at a time.

const std = @import("std");
const farewell = @import("farewell");
const builtin = @import("builtin");

const Unix = struct {
    saved: std.posix.termios = undefined,
    raw: bool = false,

    fn stdinIsTty() bool {
        _ = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return false;
        return true;
    }

    fn stdoutIsTty() bool {
        _ = std.posix.tcgetattr(std.posix.STDOUT_FILENO) catch return false;
        return true;
    }

    fn rawOn(self: *Unix) void {
        const fd = std.posix.STDIN_FILENO;
        self.saved = std.posix.tcgetattr(fd) catch return;
        var t = self.saved;
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.cc[@backingInt(std.posix.V.MIN)] = 1;
        t.cc[@backingInt(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(fd, .NOW, t) catch return;
        self.raw = true;
    }

    fn rawOff(self: *Unix) void {
        if (!self.raw) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.saved) catch {};
        self.raw = false;
    }

    fn size(io: std.Io, out: std.Io.File) ?farewell.Size {
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = (io.operate(.{ .device_io_control = .{
            .file = out,
            .code = std.posix.T.IOCGWINSZ,
            .arg = &ws,
        } }) catch return null).device_io_control;
        if (rc < 0 or ws.col == 0 or ws.row == 0) return null;
        return .{ .cols = ws.col, .rows = ws.row };
    }

    fn key() ?u8 {
        var fds: [1]std.posix.pollfd = .{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 0) catch return null;
        if (ready == 0) return null;
        var b: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch return null;
        if (n == 0) return null;
        return b[0];
    }
};

/// No terminal to talk to: every query answers "unknown".
const Headless = struct {
    fn stdinIsTty() bool {
        return false;
    }

    fn stdoutIsTty() bool {
        return false;
    }

    fn rawOn(self: *Headless) void {
        _ = self;
    }

    fn rawOff(self: *Headless) void {
        _ = self;
    }

    fn size(io: std.Io, out: std.Io.File) ?farewell.Size {
        _ = io;
        _ = out;
        return null;
    }

    fn key() ?u8 {
        return null;
    }
};

const Impl = if (builtin.os.tag == .windows) Headless else Unix;

pub const Host = struct {
    io: std.Io,
    out: std.Io.File,
    term: Impl = .{},
    screen: bool = false,
    keys: bool = false,
    size_: farewell.Size,

    /// Takes the screen and the keyboard if there is a terminal behind them.
    /// `fallback` is reported as the size when there is not.
    pub fn open(io: std.Io, fallback: farewell.Size) !Host {
        var h: Host = .{ .io = io, .out = std.Io.File.stdout(), .size_ = fallback };
        h.screen = Impl.stdoutIsTty();
        h.keys = Impl.stdinIsTty();
        if (h.keys) h.term.rawOn();
        if (h.screen) {
            try h.write(farewell.ansi.enter);
            if (Impl.size(io, h.out)) |s| h.size_ = s;
        }
        return h;
    }

    /// Gives the screen and the keyboard back.
    pub fn deinit(self: *Host) void {
        if (self.screen) self.write(farewell.ansi.leave) catch {};
        if (self.keys) self.term.rawOff();
        self.* = undefined;
    }

    /// The whole frame in one call; nothing is buffered across frames.
    pub fn write(self: *Host, bytes: []const u8) !void {
        try self.out.writeStreamingAll(self.io, bytes);
    }

    /// Asks the terminal again, keeping the last answer when the query fails.
    pub fn refreshSize(self: *Host) farewell.Size {
        if (self.screen) {
            if (Impl.size(self.io, self.out)) |s| self.size_ = s;
        }
        return self.size_;
    }

    /// The next byte typed, or null when nothing is waiting.
    pub fn readKey(self: *Host) ?u8 {
        if (!self.keys) return null;
        return Impl.key();
    }
};
