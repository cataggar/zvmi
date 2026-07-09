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

    // ---- qmp: native Zig QEMU Machine Protocol (QMP) client ----
    const qmp_mod = b.addModule("qmp", .{
        .root_source_file = b.path("qmp/src/qmp.zig"),
        .target = target,
    });

    const qmp_exe = b.addExecutable(.{
        .name = "qmp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("qmp/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qmp", .module = qmp_mod },
            },
        }),
    });
    b.installArtifact(qmp_exe);

    // Offline QAPI-schema-to-Zig-bindings generator. Not part of the default
    // build graph's dependency chain on qapi/*.json; run manually against a
    // QEMU checkout (see qmp/README.md) and commit the generated
    // qmp/src/qapi_generated.zig.
    const qapi_codegen_exe = b.addExecutable(.{
        .name = "qapi-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("qmp/tools/qapi_codegen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(qapi_codegen_exe);

    const run_qapi_codegen = b.addRunArtifact(qapi_codegen_exe);
    run_qapi_codegen.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_qapi_codegen.addArgs(args);
    const qapi_codegen_step = b.step("qapi-codegen", "Regenerate qmp/src/qapi_generated.zig from a QEMU checkout's qapi/qapi-schema.json");
    qapi_codegen_step.dependOn(&run_qapi_codegen.step);

    const qmp_mod_tests = b.addTest(.{ .root_module = qmp_mod });
    const run_qmp_mod_tests = b.addRunArtifact(qmp_mod_tests);
    const qmp_exe_tests = b.addTest(.{ .root_module = qmp_exe.root_module });
    const run_qmp_exe_tests = b.addRunArtifact(qmp_exe_tests);
    const qmp_codegen_tests = b.addTest(.{ .root_module = qapi_codegen_exe.root_module });
    const run_qmp_codegen_tests = b.addRunArtifact(qmp_codegen_tests);
    // `qmp/tools/qapi_schema.zig`'s tests aren't reachable from
    // `qapi_codegen.zig` as a *test* root (Zig only auto-discovers `test`
    // blocks declared in the module's own root file), so it needs its own
    // test root too.
    const qmp_schema_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("qmp/tools/qapi_schema.zig"),
        .target = target,
    }) });
    const run_qmp_schema_tests = b.addRunArtifact(qmp_schema_tests);

    // ---- tests/boot_smoke.zig: opportunistic real-QEMU boot verification,
    // driving zvmi.build_image.build() output with qmp. Lives outside
    // packages/zvmi since it needs both zvmi and qmp -- see issue #99. ----
    const boot_smoke_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/boot_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zvmi", .module = zvmi_mod },
            .{ .name = "qmp", .module = qmp_mod },
        },
    }) });
    const run_boot_smoke_tests = b.addRunArtifact(boot_smoke_tests);
    const boot_smoke_step = b.step("test-boot-smoke", "Run opportunistic real-QEMU boot-smoke tests");
    boot_smoke_step.dependOn(&run_boot_smoke_tests.step);

    // ---- nbd: native Zig NBD client + reference server ----
    const nbd_mod = b.addModule("nbd", .{
        .root_source_file = b.path("nbd/src/nbd.zig"),
        .target = target,
    });

    const nbd_exe = b.addExecutable(.{
        .name = "nbd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("nbd/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nbd", .module = nbd_mod },
            },
        }),
    });
    b.installArtifact(nbd_exe);

    const nbd_mod_tests = b.addTest(.{ .root_module = nbd_mod });
    const run_nbd_mod_tests = b.addRunArtifact(nbd_mod_tests);
    const nbd_exe_tests = b.addTest(.{ .root_module = nbd_exe.root_module });
    const run_nbd_exe_tests = b.addRunArtifact(nbd_exe_tests);
    // `nbd/src/server.zig`'s tests aren't reachable from `nbd/src/nbd.zig`
    // as a *test* root (Zig only auto-discovers `test` blocks declared in
    // the module's own root file), even though `nbd.zig` re-exports it as
    // `nbd.server`, so it needs its own test root too.
    const nbd_server_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("nbd/src/server.zig"),
        .target = target,
    }) });
    const run_nbd_server_tests = b.addRunArtifact(nbd_server_tests);

    // ---- qcow2: native Zig qcow2 reader/writer ----
    const qcow2_mod = b.addModule("qcow2", .{
        .root_source_file = b.path("qcow2/src/qcow2.zig"),
        .target = target,
    });

    const qcow2_exe = b.addExecutable(.{
        .name = "qcow2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("qcow2/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qcow2", .module = qcow2_mod },
            },
        }),
    });
    b.installArtifact(qcow2_exe);

    const qcow2_mod_tests = b.addTest(.{ .root_module = qcow2_mod });
    const run_qcow2_mod_tests = b.addRunArtifact(qcow2_mod_tests);
    const qcow2_exe_tests = b.addTest(.{ .root_module = qcow2_exe.root_module });
    const run_qcow2_exe_tests = b.addRunArtifact(qcow2_exe_tests);

    // ---- miniinit: standalone minimal PID 1 for real-boot testing of
    // --skip-iso-rootfs images ----
    // miniinit always runs as PID 1 inside an x86_64 Azure Linux guest, so
    // unlike the rest of this repo it hardcodes its target rather than
    // using `target`/`optimize` above. Static linking keeps it fully
    // self-contained: no libc, no kmod, no other runtime dependency needs
    // to be present in the guest's root filesystem.
    const miniinit_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });
    const miniinit_exe = b.addExecutable(.{
        .name = "miniinit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("miniinit/init.zig"),
            .target = miniinit_target,
            .optimize = .ReleaseSmall,
        }),
        .linkage = .static,
    });
    b.installArtifact(miniinit_exe);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zvmi_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_qmp_mod_tests.step);
    test_step.dependOn(&run_qmp_exe_tests.step);
    test_step.dependOn(&run_qmp_codegen_tests.step);
    test_step.dependOn(&run_qmp_schema_tests.step);
    test_step.dependOn(&run_boot_smoke_tests.step);
    test_step.dependOn(&run_nbd_mod_tests.step);
    test_step.dependOn(&run_nbd_exe_tests.step);
    test_step.dependOn(&run_nbd_server_tests.step);
    test_step.dependOn(&run_qcow2_mod_tests.step);
    test_step.dependOn(&run_qcow2_exe_tests.step);
}
