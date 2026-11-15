//! Frame pacing: trades rate for quality to keep each frame inside its interval.

const std = @import("std");

/// What one frame cost, split so the caller can see which side was slow.
pub const Sample = struct {
    /// Producing the bytes: sampling, packing, encoding.
    render_ns: u64,
    /// Writing them out; a slow channel shows up here.
    write_ns: u64,
};

pub const Decision = enum {
    keep,
    /// The interval widened; the caller has more room next frame.
    slower,
    /// The quality level dropped.
    coarser,
    /// The interval narrowed.
    faster,
    /// The quality level climbed.
    finer,
};

pub const Options = struct {
    /// Frame rate to start from, and the most the pacer will ask for.
    fps: u16 = 60,
    /// Below this a longer interval is a slideshow, so quality drops instead.
    min_fps: u16 = 15,
    /// Quality levels the caller can render; 0 is the cheapest.
    levels: u8 = 6,
    /// Level to start from, and the finest the pacer will ask for.
    level: u8 = 2,
    /// Without atomic frames (mode 2026) the terminal shows partly painted
    /// frames, so the rate is capped before anything else is traded away.
    unsynced_max_fps: u16 = 30,
    /// Consecutive frames over budget before anything is traded.
    late_after: u8 = 3,
    /// Consecutive frames with room to spare before widening again.
    early_after: u8 = 30,
};

pub const Pacer = struct {
    o: Options,
    fps: u16,
    ceiling: u16,
    level: u8,
    late: u8 = 0,
    early: u8 = 0,

    /// `synced` is the terminal's atomic-frame support.
    pub fn init(o: Options, synced: bool) Pacer {
        const ceiling = if (synced) o.fps else @min(o.fps, o.unsynced_max_fps);
        return .{
            .o = o,
            .fps = @max(ceiling, o.min_fps),
            .ceiling = ceiling,
            .level = o.level,
        };
    }

    /// What one frame may take at the current rate.
    pub fn budgetNs(self: Pacer) u64 {
        return std.time.ns_per_s / @as(u64, self.fps);
    }

    /// Feeds one measured frame and trades rate for quality once the evidence
    /// is strong enough. `fps` and `level` are updated in place; the return
    /// value says what moved.
    pub fn observe(self: *Pacer, s: Sample) Decision {
        const spent = s.render_ns + s.write_ns;

        if (spent > self.budgetNs()) {
            self.late +|= 1;
            self.early = 0;
            if (self.late < self.o.late_after) return .keep;
            self.late = 0;
            if (self.fps > self.o.min_fps) {
                self.fps = @max(self.o.min_fps, self.fps - self.fps / 4);
                return .slower;
            }
            if (self.level > 0) {
                self.level -= 1;
                return .coarser;
            }
            return .keep;
        }

        self.late = 0;
        self.early +|= 1;
        if (self.early < self.o.early_after) return .keep;
        self.early = 0;
        if (self.level < self.o.level) {
            self.level += 1;
            return .finer;
        }
        if (self.fps < self.ceiling) {
            self.fps = @min(self.ceiling, self.fps +| self.fps / 4);
            return .faster;
        }
        return .keep;
    }
};

const fast = Sample{ .render_ns = 1_000_000, .write_ns = 1_000_000 };
const slow = Sample{ .render_ns = 10_000_000, .write_ns = 8_000_000 };
/// One nanosecond past the 60 fps budget.
const over = Sample{ .render_ns = 8_000_000, .write_ns = 8_666_667 };
/// Over budget even at 15 fps, so the rate has to bottom out.
const stuck = Sample{ .render_ns = 40_000_000, .write_ns = 30_000_000 };

fn feed(p: *Pacer, n: usize, s: Sample) Decision {
    var last: Decision = .keep;
    var i: usize = 0;
    while (i < n) : (i += 1) last = p.observe(s);
    return last;
}

test "one late frame is not evidence" {
    var p = Pacer.init(.{}, true);
    try std.testing.expectEqual(Decision.keep, p.observe(slow));
    try std.testing.expectEqual(@as(u16, 60), p.fps);
    try std.testing.expectEqual(@as(u8, 2), p.level);
}

test "a frame exactly on budget is not late, a nanosecond is" {
    var on = Pacer.init(.{ .fps = 60 }, true);
    try std.testing.expectEqual(Decision.keep, feed(&on, 60, .{ .render_ns = 8_000_000, .write_ns = 8_666_666 }));
    try std.testing.expectEqual(@as(u16, 60), on.fps);

    var past = Pacer.init(.{ .fps = 60 }, true);
    try std.testing.expectEqual(Decision.slower, feed(&past, 3, over));
}

test "late frames slow the rate to its floor, then coarsen" {
    var p = Pacer.init(.{ .level = 3 }, true);
    try std.testing.expectEqual(Decision.slower, feed(&p, 3, slow));
    try std.testing.expectEqual(@as(u16, 45), p.fps);

    while (p.fps > 15) _ = feed(&p, 3, stuck);
    try std.testing.expectEqual(@as(u16, 15), p.fps);
    try std.testing.expectEqual(@as(u8, 3), p.level);

    try std.testing.expectEqual(Decision.coarser, feed(&p, 3, stuck));
    try std.testing.expectEqual(@as(u8, 2), p.level);
    try std.testing.expectEqual(@as(u16, 15), p.fps);
}

test "quality climbs back before the rate does" {
    var p = Pacer.init(.{ .level = 3 }, true);
    while (p.fps > 15) _ = feed(&p, 3, stuck);
    _ = feed(&p, 3, stuck);
    try std.testing.expectEqual(@as(u8, 2), p.level);

    try std.testing.expectEqual(Decision.finer, feed(&p, 30, fast));
    try std.testing.expectEqual(@as(u8, 3), p.level);
    try std.testing.expectEqual(@as(u16, 15), p.fps);

    try std.testing.expectEqual(Decision.faster, feed(&p, 30, fast));
    try std.testing.expectEqual(@as(u16, 18), p.fps);
}

test "the floor of the ladder holds" {
    var p = Pacer.init(.{ .fps = 15, .min_fps = 15, .level = 0 }, true);
    try std.testing.expectEqual(Decision.keep, feed(&p, 30, stuck));
    try std.testing.expectEqual(@as(u16, 15), p.fps);
    try std.testing.expectEqual(@as(u8, 0), p.level);
}

test "a terminal without atomic frames starts capped" {
    try std.testing.expectEqual(@as(u16, 30), Pacer.init(.{ .fps = 60 }, false).fps);
    try std.testing.expectEqual(@as(u16, 60), Pacer.init(.{ .fps = 60 }, true).fps);
    try std.testing.expectEqual(@as(u16, 24), Pacer.init(.{ .fps = 24 }, false).fps);
}

test "the ceiling survives the climb" {
    var p = Pacer.init(.{ .fps = 60 }, false);
    while (p.fps > 15) _ = feed(&p, 3, stuck);
    while (p.fps < 30) _ = feed(&p, 30, fast);
    try std.testing.expectEqual(@as(u16, 30), p.fps);
    try std.testing.expectEqual(Decision.keep, feed(&p, 60, fast));
}

test "the budget follows the rate" {
    var p = Pacer.init(.{ .fps = 60 }, true);
    try std.testing.expectEqual(@as(u64, 16_666_666), p.budgetNs());
    _ = feed(&p, 3, slow);
    try std.testing.expectEqual(@as(u64, 22_222_222), p.budgetNs());
}
