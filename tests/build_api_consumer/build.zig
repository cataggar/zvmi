const std = @import("std");
const zvmi = @import("zvmi");

pub fn build(b: *std.Build) void {
    const dependency = b.dependencyFromBuildZig(zvmi, .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });

    const layout_image = zvmi.addImage(b, dependency, .{
        .name = "layout-fixture",
        .input = .{
            .iso = b.path("fixtures/os.iso"),
            .container = .{ .oci_layout = b.path("fixtures/oci-layout") },
        },
        .output = .{
            .format = .qcow2,
            .basename = "layout-fixture.qcow2",
        },
        .size = 64 * 1024 * 1024,
    });

    const archive_image = zvmi.addImage(b, dependency, .{
        .name = "archive-fixture",
        .input = .{
            .iso = b.path("fixtures/os.iso"),
            .container = .{ .archive = b.path("fixtures/container.tar") },
        },
        .output = .{
            .format = .vhd,
            .basename = "archive-fixture.vhd",
        },
        .size = 64 * 1024 * 1024,
        .boot_mode = .both,
        .uki = .{
            .stub_source_path = "usr/lib/systemd/boot/efi/linuxx64.efi.stub",
            .os_release_source_path = "usr/lib/os-release",
            .splash_source_path = "usr/share/plymouth/splash.bmp",
            .output_directory = "EFI/Custom",
        },
    });

    const install_layout = b.addInstallFile(layout_image.path, "images/layout-fixture.qcow2");
    const install_archive = b.addInstallFile(archive_image.path, "images/archive-fixture.vhd");
    const image_step = b.step("image", "Build and install both fixture images");
    image_step.dependOn(&install_layout.step);
    image_step.dependOn(&install_archive.step);
}
