//! Disk image format identifiers and (de)serialization helpers shared across
//! the library and the CLI. Mirrors qemu-img's `-f`/`-O` format names where
//! practical, e.g. `vpc` is qemu's name for this format; we accept both `vhd`
//! and `vpc` as aliases since `vhd` is the far more common spelling.

const std = @import("std");

pub const Format = enum {
    raw,
    vhd,

    pub fn parseName(name: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(name, "raw")) return .raw;
        if (std.ascii.eqlIgnoreCase(name, "vhd")) return .vhd;
        if (std.ascii.eqlIgnoreCase(name, "vpc")) return .vhd;
        return null;
    }

    pub fn displayName(self: Format) []const u8 {
        return switch (self) {
            .raw => "raw",
            .vhd => "vhd",
        };
    }
};

test "Format.parseName accepts vhd and vpc aliases" {
    try std.testing.expectEqual(Format.vhd, Format.parseName("vhd").?);
    try std.testing.expectEqual(Format.vhd, Format.parseName("VPC").?);
    try std.testing.expectEqual(Format.raw, Format.parseName("RAW").?);
    try std.testing.expect(Format.parseName("qcow2") == null);
}
