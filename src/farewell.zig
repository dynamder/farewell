//! Terminal graphics primitives: pixels in, ANSI bytes out.

pub const types = @import("types.zig");
pub const source = @import("source.zig");
pub const blit = @import("blit.zig");
pub const ansi = @import("ansi.zig");
pub const caps = @import("caps.zig");
pub const pacer = @import("pacer.zig");
pub const post = @import("post.zig");
pub const present = @import("present.zig");

pub const RGB = types.RGB;
pub const Attr = types.Attr;
pub const Cell = types.Cell;
pub const Dims = types.Dims;
pub const Grid = types.Grid;
pub const Mode = types.Mode;

pub const Frame = source.Frame;
pub const Fmt = source.Fmt;
pub const Sampler = source.Sampler;
pub const sampler = source.sampler;

pub const Options = blit.Options;
pub const Uv = blit.Uv;
pub const render = blit.render;
pub const renderAny = blit.renderAny;

pub const emit = ansi.emit;
pub const EmitOptions = ansi.Options;
pub const Redraw = ansi.Redraw;
pub const takeScreen = ansi.enter;
pub const releaseScreen = ansi.leave;

pub const Caps = caps.Caps;
pub const Probe = caps.Probe;
pub const Env = caps.Env;
pub const resolve = caps.resolve;
pub const probeFrom = caps.probeFrom;
pub const select = caps.select;
pub const applySpec = caps.applySpec;

pub const Pacer = pacer.Pacer;
pub const Decision = pacer.Decision;
pub const Sample = pacer.Sample;

pub const Presenter = present.Presenter;
pub const Size = present.Size;
pub const bytesNeeded = present.bytesNeeded;

test {
    @import("std").testing.refAllDecls(@This());
}
