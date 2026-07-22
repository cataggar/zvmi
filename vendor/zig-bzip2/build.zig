const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.step("check", "Check that build.zig compiles. Used by zls for analysis.");

    const upstream = b.dependency("bzip2", .{});

    const big_files: []const []const u8 = &.{"-D_FILE_OFFSET_BITS=64"};
    const cflags: []const []const u8 = &.{ "-Wall", "-Winline", "-O2", "-g" };
    const flags = cflags ++ big_files;

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pic", "Produce Position Independent Code");

    const enable_bz2 = b.option(bool, "bz2", "Install the bz2 lib (default=true)") orelse true;
    const enable_bzip2 = b.option(bool, "bzip2", "Install the bzip2 exe (default=true)") orelse true;
    const enable_bzip2recover = b.option(bool, "bzip2recover", "Install the bzip2recover executable (default=true)") orelse true;

    const bz2_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .pic = pic,
    });
    bz2_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = bz2_src,
        .flags = flags,
    });

    const bz2 = b.addLibrary(.{
        .name = "bz2",
        .root_module = bz2_mod,
        .linkage = linkage,
    });
    bz2.installHeader(upstream.path("bzlib.h"), "bzlib.h");
    if (enable_bz2) b.installArtifact(bz2);

    const bzip2_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .pic = pic,
    });
    bzip2_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = bzip2_src,
        .flags = flags,
    });
    bzip2_mod.linkLibrary(bz2);

    const bzip2 = b.addExecutable(.{
        .name = "bzip2",
        .root_module = bzip2_mod,
    });
    if (enable_bzip2) b.installArtifact(bzip2);

    const bzip2recover_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .pic = pic,
    });
    bzip2recover_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = bzip2recover_src,
        .flags = flags,
    });
    const bzip2_recover = b.addExecutable(.{
        .name = "bzip2recover",
        .root_module = bzip2recover_mod,
    });
    if (enable_bzip2recover) b.installArtifact(bzip2_recover);
}

const bzip2_src: []const []const u8 = &.{
    "bzip2.c",
};

const bz2_src: []const []const u8 = &.{
    "blocksort.c",
    "huffman.c",
    "crctable.c",
    "randtable.c",
    "compress.c",
    "decompress.c",
    "bzlib.c",
};

const bzip2recover_src: []const []const u8 = &.{
    "bzip2recover.c",
};
