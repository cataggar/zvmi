# Getting started

## Requirements

- Zig **0.16.0** or later.
- `zvmi qemu` additionally requires [ghr](https://github.com/cataggar/ghr) for automatic known-image download. Install the packaged QEMU build with `ghr install cataggar/qemu`, or provide a system QEMU/UEFI installation.
- The released `zvmi` binary includes bzip2 support for packaged compressed firmware and does not require a system decompression tool.

## Build and run

```console
zig build
zig build test
zig build test-boot-smoke
zig build test-freebsd15-aarch64-boot
zig build run -- info foo.vhd
zig build run -- qemu
```

See [Image building](image-building.md) for advanced image commands, [Azure Linux images](azure-linux.md) for the hosted release recipes, and [FreeBSD images](freebsd.md) for the AArch64 FreeBSD workflow.
