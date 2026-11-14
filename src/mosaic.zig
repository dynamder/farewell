//! mosaic — turn a frame of pixels into terminal bytes, and pick the right trick.
//!
//! M0 scope: caps-independent core only.
//!   types  — RGB, Cell, Grid, Mode (density table)
//!   source — Frame | Sampler (duck-typed `at(u, v)`)
//!   blit   — sub-cell packing, `render` / `renderAny`
//!   emit   — cells → ANSI bytes, full redraw

pub const version = "0.0.1";

test {
    @import("std").testing.refAllDecls(@This());
}
