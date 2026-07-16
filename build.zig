const std = @import("std");

const image_build = @import("build/image.zig");

pub const ImageFormat = image_build.Format;
pub const ImageGeneration = image_build.Generation;
pub const ImageBootMode = image_build.BootMode;
pub const ImageArchitecture = image_build.Architecture;
pub const ImageReproducibility = image_build.Reproducibility;
pub const ImageUkiOptions = image_build.UkiOptions;
pub const ImageContainer = image_build.Container;
pub const ImageInput = image_build.Input;
pub const ImageOutput = image_build.Output;
pub const ImageOptions = image_build.Options;
pub const ImageResult = image_build.Result;
pub const addImage = image_build.add;
pub const PreservedImageInput = image_build.PreservedInput;
pub const PreservedImageRootPartition = image_build.PreservedRootPartition;
pub const PreservedImageFileSource = image_build.PreservedFileSource;
pub const PreservedImageOperation = image_build.PreservedOperation;
pub const PreservedImageBackend = image_build.PreservedBackend;
pub const PreservedImageOptions = image_build.PreservedOptions;
pub const addPreservedImage = image_build.addPreserved;

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

    // ---- wireserver: native Zig client for the Azure WireServer
    // goal-state protocol (minimal provisioning subset). A self-contained
    // module with no standalone build.zig of its own; consumed by the
    // future `azagent` guest provisioning executable (issue #112). ----
    const wireserver_mod = b.addModule("wireserver", .{
        .root_source_file = b.path("wireserver/wireserver.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wireserver_tests = b.addTest(.{ .root_module = wireserver_mod });
    const run_wireserver_tests = b.addRunArtifact(wireserver_tests);

    // ---- qemu/host.zig: shared host-side QEMU and OVMF discovery ----
    const qemu_host_mod = b.addModule("qemu_host", .{
        .root_source_file = b.path("qemu/host.zig"),
        .target = target,
        .optimize = optimize,
    });
    const qemu_host_tests = b.addTest(.{ .root_module = qemu_host_mod });
    const run_qemu_host_tests = b.addRunArtifact(qemu_host_tests);

    // ---- azagent: minimal guest provisioning agent for first-boot Azure
    // VM setup (issue #112). Statically linked for self-containment
    // (matching azinit's philosophy), but -- unlike azinit, which is
    // pinned to a single real-boot x86_64 QEMU test fixture -- built for
    // the standard target/optimize so it supports every Linux architecture
    // a given image targets (Azure supports Arm64 VMs too) and remains
    // natively testable via `zig build test` on any host.
    // Imports `zvmi` too (issue #113's resource-disk setup reuses
    // `mbr.zig`/`ext4.zig` directly against a real block device). ----
    const azagent_mod = b.createModule(.{
        .root_source_file = b.path("azagent/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wireserver", .module = wireserver_mod },
            .{ .name = "zvmi", .module = zvmi_mod },
        },
    });

    if (target.result.os.tag == .linux) {
        const azagent_exe = b.addExecutable(.{
            .name = "azagent",
            .root_module = azagent_mod,
            .linkage = .static,
        });
        b.installArtifact(azagent_exe);
    }

    const azagent_tests = b.addTest(.{ .root_module = azagent_mod });
    const run_azagent_tests = b.addRunArtifact(azagent_tests);

    // ---- cli: the `zvmi` executable ----
    const cli_exe = b.addExecutable(.{
        .name = "zvmi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = zvmi_mod },
                .{ .name = "qemu_host", .module = qemu_host_mod },
            },
        }),
    });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    const install_cli_step = b.step("install-zvmi", "Install only the zvmi CLI");
    install_cli_step.dependOn(&install_cli.step);

    const run_cmd = b.addRunArtifact(cli_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zvmi");
    run_step.dependOn(&run_cmd.step);

    const cli_tests = b.addTest(.{ .root_module = cli_exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // Host-only image builders used by the exported build helpers. They remain
    // executable even when the dependency is configured for a foreign target.
    const host_zvmi_mod = b.createModule(.{
        .root_source_file = b.path("packages/zvmi/src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const image_builder_exe = b.addExecutable(.{
        .name = "zvmi-image-builder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/image_builder.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
            },
        }),
    });
    b.installArtifact(image_builder_exe);

    const preserved_image_wire_mod = b.createModule(.{
        .root_source_file = b.path("packages/zvmi/src/preserved_image_wire.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const preserved_image_builder_exe = b.addExecutable(.{
        .name = "zvmi-preserved-image-builder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/preserved_image_builder.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
            },
        }),
    });
    b.installArtifact(preserved_image_builder_exe);
    const preserved_image_builder_tests = b.addTest(.{
        .root_module = preserved_image_builder_exe.root_module,
    });
    const run_preserved_image_builder_tests = b.addRunArtifact(
        preserved_image_builder_tests,
    );
    const preserved_image_wire_tests = b.addTest(.{
        .root_module = preserved_image_wire_mod,
    });
    const run_preserved_image_wire_tests = b.addRunArtifact(
        preserved_image_wire_tests,
    );
    const preserved_image_builder_test_step = b.step(
        "test-preserved-image-builder",
        "Run preserved-image host builder and wire tests",
    );
    preserved_image_builder_test_step.dependOn(
        &run_preserved_image_builder_tests.step,
    );
    preserved_image_builder_test_step.dependOn(
        &run_preserved_image_wire_tests.step,
    );

    const input_validator_mod = b.createModule(.{
        .root_source_file = b.path("cli/src/input_validator.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const input_validator_exe = b.addExecutable(.{
        .name = "zvmi-input-validator",
        .root_module = input_validator_mod,
    });
    b.installArtifact(input_validator_exe);
    const input_validator_tests = b.addTest(.{ .root_module = input_validator_mod });
    const run_input_validator_tests = b.addRunArtifact(input_validator_tests);

    const image_status_check_mod = b.createModule(.{
        .root_source_file = b.path("cli/src/image_status_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const image_status_check_exe = b.addExecutable(.{
        .name = "zvmi-image-status-check",
        .root_module = image_status_check_mod,
    });
    b.installArtifact(image_status_check_exe);
    const image_status_check_tests = b.addTest(.{ .root_module = image_status_check_mod });
    const run_image_status_check_tests = b.addRunArtifact(image_status_check_tests);

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
            .{ .name = "qemu_host", .module = qemu_host_mod },
        },
    }) });
    const run_boot_smoke_tests = b.addRunArtifact(boot_smoke_tests);
    const boot_smoke_step = b.step("test-boot-smoke", "Run opportunistic real-QEMU boot-smoke tests");
    boot_smoke_step.dependOn(&run_boot_smoke_tests.step);

    const unsafe_chroot_integration_exe = b.addExecutable(.{
        .name = "zvmi-unsafe-chroot-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unsafe_chroot_integration.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
            },
        }),
        .linkage = .static,
    });
    const run_unsafe_chroot_integration = b.addRunArtifact(
        unsafe_chroot_integration_exe,
    );
    const unsafe_chroot_integration_step = b.step(
        "test-unsafe-chroot-integration",
        "Run the privileged unsafe-chroot lifecycle integration",
    );
    unsafe_chroot_integration_step.dependOn(
        &run_unsafe_chroot_integration.step,
    );

    const host_qmp_mod = b.createModule(.{
        .root_source_file = b.path("qmp/src/qmp.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const host_qemu_host_mod = b.createModule(.{
        .root_source_file = b.path("qemu/host.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const freebsd_boot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/freebsd15_aarch64_boot.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qmp", .module = host_qmp_mod },
                .{ .name = "qemu_host", .module = host_qemu_host_mod },
            },
        }),
    });
    const run_freebsd_boot_tests = b.addRunArtifact(freebsd_boot_tests);
    const freebsd_boot_test_step = b.step(
        "test-freebsd15-aarch64-boot",
        "Run opt-in generalized FreeBSD 15.1 AArch64 QEMU acceptance",
    );
    freebsd_boot_test_step.dependOn(&run_freebsd_boot_tests.step);
    const unsafe_chroot_real_boot_exe = b.addExecutable(.{
        .name = "zvmi-unsafe-chroot-real-boot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unsafe_chroot_real_boot.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
                .{ .name = "qmp", .module = host_qmp_mod },
                .{ .name = "qemu_host", .module = host_qemu_host_mod },
            },
        }),
        .linkage = .static,
    });
    const run_unsafe_chroot_real_boot = b.addRunArtifact(
        unsafe_chroot_real_boot_exe,
    );
    const unsafe_chroot_real_boot_step = b.step(
        "test-unsafe-chroot-real-boot",
        "Run real TDNF/dracut customization and QEMU boot integration",
    );
    unsafe_chroot_real_boot_step.dependOn(
        &run_unsafe_chroot_real_boot.step,
    );

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

    // ---- azinit: standalone minimal PID 1 for real-boot testing of
    // --skip-iso-rootfs images ----
    // azinit always runs as PID 1 inside an x86_64 Azure Linux guest, so
    // unlike the rest of this repo it hardcodes its target rather than
    // using `target`/`optimize` above. Static linking keeps it fully
    // self-contained: no libc, no kmod, no other runtime dependency needs
    // to be present in the guest's root filesystem.
    const azinit_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });
    const azinit_cdrom_mod = b.createModule(.{
        .root_source_file = b.path("azagent/cdrom.zig"),
        .target = azinit_target,
        .optimize = .ReleaseSmall,
    });
    const azinit_mod = b.createModule(.{
        .root_source_file = b.path("azinit/init.zig"),
        .target = azinit_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "provisioning_media", .module = azinit_cdrom_mod },
        },
    });
    const azinit_exe = b.addExecutable(.{
        .name = "azinit",
        .root_module = azinit_mod,
        .linkage = .static,
    });
    b.installArtifact(azinit_exe);

    const azinit_test_cdrom_mod = b.createModule(.{
        .root_source_file = b.path("azagent/cdrom.zig"),
        .target = target,
        .optimize = optimize,
    });
    const azinit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("azinit/init.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "provisioning_media", .module = azinit_test_cdrom_mod },
            },
        }),
    });
    const run_azinit_tests = b.addRunArtifact(azinit_tests);
    const azinit_test_step = b.step("test-azinit", "Run azinit tests");
    azinit_test_step.dependOn(&run_azinit_tests.step);

    const test_step = b.step("test", "Run all tests");

    const build_api_consumer_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--help",
    });
    build_api_consumer_check.setName("check external build.zig consumer");
    build_api_consumer_check.setCwd(b.path("tests/build_api_consumer"));

    const build_api_diagnostics_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "diagnostics",
    });
    build_api_diagnostics_check.setName("check external build.zig diagnostics");
    build_api_diagnostics_check.setCwd(b.path("tests/build_api_consumer"));

    const build_api_execution_diagnostics_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "execution-diagnostics",
    });
    build_api_execution_diagnostics_check.setName("check external build.zig execution diagnostics");
    build_api_execution_diagnostics_check.setCwd(b.path("tests/build_api_consumer"));

    const build_api_preserved_diagnostics_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "preserved-diagnostics",
    });
    build_api_preserved_diagnostics_check.setName(
        "check external preserved-image build.zig diagnostics",
    );
    build_api_preserved_diagnostics_check.setCwd(b.path("tests/build_api_consumer"));

    // ---- scripts/build_generalized_azurelinux4.zig: generalized Azure Linux 4
    // QCOW2 builder, replacing scripts/build-generalized-azurelinux4.py.
    // Linux-specific: the full pipeline (dnf, sudo chroot, qemu-img) is only
    // meaningful on Linux.  The zstd_max_preload shared library is also
    // Linux-specific. ----
    if (b.graph.host.result.os.tag == .linux) {

        // Guest-targeted azagent for embedding in the generalized image.
        // Must be x86_64-linux (static) and ReleaseSmall, matching azinit.
        const zvmi_guest_mod = b.createModule(.{
            .root_source_file = b.path("packages/zvmi/src/root.zig"),
            .target = azinit_target,
            .optimize = .ReleaseSmall,
        });
        const wireserver_guest_mod = b.createModule(.{
            .root_source_file = b.path("wireserver/wireserver.zig"),
            .target = azinit_target,
            .optimize = .ReleaseSmall,
        });
        const azagent_guest_mod = b.createModule(.{
            .root_source_file = b.path("azagent/main.zig"),
            .target = azinit_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "wireserver", .module = wireserver_guest_mod },
                .{ .name = "zvmi", .module = zvmi_guest_mod },
            },
        });
        const azagent_guest_exe = b.addExecutable(.{
            .name = "azagent",
            .root_module = azagent_guest_mod,
            .linkage = .static,
        });

        // LD_PRELOAD shared library: intercepts ZSTD_compressStream2 and sets
        // ZSTD_maxCLevel() so qemu-img -o compression_type=zstd uses max compression.
        const zstd_preload_lib = b.addLibrary(.{
            .name = "zstd_max_preload",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("scripts/zstd_max_preload.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        // Link libdl for dlsym; libzstd is resolved at runtime via dlsym(RTLD_NEXT).
        zstd_preload_lib.root_module.linkSystemLibrary("dl", .{});
        b.installArtifact(zstd_preload_lib);

        const builder_mod = b.createModule(.{
            .root_source_file = b.path("scripts/build_generalized_azurelinux4.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
            },
        });
        const builder_exe = b.addExecutable(.{
            .name = "build_generalized_azurelinux4",
            .root_module = builder_mod,
        });
        b.installArtifact(builder_exe);

        // `zig build generalized-azurelinux4 -- [--iso ...] [--output ...] ...`
        // Automatically passes the paths of the just-built native zvmi, guest
        // azinit/azagent, and the preload library so the builder does not need to
        // invoke `zig build` itself.
        const run_builder = b.addRunArtifact(builder_exe);
        run_builder.step.dependOn(b.getInstallStep());
        run_builder.addArg("--zvmi");
        run_builder.addArtifactArg(cli_exe);
        run_builder.addArg("--azinit");
        run_builder.addArtifactArg(azinit_exe);
        run_builder.addArg("--azagent");
        run_builder.addArtifactArg(azagent_guest_exe);
        run_builder.addArg("--preload");
        run_builder.addArtifactArg(zstd_preload_lib);
        if (b.args) |args| run_builder.addArgs(args);
        const generalized_step = b.step(
            "generalized-azurelinux4",
            "Build a generalized Azure Linux 4 Gen2 QCOW2 image (requires root, Linux, dnf, qemu-img)",
        );
        generalized_step.dependOn(&run_builder.step);

        // Tests for pure, side-effect-free helpers.
        const builder_tests = b.addTest(.{
            .root_module = builder_mod,
        });
        const run_builder_tests = b.addRunArtifact(builder_tests);
        const builder_test_step = b.step("test-generalized-azurelinux4", "Run build_generalized_azurelinux4 unit tests");
        builder_test_step.dependOn(&run_builder_tests.step);
        test_step.dependOn(&run_builder_tests.step);

        const freebsd_builder_mod = b.createModule(.{
            .root_source_file = b.path("scripts/build_generalized_freebsd15_aarch64.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zvmi", .module = host_zvmi_mod },
                .{ .name = "qmp", .module = host_qmp_mod },
            },
        });
        const freebsd_builder_exe = b.addExecutable(.{
            .name = "build_generalized_freebsd15_aarch64",
            .root_module = freebsd_builder_mod,
        });
        b.installArtifact(freebsd_builder_exe);

        const run_freebsd_builder = b.addRunArtifact(freebsd_builder_exe);
        if (b.args) |args| run_freebsd_builder.addArgs(args);
        const generalized_freebsd_step = b.step(
            "generalized-freebsd15-aarch64",
            "Build a generalized FreeBSD 15.1 AArch64 QCOW2 (Linux, QEMU, UEFI)",
        );
        generalized_freebsd_step.dependOn(&run_freebsd_builder.step);

        const freebsd_builder_tests = b.addTest(.{
            .root_module = freebsd_builder_mod,
        });
        const run_freebsd_builder_tests = b.addRunArtifact(
            freebsd_builder_tests,
        );
        const freebsd_builder_test_step = b.step(
            "test-generalized-freebsd15-aarch64",
            "Run FreeBSD 15.1 AArch64 builder unit tests",
        );
        freebsd_builder_test_step.dependOn(&run_freebsd_builder_tests.step);
        test_step.dependOn(&run_freebsd_builder_tests.step);
    }

    test_step.dependOn(&run_zvmi_tests.step);
    test_step.dependOn(&run_wireserver_tests.step);
    test_step.dependOn(&run_qemu_host_tests.step);
    test_step.dependOn(&run_azagent_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_preserved_image_builder_tests.step);
    test_step.dependOn(&run_preserved_image_wire_tests.step);
    test_step.dependOn(&run_input_validator_tests.step);
    test_step.dependOn(&run_image_status_check_tests.step);
    test_step.dependOn(&run_qmp_mod_tests.step);
    test_step.dependOn(&run_qmp_exe_tests.step);
    test_step.dependOn(&run_qmp_codegen_tests.step);
    test_step.dependOn(&run_qmp_schema_tests.step);
    test_step.dependOn(&run_boot_smoke_tests.step);
    test_step.dependOn(&run_freebsd_boot_tests.step);
    test_step.dependOn(&run_unsafe_chroot_integration.step);
    test_step.dependOn(&run_nbd_mod_tests.step);
    test_step.dependOn(&run_nbd_exe_tests.step);
    test_step.dependOn(&run_nbd_server_tests.step);
    test_step.dependOn(&run_qcow2_mod_tests.step);
    test_step.dependOn(&run_qcow2_exe_tests.step);
    test_step.dependOn(&run_azinit_tests.step);
    test_step.dependOn(&build_api_consumer_check.step);
    test_step.dependOn(&build_api_diagnostics_check.step);
    test_step.dependOn(&build_api_execution_diagnostics_check.step);
    test_step.dependOn(&build_api_preserved_diagnostics_check.step);
}
