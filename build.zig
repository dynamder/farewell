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

    // The glyph table is generated from a font, which needs a rasteriser: that is
    // the one thing Zig's standard library does not have. Python is a tool-time
    // dependency only; the generated file is committed and `zig build` never
    // runs this step.
    const python = b.option([]const u8, "python", "interpreter for tools/inkmap.py") orelse "python";
    const table_args = [_][]const u8{ "--out", "src/ink-ascii.zig", "--cell", "10x20", "--size", "16" };

    const inkmap = b.addSystemCommand(&.{python});
    inkmap.addFileArg(b.path("tools/inkmap.py"));
    inkmap.addArgs(&table_args);
    if (b.option([]const u8, "font", "TTF the glyph masks are measured from")) |font| {
        inkmap.addArgs(&.{ "--font", font });
    }
    const inkmap_fmt = b.addFmt(.{ .paths = &.{b.path("src/ink-ascii.zig")} });
    inkmap_fmt.step.dependOn(&inkmap.step);
    b.step("inkmap", "Regenerate src/ink-ascii.zig from a font").dependOn(&inkmap_fmt.step);

    const inkmap_check = b.addSystemCommand(&.{python});
    inkmap_check.addFileArg(b.path("tools/inkmap.py"));
    inkmap_check.addArgs(&table_args);
    inkmap_check.addArg("--check");
    b.step("inkmap-check", "Verify the glyph table matches tools/inkmap.py").dependOn(&inkmap_check.step);
}
