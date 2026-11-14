const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mosaic = b.addModule("mosaic", .{
        .root_source_file = b.path("src/mosaic.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mosaic });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const demo = b.addExecutable(.{
        .name = "raymarch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/raymarch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("mosaic", mosaic);
    b.installArtifact(demo);

    const run = b.addRunArtifact(demo);
    b.step("run", "Run the raymarch demo").dependOn(&run.step);
}
