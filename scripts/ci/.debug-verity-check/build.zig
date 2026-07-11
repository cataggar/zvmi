const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cpio_mod = b.addModule("cpio", .{
        .root_source_file = b.path("../../../packages/zvmi/src/cpio.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "veritycheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cpio", .module = cpio_mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    const step = b.step("run", "run");
    step.dependOn(&run.step);
}
