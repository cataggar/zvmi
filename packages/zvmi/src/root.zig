//! zvmi: a Zig library for reading and writing VM disk image formats
//! (raw, VHD/VPC, VHDX, and qcow2), analogous to qemu-img's
//! block-driver layer. See the project plan for the full format roadmap and
//! the Azure Linux + container build-image workflow this library exists to
//! support.
//!
//! Milestone 4 status: raw + fixed/dynamic vhd read/write, MBR + GPT
//! partition table read/write, FAT32 filesystem read/write, VHDX
//! **read-only**, and qcow2 **read-only**.

const std = @import("std");

pub const vhd = @import("vhd.zig");
pub const vhdx = @import("vhdx.zig");
pub const qcow2 = @import("qcow2.zig");
pub const fat32 = @import("fat32.zig");
pub const iso9660 = @import("iso9660.zig");
pub const squashfs = @import("squashfs.zig");
pub const guid = @import("guid.zig");
pub const mbr = @import("mbr.zig");
pub const gpt = @import("gpt.zig");
pub const azure = @import("azure.zig");
pub const layout = @import("layout.zig");
pub const oci = @import("oci.zig");
const image_mod = @import("image.zig");
const size_mod = @import("size.zig");

pub const Format = image_mod.Format;
pub const Image = image_mod.Image;
pub const Info = image_mod.Info;
pub const CreateOptions = image_mod.CreateOptions;
pub const VhdSubformat = image_mod.VhdSubformat;
pub const copyAll = image_mod.copyAll;

pub const parseSize = size_mod.parseSize;

test {
    std.testing.refAllDecls(@This());
}
