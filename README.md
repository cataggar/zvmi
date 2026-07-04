# zvmi

A Zig 0.16 library and CLI for reading and writing VM disk image formats
(raw, VHD/VPC, qcow2, plus read-only VHDX) plus filesystem/image-build
orchestration, analogous to `qemu-img`.

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
                              #   resize/check/map; raw + fixed/dynamic vhd +
                              #   qcow2)
        fat32.zig             # FAT32 formatter + directory/file read/write
                              #   for partition-sized regions inside an Image
        vhd.zig               # VHD/VPC footer + dynamic header codec
                              #   (spec + QEMU-verified)
        vhdx.zig              # VHDX **read-only** codec (header, region
                              #   table, metadata, BAT -- QEMU-verified)
        qcow2.zig              # qcow2 codec (header, L1/L2 cluster mapping,
                              #   create/pwrite/resize)
        iso9660.zig            # ISO9660 **read-only** codec (PVD, Rock
                              #   Ridge, Joliet)
        squashfs.zig           # squashfs **read-only** codec (superblock,
                              #   inode/directory/fragment tables, XZ/zstd
                              #   compressed blocks)
        oci.zig                # local OCI/docker-save image ingestion
                              #   (layer extraction + whiteout-aware merge)
        ext4.zig              # minimal native ext4 writer + readback helper
                              #   (no journal, linear dirs, inline extents)
        bootconfig.zig         # ESP bootloader population (copy EFI binaries
                              #   + Secure Boot MOK/UKI orchestration)
        uki.zig                # low-level UKI/systemd-stub PE section
                              #   assembly helpers
        verity.zig             # dm-verity SHA-256 hash-tree generation +
                              #   kernel cmdline metadata helpers
        layout.zig             # partition-layout planner (sizing math,
                              #   alignment, DPS type GUIDs)
        guid.zig               # mixed-endian GUID encoding + well-known
                              #   partition type GUIDs (ESP, Linux data)
        mbr.zig                # MBR partition table codec (protective +
                              #   plain single-partition)
        gpt.zig                # GPT header + partition entry array codec
                              #   (CRC-32, spec-verified layout)
        azure.zig              # 1 MiB alignment + Gen1/Gen2 partition-style
                              #   checks (backs `zvmi azure fixup`)
        tar.zig                # minimal private USTAR reader/writer shared by
                              #   OCI layer ingestion and COSI packaging
        zstd.zig               # minimal private raw-block zstd codec for COSI
        cosi.zig               # COSI writer (tar + metadata.json + raw.zst parts)
        build_image.zig        # ISO + OCI -> raw/fixed-VHD orchestration
        formats.zig           # Format enum (raw, vhd, vhdx, qcow2)
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
        cosi.zig              # `zvmi cosi`
        build_image.zig       # `zvmi build-image`
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

## Status (Milestone 7)

Supports `raw`, fixed `vhd`, dynamic `vhd`, `qcow2`, MBR/GPT partition tables,
native FAT32 filesystem read/write for ESP-style partitions, native ESP
bootloader population (copy prebuilt EFI binaries + generate `grub.cfg`/BLS
text), an Azure-readiness check, **read-only** `vhdx`, **read-only** ISO9660
(+Rock Ridge/Joliet) and squashfs readers (including
XZ/zstd-compressed squashfs blocks), automatic unwrapping of nested ext4 or
squashfs rootfs images discovered inside squashfs payloads (matching LiveOS
media such as Azure Linux 4.0), local OCI container image ingestion, a minimal
native ext4 writer/readback library API, COSI output packaging, and a first
`zvmi build-image` orchestration path that builds `raw`, fixed-`vhd`, and
`qcow2` disk images from an ISO + local OCI layout:

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
zvmi cosi disk.img -o disk.cosi              # tar + metadata.json + per-partition raw.zst
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.vhd
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.raw -O raw
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.qcow2 -O qcow2
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G --verity -o output.vhd
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

Bootloader population lives at `zvmi.bootconfig`. It reuses the exact same
`FileTreeView` shape as `zvmi.ext4`, so future orchestration can drive rootfs
population plus either ESP/UEFI or BIOS/MBR boot installation from one merged
source-tree interface. For Gen2/GPT callers pass the planned GPT partitions
plus their unique GUIDs, then `populateEsp()` copies discovered
`EFI/.../*.efi` binaries into a FAT32 ESP and, depending on `boot_mode`,
generates the existing shim/GRUB/BLS text files, named `EFI/Linux/*.efi`
UKIs, or both. The same pass also copies shim/MOK auxiliary assets such as
`mm*.efi`, `MokManager`, and enrollment/config files that already exist in the
source tree. For Gen1/MBR, `installBiosBoot()` discovers prebuilt
`boot/grub2/i386-pc/boot.img` + `core.img` assets (or equivalent common
locations) and embeds them into the post-MBR gap ahead of the first 1 MiB
aligned root partition while preserving the existing MBR partition table.

```zig
try zvmi.bootconfig.populateEsp(allocator, io, &esp_fs, &tree, .{
    .planned_partitions = planned_partitions,
    .boot_mode = .bls_and_uki,
    .path_strip_prefix = "",
    .extra_kernel_options = "console=ttyS0",
    .uki = .{
        .output_directory = "EFI/Linux",
    },
});
```

The low-level PE/COFF rewriting lives in `zvmi.uki`, which takes a prebuilt
stub plus kernel/initrd/cmdline payloads and emits a structurally valid UKI
with `.linux`, `.initrd`, `.cmdline`, `.osrel`, `.uname`, and optional
`.splash` sections.

`zvmi build-image` currently writes `raw`, fixed `vhd`, and `qcow2` outputs.
`vhdx` remains a read-only source format for now, so `build-image` VHDX output
is still deferred pending separate VHDX write/create support. Both Gen2
(UEFI/protective-MBR+GPT+ESP) and Gen1 (BIOS/plain-MBR with GRUB embedded into
the post-MBR gap) are now fully wired in `zvmi build-image`, and both
generations can optionally append a same-partition dm-verity SHA-256 hash tree
with `--verity`, wiring the resulting `roothash=`/`systemd.verity_root_*`
parameters through the shared PARTUUID-based cmdline path. Gen1/MBR builds use
Linux's synthesized MBR PARTUUID form (`<8-hex-disk-signature>-<2-hex-partition-number>`);
the matching verity metadata is also exposed through `zvmi.cosi.writeWithOptions`.

## Notes on Zig 0.16

This codebase targets Zig 0.16's new `std.Io` interface: every filesystem,
clock, and randomness operation takes an explicit `io: std.Io` parameter
(via `std.process.Init.io` in the CLI, or `std.testing.io` in tests) rather
than relying on implicit global state.
