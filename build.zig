const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- packages/zvmi: the core disk-image library ----
    const zvmi_mod = b.addModule("zvmi", .{
        .root_source_file = b.path("packages/zvmi/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zvmi_tests = b.addTest(.{ .root_module = zvmi_mod });
    const run_zvmi_tests = b.addRunArtifact(zvmi_tests);

    // ---- cli: the `zvmi` executable ----
    const cli_exe = b.addExecutable(.{
        .name = "zvmi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = zvmi_mod },
            },
        }),
    });
    b.installArtifact(cli_exe);

    const run_cmd = b.addRunArtifact(cli_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zvmi");
    run_step.dependOn(&run_cmd.step);

    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zvmi_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
