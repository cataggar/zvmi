# zvmi

A Zig 0.16 library and CLI for reading and writing VM disk image formats
(raw, VHD/VPC, and eventually VHDX/qcow2) plus FAT32 filesystem contents,
analogous to `qemu-img`.

## Goal

Build a fixed, 1 MiB-aligned Azure-compatible VHD from the
[Azure Linux 4.0 ISO](https://aka.ms/azurelinux-4.0-x86_64.iso) plus a
container image, ready to upload as an Azure managed disk and run as a VM.
See the project plan for the full roadmap (format support, MBR/GPT,
container embedding, and the `zvmi build-image` orchestration command).

## Layout

```
zvmi/
  build.zig               # top-level build graph
  build.zig.zon            # package manifest
  packages/
    zvmi/                   # the core disk-image library
      src/
        root.zig             # public API surface
        image.zig            # format-agnostic Image (open/create/read/write,
                              #   resize/check/map; raw + fixed/dynamic vhd)
        fat32.zig             # FAT32 formatter + directory/file read/write
                              #   for partition-sized regions inside an Image
        vhd.zig               # VHD/VPC footer + dynamic header codec
                              #   (spec + QEMU-verified)
        vhdx.zig              # VHDX **read-only** codec (header, region
                              #   table, metadata, BAT -- QEMU-verified)
        ext4.zig              # minimal native ext4 writer + readback helper
                              #   (no journal, linear dirs, inline extents)
        guid.zig               # mixed-endian GUID encoding + well-known
                              #   partition type GUIDs (ESP, Linux data)
        mbr.zig                # MBR partition table codec (protective +
                              #   plain single-partition)
        gpt.zig                # GPT header + partition entry array codec
                              #   (CRC-32, spec-verified layout)
        azure.zig              # 1 MiB alignment + Gen1/Gen2 partition-style
                              #   checks (backs `zvmi azure fixup`)
        formats.zig           # Format enum (raw, vhd)
        size.zig              # qemu-img-style size suffix parsing (K/M/G/T)
  cli/
    src/
      main.zig               # `zvmi` executable entry point
      commands/
        create.zig            # `zvmi create`
        info.zig              # `zvmi info`
        convert.zig           # `zvmi convert`
        resize.zig            # `zvmi resize`
        check.zig             # `zvmi check`
        map.zig               # `zvmi map`
        azure.zig             # `zvmi azure fixup`
        opts.zig              # shared `-o subformat=...` parsing
```

## Requirements

- Zig **0.16.0** or later.

## Build

```
zig build            # build the library + the zvmi CLI
zig build test       # run all tests
zig build run -- <args>   # run the CLI, e.g. `zig build run -- info foo.vhd`
```

## Status (Milestone 5)

Supports `raw`, fixed `vhd`, dynamic `vhd`, MBR/GPT partition tables, native
FAT32 filesystem read/write for ESP-style partitions, an Azure-readiness
check, **read-only** `vhdx`, **read-only** `qcow2`, **read-only** ISO9660
(+Rock Ridge/Joliet) and squashfs readers, local OCI container image
ingestion, and a minimal native ext4 writer/readback library API:

```
zvmi create -f vhd disk.vhd 32M                          # dynamic by default (matches qemu-img)
zvmi create -f vhd -o subformat=fixed disk.vhd 32M       # required for Azure managed-disk upload
zvmi info disk.vhd
zvmi info --output=json disk.vhd
zvmi convert -f raw -O vhd -o subformat=dynamic disk.img disk.vhd
zvmi convert -f vhdx -O vhd -o subformat=fixed disk.vhdx disk.vhd  # import a VHDX (e.g. Hyper-V export)
zvmi resize disk.vhd +4G
zvmi check disk.vhd
zvmi map disk.vhd
zvmi azure fixup --generation 1|2 disk.vhd  # pads to 1 MiB, checks MBR/GPT
```

`convert` skips all-zero chunks (aligned to the destination's block size for
dynamic vhd), so converting a mostly-empty raw image into a dynamic vhd stays
sparse instead of eagerly allocating every block it touches.

MBR/GPT partition-table read/write is available as a library API
(`zvmi.mbr`, `zvmi.gpt`, `zvmi.guid`) with round-trip test coverage, used by
`zvmi azure fixup` to validate the disk's partition style against the
requested Hyper-V generation (Gen1 = plain MBR, Gen2 = protective MBR + GPT).
There is no interactive partitioning CLI command yet -- that lands with
`zvmi build-image`.

FAT32 filesystem support is currently library-only (`zvmi.fat32`). Callers
format a partition-sized region inside an existing `zvmi.Image`, then use the
returned/opened filesystem handle to create directories, write full file
contents, list directory entries, and read files back -- including VFAT long
file names such as typical `EFI/...` ESP paths.

VHDX support is read-only (`zvmi.vhdx`; usable via `info`/`convert`/`check`/
`map`, but not `create`), covering non-differencing images with 512-byte
logical sectors -- the common case. No real Hyper-V/QEMU install was
available in this environment to generate reference VHDX files, so
correctness was verified against QEMU's own `block/vhdx.c`/`vhdx.h` (struct
layout, CRC-32C checksums, and the BAT chunk-ratio interleaving formula) plus
a hand-built synthetic fixture exercised through the full `Image` API in
`packages/zvmi/src/image.zig`'s test suite.

Phase-1 ext4 lives at `zvmi.ext4`. The writer entry point is:

```zig
try zvmi.ext4.populate(io, file, allocator, &tree, .{
    .offset = 0,
    .length = fs_bytes,
    .block_size = 4096,
    .label = "rootfs",
});
```

`tree` is a small vtable-style `FileTreeView` owned by `ext4.zig`: each
`next()` yields a relative path plus `{ kind, mode, uid, gid, size }` and an
optional `content.readAt(buffer, offset)` callback for regular files and
symlinks. Paths are relative to the ext4 root; the root directory itself is
implicit. The phase-1 writer emits no journal, no dir_index/htree, and no
metadata checksums; it writes linear directory blocks plus inline extents in
each inode. The paired reader API can `statPath`, `listDir`, `preadPath`,
`readExtents`, and `readLinkAlloc` for round-trip verification.

qcow2 and the `zvmi build-image` Azure Linux + container workflow are future
milestones.

## Notes on Zig 0.16

This codebase targets Zig 0.16's new `std.Io` interface: every filesystem,
clock, and randomness operation takes an explicit `io: std.Io` parameter
(via `std.process.Init.io` in the CLI, or `std.testing.io` in tests) rather
than relying on implicit global state.
