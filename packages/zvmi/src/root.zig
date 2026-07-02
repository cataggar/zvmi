//! zvmi: a Zig library for reading and writing VM disk image formats
//! (raw, VHD/VPC, and eventually VHDX/qcow2), analogous to qemu-img's
//! block-driver layer. See the project plan for the full format roadmap and
//! the Azure Linux + container build-image workflow this library exists to
//! support.
//!
//! Milestone 1 status: `raw` and fixed `vhd` read/write + convert. Dynamic
//! vhd, MBR/GPT, VHDX, and qcow2 are not implemented yet.

const std = @import("std");

pub const vhd = @import("vhd.zig");
const image_mod = @import("image.zig");
const size_mod = @import("size.zig");

pub const Format = image_mod.Format;
pub const Image = image_mod.Image;
pub const Info = image_mod.Info;
pub const copyAll = image_mod.copyAll;

pub const parseSize = size_mod.parseSize;

test {
    std.testing.refAllDecls(@This());
}
