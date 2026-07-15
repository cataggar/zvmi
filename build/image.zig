const std = @import("std");

pub const Format = enum {
    raw,
    vhd,
    vhdx,
    qcow2,

    fn cliName(format: Format) []const u8 {
        return @tagName(format);
    }
};

pub const Generation = enum {
    gen1,
    gen2,

    fn cliName(generation: Generation) []const u8 {
        return switch (generation) {
            .gen1 => "1",
            .gen2 => "2",
        };
    }
};

pub const BootMode = enum {
    bls,
    uki,
    both,

    fn cliName(mode: BootMode) []const u8 {
        return @tagName(mode);
    }
};

pub const UkiOptions = struct {
    stub_source_path: ?[]const u8 = null,
    os_release_source_path: ?[]const u8 = null,
    splash_source_path: ?[]const u8 = null,
    output_directory: []const u8 = "EFI/Linux",
};

pub const Container = union(enum) {
    /// An OCI image-layout directory. The helper snapshots the complete
    /// directory into the build cache so additions and removals invalidate
    /// the image step, not just changes to the directory path.
    oci_layout: std.Build.LazyPath,
    /// A docker/podman save archive.
    archive: std.Build.LazyPath,
};

pub const Input = struct {
    iso: std.Build.LazyPath,
    container: Container,
};

pub const Output = struct {
    format: Format,
    basename: []const u8,
};

pub const Options = struct {
    name: []const u8,
    input: Input,
    output: Output,
    size: u64,
    generation: Generation = .gen2,
    rootfs_path_in_iso: ?[]const u8 = null,
    skip_iso_rootfs: bool = false,
    esp_size: ?u64 = null,
    ext4_label: []const u8 = "rootfs",
    verity: bool = false,
    extra_kernel_options: []const u8 = "",
    boot_mode: BootMode = .bls,
    uki: UkiOptions = .{},
    verbose: bool = false,
};

pub const Result = struct {
    path: std.Build.LazyPath,
    step: *std.Build.Step.Run,
};

pub fn add(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    options: Options,
) Result {
    const run = b.addRunArtifact(dependency.artifact("zvmi-image-builder"));
    run.setName(b.fmt("build image {s}", .{options.name}));

    run.addArg("--iso");
    run.addFileArg(options.input.iso);

    run.addArg("--container");
    switch (options.input.container) {
        .oci_layout => |layout| {
            const validate = b.addRunArtifact(dependency.artifact("zvmi-input-validator"));
            validate.setName(b.fmt("validate OCI layout for {s}", .{options.name}));
            validate.addDirectoryArg(layout);

            const snapshot = b.addWriteFiles();
            snapshot.step.name = b.fmt("snapshot OCI layout for {s}", .{options.name});
            snapshot.step.dependOn(&validate.step);
            const tracked_layout = snapshot.addCopyDirectory(layout, "oci-layout", .{});
            run.addDirectoryArg(tracked_layout);
        },
        .archive => |archive| run.addFileArg(archive),
    }

    run.addArgs(&.{ "--generation", options.generation.cliName() });
    run.addArgs(&.{ "--size", b.fmt("{d}", .{options.size}) });
    run.addArgs(&.{ "-O", options.output.format.cliName() });

    if (options.rootfs_path_in_iso) |path| {
        run.addArgs(&.{ "--rootfs-path", path });
    }
    if (options.skip_iso_rootfs) run.addArg("--skip-iso-rootfs");
    if (options.esp_size) |size| {
        run.addArgs(&.{ "--esp-size", b.fmt("{d}", .{size}) });
    }
    if (!std.mem.eql(u8, options.ext4_label, "rootfs")) {
        run.addArgs(&.{ "--ext4-label", options.ext4_label });
    }
    if (options.verity) run.addArg("--verity");
    if (options.extra_kernel_options.len != 0) {
        run.addArgs(&.{ "--extra-kernel-options", options.extra_kernel_options });
    }
    if (options.boot_mode != .bls) {
        run.addArgs(&.{ "--boot-mode", options.boot_mode.cliName() });
    }
    if (options.uki.stub_source_path) |path| {
        run.addArgs(&.{ "--stub-source-path", path });
    }
    if (options.uki.os_release_source_path) |path| {
        run.addArgs(&.{ "--os-release-source-path", path });
    }
    if (options.uki.splash_source_path) |path| {
        run.addArgs(&.{ "--splash-source-path", path });
    }
    if (!std.mem.eql(u8, options.uki.output_directory, "EFI/Linux")) {
        run.addArgs(&.{ "--uki-output-directory", options.uki.output_directory });
    }
    if (options.verbose) run.addArg("--verbose");

    run.addArg("--output");
    const output = run.addOutputFileArg(options.output.basename);

    return .{ .path = output, .step = run };
}
