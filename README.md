# zvmi

A Zig 0.16 library and CLI for reading and writing VM disk image formats
(raw, VHD/VPC, VHDX, and qcow2) plus filesystem/image-build
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
                              #   vhdx + qcow2)
        fat32.zig             # FAT32 formatter + directory/file read/write
                              #   for partition-sized regions inside an Image
        vhd.zig               # VHD/VPC footer + dynamic header codec
                              #   (spec + QEMU-verified)
        vhdx.zig              # VHDX codec (header, region table, metadata,
                              #   BAT, create/pwrite/resize -- QEMU-verified)
        qcow2.zig              # qcow2 codec (header, L1/L2 cluster mapping,
                              #   create/pwrite/resize)
        iso9660.zig            # ISO9660 **read-only** codec (PVD, Rock
                              #   Ridge, Joliet)
        squashfs.zig           # squashfs **read-only** codec (superblock,
                              #   inode/directory/fragment tables, XZ/zstd
                              #   compressed blocks)
        oci.zig                # local OCI/docker-save image ingestion
                              #   (layer extraction + whiteout-aware merge)
        ext4.zig              # native ext4 writer + readback helper (htree
                              #   dirs, metadata checksums, extent trees,
                              #   offline resize; no journal)
        bootconfig.zig         # ESP bootloader population (copy EFI binaries
                              #   + Secure Boot MOK/UKI orchestration)
        uki.zig                # low-level UKI/systemd-stub PE section
                              #   assembly helpers
        verity.zig             # dm-verity SHA-256 hash-tree generation +
                              #   kernel cmdline metadata helpers
        cpio.zig               # minimal read-only newc-format cpio archive
                              #   reader (concatenated archives, e.g. dracut
                              #   early-cpio + main)
        initramfs.zig           # initramfs dm-verity userspace tooling
                              #   detection for `--verity` (issue #77)
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
        deprovision.zig        # offline image generalization: resets
                              #   hostname/SSH host keys/machine-id/DHCP
                              #   state (+ optional user removal) directly
                              #   via ext4.Editor (backs
                              #   `zvmi azure deprovision`; issue #110)
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
        azure.zig             # `zvmi azure fixup`, `zvmi azure deprovision`
        cosi.zig              # `zvmi cosi`
        build_image.zig       # `zvmi build-image`
        opts.zig              # shared `-o subformat=...` parsing
  azinit/                   # minimal PID 1 for real-boot testing of
                              #   --skip-iso-rootfs images (see azinit/README.md)
  qmp/                      # native Zig QEMU Machine Protocol (QMP) client,
                              #   MIT licensed (see qmp/README.md)
  nbd/                      # native Zig NBD client + reference server, MIT
                              #   licensed (see nbd/README.md)
  qcow2/                    # native Zig qcow2 reader/writer, MIT licensed
                              #   (see qcow2/README.md -- a separate,
                              #   standalone implementation from
                              #   packages/zvmi/src/qcow2.zig, kept for its
                              #   CLI + qemu-img cross-validation
                              #   methodology; see issue #96)
  wireserver/
    wireserver.zig            # native Zig client for the Azure WireServer
                              #   goal-state protocol (minimal provisioning
                              #   subset): version negotiation, goal-state
                              #   fetch, health reporting -- a building
                              #   block for the future `azagent` guest
                              #   provisioning executable (issue #112)
    xml.zig                   # minimal hand-rolled XML parser sufficient for
                              #   the concrete goal-state/health-report shapes
  azagent/                  # minimal guest provisioning agent for first-boot
                              #   Azure VM setup (issue #112); statically
                              #   linked, imports wireserver
    main.zig                  # entry point + provision() orchestration
    ovf.zig                   # ovf-env.xml parser (hostname/username/ssh keys)
    cdrom.zig                  # locates/mounts/reads ovf-env.xml off the
                              #   provisioning CD-ROM/DVD
    hostname.zig                # sethostname(2) + /etc/hostname
    passwd.zig                  # direct /etc/passwd,shadow,group editing
                              #   (useradd/usermod -L equivalent) + root
                              #   password lock
    sudoers.zig                 # /etc/sudoers.d/azagent NOPASSWD drop-in
    ssh_keys.zig                 # ~/.ssh/authorized_keys deployment + SSH
                              #   host key regeneration (ssh-keygen -A)
    sentinel.zig                # /var/lib/azagent/provisioned first-boot
                              #   sentinel
    waagent_conf.zig             # minimal /etc/waagent.conf reader (issue
                              #   #125): parses the real format, but only
                              #   honors a small explicit key whitelist --
                              #   not full waagent.conf compatibility
    root_resize.zig              # grows the root partition + ext4 filesystem
                              #   to fill a larger deployed disk (issue #130,
                              #   "growpart" equivalent); runs every boot,
                              #   not sentinel-gated
  tests/
    boot_smoke.zig          # opportunistic real-QEMU boot verification for
                              #   build-image output (Gen1/Gen2, --verity,
                              #   --boot-mode uki); driven by qmp, skips
                              #   gracefully when qemu-system-x86_64, OVMF, or
                              #   the ZVMI_BOOT_TEST_* fixture env vars aren't
                              #   available
  scripts/
    build_generalized_azurelinux4.zig  # generalized Azure Linux 4 Gen2 QCOW2
                              #   builder (run via `zig build generalized-azurelinux4`)
    zstd_max_preload.zig       # LD_PRELOAD shared library that forces maximum
                              #   zstd compression level in qemu-img
    ci/
      make-minimal-oci-fixture.py   # builds a tiny from-scratch OCI layout
                              #   used as the boot-smoke tests' --container
                              #   fixture in CI
  .github/
    workflows/
      ci.yml                 # required build + test for pushes and PRs
      boot-smoke.yml         # required for release tags; also manual
```

## Requirements

- Zig **0.16.0** or later.

## Build

```
zig build            # build the library + the zvmi CLI
zig build test       # run all tests (boot-smoke tests skip gracefully
                      #   without qemu-system-x86_64/OVMF/fixtures)
zig build test-boot-smoke  # run just the real-QEMU boot-smoke tests
zig build run -- <args>   # run the CLI, e.g. `zig build run -- info foo.vhd`
zig build generalized-azurelinux4 -- [--iso <path>] [--output <path>] [--size <size>] [--work-dir <dir>]
                      # build a generalized Azure Linux 4 Gen2 QCOW2 image
                      #   (Linux-only; requires root, curl, dnf, qemu-img, sudo)
```

## CI

`.github/workflows/ci.yml` runs the required `zig fmt --check`, `zig build`, and `zig build test` checks on every pull request and push to `main`.

`.github/workflows/boot-smoke.yml` runs `zig build test-boot-smoke` for every release tag and when manually dispatched. It installs `qemu-system-x86`/`ovmf`, downloads and caches the [Azure Linux 4.0 ISO](https://aka.ms/azurelinux-4.0-x86_64.iso), and builds the OCI fixtures used by the real-QEMU tests. The job is required (not `continue-on-error`) for release tags but is not part of universal pull-request CI.

## Status (Milestone 7)

Supports `raw`, fixed `vhd`, dynamic `vhd`, `vhdx`, `qcow2`, MBR/GPT partition tables,
native FAT32 filesystem read/write for ESP-style partitions, native ESP
bootloader population (copy prebuilt EFI binaries + generate `grub.cfg`/BLS
text), an Azure-readiness check, **read-only** ISO9660
(+Rock Ridge/Joliet) and squashfs readers (including
XZ/zstd-compressed squashfs blocks), automatic unwrapping of nested ext4 or
squashfs rootfs images discovered inside squashfs payloads (matching LiveOS
media such as Azure Linux 4.0), local OCI container image ingestion, a minimal
native ext4 writer/readback library API, COSI output packaging, and a first
`zvmi build-image` orchestration path that builds `raw`, fixed-`vhd`, `vhdx`,
and `qcow2` disk images from an ISO + local OCI layout:

```
zvmi create -f vhd disk.vhd 32M                          # dynamic by default (matches qemu-img)
zvmi create -f vhd -o subformat=fixed disk.vhd 32M       # required for Azure managed-disk upload
zvmi info disk.vhd
zvmi info --output=json disk.vhd
zvmi convert -f raw -O vhd -o subformat=dynamic disk.img disk.vhd
zvmi convert -f raw -O vhdx disk.img disk.vhdx
zvmi convert -f vhdx -O vhd -o subformat=fixed disk.vhdx disk.vhd  # import a VHDX (e.g. Hyper-V export)
zvmi resize disk.vhdx +4G
zvmi resize disk.vhd +4G
zvmi check disk.vhd
zvmi map disk.vhd
zvmi azure fixup --generation 1|2 disk.vhd  # pads to 1 MiB, checks MBR/GPT
zvmi azure deprovision disk.vhd                    # generalize: reset hostname/SSH host keys/machine-id/DHCP state
zvmi azure deprovision --user azureuser disk.vhd   # also removes that user account + its home directory
zvmi cosi disk.img -o disk.cosi              # tar + metadata.json + per-partition raw.zst
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.vhd
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.raw -O raw
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.vhdx -O vhdx
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G -o output.qcow2 -O qcow2
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 384M --skip-iso-rootfs -o output-minimal.raw -O raw
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G --verity -o output.vhd
zvmi build-image --iso azurelinux.iso --container ./oci-layout --generation 2 --size 4G --boot-mode uki --esp-size 512M -o output-uki.vhd
```

`--skip-iso-rootfs` is useful with genuinely minimal base containers: it keeps
the container as the effective root filesystem and carries over only the
boot-critical assets from the ISO/squashfs (kernel, initramfs, EFI binaries,
Secure Boot helpers, BIOS GRUB stage images, and the installed rootfs's
`/lib/modules/<kernel-version>` tree -- kept in full, since loadable drivers
that aren't statically built into the kernel, e.g. Azure's Hyper-V
`hv_netvsc`/Mellanox `mlx5` NIC drivers, otherwise fail to load on real
hardware even though they work under local QEMU testing where `virtio_net`
happens to be statically built in), instead of merging the
entire live/installer rootfs into the final disk.

For `--boot-mode uki` or `--boot-mode both`, the default 96 MiB ESP is sized
for the GRUB+BLS path and is often too small for real distro UKIs. Start with
`--esp-size 512M` and increase it further if your kernel+initrd payloads are
especially large.

UKI generation also requires a systemd EFI stub such as `linuxx64.efi.stub`
or `linuxaa64.efi.stub`, typically from the `systemd-boot-unsigned` package,
to exist somewhere in the merged ISO/squashfs/container source tree. If the
base OS image does not ship it, inject that package via an extra container
layer or point `--stub-source-path` at the non-standard in-tree path where you
added the stub.

If `usr/sbin/azagent` (the guest provisioning agent -- see `azagent/` above,
issue #112) is present anywhere in the merged ISO/squashfs/container source
tree, `build-image` automatically installs and enables a oneshot
`azagent.service` systemd unit that runs it once at first boot, mirroring
real `waagent.service`. As with the UKI stub, `zvmi` never builds or injects
the `azagent` binary itself -- add it via an extra container layer,
cross-compiled for the image's target architecture. This only applies to a
full (non-`--skip-iso-rootfs`) image, since its systemd comes from the
merged distro content; a `--skip-iso-rootfs` image's `/sbin/init` is
responsible for invoking `azagent` itself if it wants first-boot
provisioning, since there's no guarantee of systemd being present at all in
that minimal path (`azinit` does this -- see `azinit/README.md`). Generalized
images using `azinit` must add `azinit.mode=persistent` to the kernel command
line so provisioned users, SSH keys, host keys, and the azagent sentinel are
written to the root filesystem instead of ephemeral overlays. Also add
`init=/sbin/init` when the container includes systemd as an OpenSSH dependency,
ensuring the initramfs launches `azinit` rather than systemd directly.
Azure still requires every generalized-VM deployment to supply an
`adminUsername`; use `g` for this image convention. The generated
`waagent.conf` mounts the temporary resource disk at `/d` and enables
managed-data-disk activation by stable Azure LUN at `/e` through `/z`. Managed
disks are mount-only: existing ext4 partition 1 is mounted, while blank and
unknown layouts are left untouched.

### Minimal generalized Azure Linux 4 QCOW2

`scripts/build_generalized_azurelinux4.zig` (run via `zig build generalized-azurelinux4`) provides the complete reproducible recipe used for the generalized Azure image: it downloads and verifies the official Azure Linux 4 ISO, pulls `mcr.microsoft.com/azurelinux-beta/base/core:4.0`, installs signed x86_64 `openssh-server` and `sudo` packages, injects static `azinit`/`azagent`, removes host identity, creates a bounded multi-layer OCI layout, builds a 768 MiB Gen2 QCOW2, and compresses it to maximum zstd level via an LD_PRELOAD intercept library (`scripts/zstd_max_preload.zig`).

```
zig build generalized-azurelinux4 -- \
  --work-dir /path/to/build-cache \
  --output /path/to/zvmi-azurelinux4-generalized.qcow2
```

The builder requires Zig 0.16, `curl`, `dnf`, GNU tar, `qemu-img`, and passwordless or interactive `sudo`. On a non-x86_64 build host, x86_64 binfmt and `qemu-x86_64-static` are also required so RPM scriptlets can run inside the target rootfs; on Azure Linux install them with `sudo tdnf install -y qemu-user-static-x86`. Use `--iso` to supply an already-downloaded ISO and `--size` to override the 768 MiB virtual disk size. The build system automatically passes the paths of the built native zvmi, guest azinit/azagent binaries, and the preload library; no separate `zig build` invocation is needed.

`convert` skips all-zero chunks (aligned to the destination's block size for
sparse block formats such as dynamic vhd and vhdx), so converting a
mostly-empty raw image into a sparse image stays sparse instead of eagerly
allocating every block it touches.

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

VHDX support (`zvmi.vhdx`) covers create/read/write/resize/check for
non-differencing images with 512-byte logical sectors -- the common case.
`zvmi build-image` can emit VHDX output directly, and `convert`/`resize`
operate on VHDX images the same way they already do for raw/VHD/qcow2. No real Hyper-V/QEMU install was
available in this environment to generate reference VHDX files, so
correctness was verified against QEMU's own `block/vhdx.c`/`vhdx.h` (struct
layout, CRC-32C checksums, the BAT chunk-ratio interleaving formula, and the
create-path metadata layout) plus writable round-trip tests exercised through
both `zvmi.vhdx` and the full `Image` API in the test suite.

ext4 support lives at `zvmi.ext4`. The writer entry point is:

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
implicit. The writer emits `DIR_INDEX` htree directories (with interior
index nodes once a directory outgrows a single root index block),
`METADATA_CSUM` crc32c checksums on bitmaps/GDTs/superblocks/inodes/
directory leaf blocks/xattr blocks, and extent trees (inline for small
files, spilling into real extent/index blocks up to depth 4 for larger or
fragmented ones); it deliberately ships without a journal or quota files,
since the target image-build flow creates filesystems offline and writes
them atomically. `resize()` supports offline, in-place growth. The paired
reader API can `statPath`, `listDir`, `preadPath`, `readExtents`, and
`readLinkAlloc` for round-trip verification.

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

`zvmi build-image` currently writes `raw`, fixed `vhd`, `vhdx`, and `qcow2`
outputs. Both Gen2
(UEFI/protective-MBR+GPT+ESP) and Gen1 (BIOS/plain-MBR with GRUB embedded into
the post-MBR gap) are now fully wired in `zvmi build-image`, and both
generations can optionally append a same-partition dm-verity SHA-256 hash tree
with `--verity`, wiring the resulting `roothash=`/`systemd.verity_root_*`
parameters through the shared PARTUUID-based cmdline path. Gen1/MBR builds use
Linux's synthesized MBR PARTUUID form (`<8-hex-disk-signature>-<2-hex-partition-number>`);
the matching verity metadata is also exposed through `zvmi.cosi.writeWithOptions`.

`zvmi build-image` never rebuilds the initramfs -- it copies whatever
`boot/initramfs*`/`boot/initrd*` blob already exists in the merged
ISO/squashfs/container source tree. Because of that, `--verity` only works
end-to-end if that source initramfs already includes dm-verity userspace
tooling (`systemd-veritysetup-generator`, `systemd-veritysetup`, or
`veritysetup`, e.g. built with `dracut --add systemd-veritysetup`); without it,
`systemd-veritysetup-generator` never runs at boot and the image hangs
forever waiting on `/dev/mapper/root` (see
[issue #77](https://github.com/cataggar/zvmi/issues/77) for the real-boot
investigation that diagnosed this). `build-image --verity` inspects the
selected initramfs (decompressing it as needed) and fails fast with a
`--verity`-specific error when it can conclusively tell the tooling is
missing, rather than silently producing an image that hangs at boot; if the
initramfs can't be fully parsed (e.g. an unrecognized compression format),
it instead prints a warning and proceeds.

### Producing a verity-capable initramfs (e.g. for Azure Linux)

Live/installer media (such as the Azure Linux ISO) typically ships an
initramfs built for the installer environment itself, which has no need for
dm-verity and so is usually missing the pieces above even when the installed
system's own root filesystem has them (`systemd-udev`'s
`systemd-veritysetup-generator`/`systemd-veritysetup`, and
`cryptsetup`/`veritysetup`'s `libcryptsetup`, plus the `dm-verity`/`dm-mod`
kernel modules). Regenerate the initramfs with `dracut --add systemd-veritysetup`
against a rootfs that has these installed, then supply the result as a
`--container` layer at the *same* `boot/initramfs-<kver>.img` path already
used by the ISO/squashfs rootfs -- OCI container layers always take
precedence over ISO/squashfs entries at the same path, so no `zvmi` flag is
needed to use it in place of the stock copy.

On a matching-architecture build host (or inside a container/chroot for that
architecture), this is a normal, native `dracut` invocation:

```bash
dracut --add systemd-veritysetup --force --kver <kernel-version> /path/to/initramfs-verity.img
```

Building this cross-architecture (e.g. generating an x86_64 initramfs on an
aarch64 build host, via `qemu-user`/`binfmt_misc` emulation) additionally
needs:

- `dracut --sysroot <mounted-or-extracted-rootfs> --no-hostonly --add
  systemd-veritysetup --force --kver <kernel-version> <output>` (`<output>`
  is a positional argument -- dracut's `-o`/`--omit` flag means something
  else entirely: a list of dracut modules to omit), with
  `DRACUT_ARCH=<target-arch>` and `QEMU_LD_PREFIX=<sysroot>` exported so the
  emulated target-arch helper binaries (e.g. `dracut-install`) can find their
  own shared libraries.
- A working cross-arch `ldd` on `PATH`: dracut-install invokes the plain
  `ldd` command by name to resolve each installed binary's shared-library
  dependencies, but a host system's own `ldd` script typically refuses
  foreign-architecture binaries outright (printing `not a dynamic
  executable`) rather than actually resolving them, which silently drops
  every shared library (including the dynamic loader itself) from the
  generated initramfs -- producing an initramfs that panics at boot with
  `Failed to execute /init`. Shadow `ldd` on `PATH` with a small wrapper that
  invokes the target's own dynamic linker in list mode instead, e.g.:
  ```bash
  #!/bin/bash
  # save as e.g. /tmp/fakebin/ldd (with /tmp/fakebin first on PATH)
  exec qemu-x86_64 -L "$QEMU_LD_PREFIX" "$QEMU_LD_PREFIX/lib64/ld-linux-x86-64.so.2" --list "$1"
  ```

This was verified end-to-end with a real QEMU + OVMF boot of a Gen2 +
`--verity` Azure Linux 4.0 image built this way: the image reaches a real
login prompt and root shell with `veritysetup.target` active.


## Notes on Zig 0.16

This codebase targets Zig 0.16's new `std.Io` interface: every filesystem,
clock, and randomness operation takes an explicit `io: std.Io` parameter
(via `std.process.Init.io` in the CLI, or `std.testing.io` in tests) rather
than relying on implicit global state.

## License

MIT -- see [LICENSE](LICENSE).
