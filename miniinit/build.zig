const std = @import("std");

pub fn build(b: *std.Build) void {
    // miniinit always runs as PID 1 inside an x86_64 Azure Linux guest, so
    // unlike the rest of this repo it hardcodes its target rather than
    // using `b.standardTargetOptions()`. Static linking keeps it fully
    // self-contained: no libc, no kmod, no other runtime dependency needs
    // to be present in the guest's root filesystem.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });
    // Hardcoded rather than exposed via -Doptimize=: this binary's whole
    // purpose is to be tiny and dependency-free, so there's no reasonable
    // case for shipping a Debug build of it.
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "miniinit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("init.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(exe);
}
