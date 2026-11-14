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
}
