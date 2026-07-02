# zvmi

A Zig 0.16 library and CLI for reading and writing VM disk image formats
(raw, VHD/VPC, and eventually VHDX/qcow2), analogous to `qemu-img`.

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
        image.zig            # format-agnostic Image (open/create/read/write)
        vhd.zig               # VHD/VPC fixed-footer codec (spec + QEMU-verified)
        formats.zig           # Format enum (raw, vhd)
        size.zig              # qemu-img-style size suffix parsing (K/M/G/T)
  cli/
    src/
      main.zig               # `zvmi` executable entry point
      commands/
        create.zig            # `zvmi create`
        info.zig              # `zvmi info`
        convert.zig           # `zvmi convert`
```

## Requirements

- Zig **0.16.0** or later.

## Build

```
zig build            # build the library + the zvmi CLI
zig build test       # run all tests
zig build run -- <args>   # run the CLI, e.g. `zig build run -- info foo.vhd`
```

## Status (Milestone 1)

Supports `raw` and fixed `vhd` formats only:

```
zvmi create -f vhd disk.vhd 32M
zvmi info disk.vhd
zvmi info --output=json disk.vhd
zvmi convert -f raw -O vhd disk.img disk.vhd
```

Dynamic VHD, MBR/GPT partitioning, VHDX, qcow2, and the `zvmi build-image`
Azure Linux + container workflow are future milestones.

## Notes on Zig 0.16

This codebase targets Zig 0.16's new `std.Io` interface: every filesystem,
clock, and randomness operation takes an explicit `io: std.Io` parameter
(via `std.process.Init.io` in the CLI, or `std.testing.io` in tests) rather
than relying on implicit global state.
