const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const initramfs_mod = b.addModule("initramfs", .{
        .root_source_file = b.path("../../../packages/zvmi/src/initramfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "veritycheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "initramfs", .module = initramfs_mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    const step = b.step("run", "run");
    step.dependOn(&run.step);
}
