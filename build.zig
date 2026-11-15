const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const farewell = b.addModule("farewell", .{
        .root_source_file = b.path("src/farewell.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = farewell });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const demo = b.addExecutable(.{
        .name = "raymarch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/raymarch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("farewell", farewell);
    b.installArtifact(demo);

    b.step("run", "Run the raymarch demo").dependOn(&b.addRunArtifact(demo).step);
    b.step("fmt", "Format sources").dependOn(&b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("demo") } }).step);

    // The glyph tables are generated from a font, which needs a rasteriser: that
    // is the one thing Zig's standard library does not have. Python is a
    // tool-time dependency only; the generated files are committed and
    // `zig build` never runs these steps.
    const python = b.option([]const u8, "python", "interpreter for tools/inkmap.py") orelse "python";
    const font = b.option([]const u8, "font", "TTF the glyph masks are measured from");

    const inkmap = b.step("inkmap", "Regenerate the measured glyph tables from a font");
    const inkmap_check = b.step("inkmap-check", "Verify the glyph tables match tools/inkmap.py");

    for ([_][]const u8{ "8x8", "8x16" }) |grid| {
        const out = b.fmt("src/ink-ascii-{s}.zig", .{grid});
        const args = [_][]const u8{ "--grid", grid, "--out", out, "--cell", "10x20", "--size", "16" };

        const gen = b.addSystemCommand(&.{python});
        gen.addFileArg(b.path("tools/inkmap.py"));
        gen.addArgs(&args);
        if (font) |path| gen.addArgs(&.{ "--font", path });

        const gen_fmt = b.addFmt(.{ .paths = &.{b.path(out)} });
        gen_fmt.step.dependOn(&gen.step);
        inkmap.dependOn(&gen_fmt.step);

        const check = b.addSystemCommand(&.{python});
        check.addFileArg(b.path("tools/inkmap.py"));
        check.addArgs(&args);
        check.addArg("--check");
        inkmap_check.dependOn(&check.step);
    }
}
