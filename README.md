# zvmi

A Zig 0.16 library and CLI for reading and writing VM disk image formats
(raw, VHD/VPC, VHDX, and qcow2) plus filesystem/image-build
orchestration, analogous to `qemu-img`.

## Install

Install the pre-built `zvmi` CLI from GitHub Releases with
[ghr](https://github.com/cataggar/ghr):

```console
ghr install cataggar/zvmi@v0.1.0
```

Release archives contain only the `zvmi` CLI. Build from source to use the
library or the repository's other tools.

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
        azure.zig             # Azure fixed-VHD derivation/readiness helpers
        cosi.zig              # `zvmi cosi`
        build_image.zig       # `zvmi build-image`
        qemu.zig              # `zvmi qemu`
        opts.zig              # shared `-o subformat=...` parsing
  zvminit/                  # minimal PID 1 for real-boot testing of
                              #   --skip-iso-rootfs images (see zvminit/README.md)
  qmp/                      # native Zig QEMU Machine Protocol (QMP) client,
                              #   MIT licensed (see qmp/README.md)
  qemu/
    host.zig                # shared host QEMU executable + OVMF discovery
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
    freebsd15_aarch64_boot.zig
                              #   opt-in generalized FreeBSD acceptance under
                              #   AArch64 UEFI QEMU, including SSH and reboot
  scripts/
    build_generalized_azurelinux4.zig  # generalized Azure Linux 4 Gen2 QCOW2
                              #   builder (run via `zig build generalized-azurelinux4`)
    build_generalized_freebsd15_aarch64.zig
                              #   generalized FreeBSD 15.1 AArch64 QCOW2
                              #   builder (run via `zig build generalized-freebsd15-aarch64`)
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
- `zvmi qemu` additionally requires [ghr](https://github.com/cataggar/ghr)
  for automatic image download. Install the packaged QEMU build with
  `ghr install cataggar/qemu`, or provide a system QEMU/OVMF installation.

## Build

```
zig build            # build the library + the zvmi CLI
zig build test       # run all tests (boot-smoke tests skip gracefully
                      #   without qemu-system-x86_64/OVMF/fixtures)
zig build test-boot-smoke  # run just the real-QEMU boot-smoke tests
zig build test-freebsd15-aarch64-boot
                      # run opt-in FreeBSD AArch64 QEMU/SSH/reboot acceptance
zig build run -- <args>   # run the CLI, e.g. `zig build run -- info foo.vhd`
zig build run -- qemu     # download (if needed) and boot the Azure Linux image
zig build -Dazurelinux-arch=x86_64 generalized-azurelinux4 -- [--iso <path>] [--output <path>] [--size <size>] [--work-dir <dir>]
                      # build a generalized Azure Linux 4 Gen2 QCOW2 image
                      #   (Linux-only; requires root, curl, dnf, qemu-img, sudo)
zig build generalized-freebsd15-aarch64 -- [--source <path>] [--output <path>] [--work-dir <dir>] [--base-only]
                      # build a generalized FreeBSD 15.1 AArch64 QCOW2
                      #   (Linux-only; requires curl, XZ Utils, qemu-img,
                      #   qemu-system-aarch64, AAVMF, xorriso, and networking)
```

## Use from another `build.zig`

Declare zvmi as a package dependency named `zvmi`, then import its build helper and use the returned `LazyPath` like any other generated file:

```zig
const std = @import("std");
const zvmi = @import("zvmi");

pub fn build(b: *std.Build) void {
    const dependency = b.dependencyFromBuildZig(zvmi, .{
        .target = b.graph.host,
    });

    const image = zvmi.addImage(b, dependency, .{
        .name = "appliance",
        .input = .{
            .iso = b.path("inputs/azurelinux.iso"),
            .container = .{ .oci_layout = b.path("inputs/oci-layout") },
        },
        .output = .{
            .format = .qcow2,
            .basename = "appliance.qcow2",
        },
        .size = 4 * 1024 * 1024 * 1024,
        .target_architecture = .x86_64,
        .generation = .gen2,
        .rootfs_path_in_iso = "images/rootfs.squashfs",
        .reproducibility = .{
            .seed = [_]u8{0x42} ** 32,
            .source_date_epoch = 1_735_689_600,
        },
        .os = .{
            .filesystem = &.{
                .{ .put_file = .{
                    .path = "/etc/appliance.conf",
                    .source = .{ .path = b.path("config/appliance.conf") },
                    .metadata = .{ .mode = 0o640 },
                } },
            },
            .hostname = "appliance",
            .users = &.{.{
                .name = "operator",
                .ssh_authorized_keys = &.{"ssh-ed25519 AAAA..."},
            }},
            .services = &.{.{ .name = "sshd.service", .state = .enabled }},
        },
        .generalization = .{ .azure = .{ .reset_hostname = false } },
        .verity = true,
    });

    const install = b.addInstallFile(image.path, "images/appliance.qcow2");
    const install_provenance = b.addInstallFile(image.provenance_path, "images/appliance.provenance.json");
    b.getInstallStep().dependOn(&install.step);
    b.getInstallStep().dependOn(&install_provenance.step);
}
```

Use `.container = .{ .archive = ... }` for a docker/podman save tarball. OCI layout directories are validated and snapshotted into the Zig build cache so adding, removing, or changing a blob invalidates the image step. Layouts containing symlinks or special files are rejected because Zig 0.16's cached directory-copy step cannot preserve them. The helper runs the dedicated `zvmi-image-builder` artifact for the build host even when the consuming project targets another architecture.

`addImage` accepts ordered file/directory/symlink/removal/metadata operations, hostname, groups, users and SSH keys, systemd service state, kernel-module settings, and Azure generalization. File inputs may be inline bytes or tracked `LazyPath` values; plaintext passwords are intentionally not representable, so callers must lock an account or provide a crypt-style pre-hashed value. The helper also returns `plan_path`, `diagnostics_path`, and `provenance_path` from image execution, plus `preflight_plan_path`, `preflight_diagnostics_path`, and `preflight_provenance_path` from a separate non-cacheable capability check. The preflight artifacts remain consumable even when its status gate blocks image execution; unavailable plan or provenance documents contain JSON `null`, while diagnostics explains the failure. Preflight and execution use separate build-cache bundle paths, so their plan hashes intentionally differ; execution repeats preflight against its exact resolved plan before mutation. Successful execution bundles are reused only when a content key covering the host builder, complete request arguments, ISO, container, customization document, and tracked files still matches; failed or stale bundles are cleared and retried instead of becoming permanent cache hits. The target architecture, rootfs path, deterministic seed, and source timestamp are explicit inputs; the resolved plan records generated identifiers and operation ordering, while provenance records source, final root-tree, and output SHA-256 hashes.

To transactionally edit an existing image, use the typed `addPreservedImage` helper:

```zig
const preserved = zvmi.addPreservedImage(b, dependency, .{
    .name = "updated-appliance",
    .input = .{
        .disk = b.path("inputs/appliance.qcow2"),
        .dependencies = &.{
            b.path("inputs/base.qcow2"),
            b.path("inputs/base-data.raw"),
        },
    },
    .root_partition = .{ .gpt_index = 2 },
    .output = .{
        .format = .qcow2,
        .basename = "updated-appliance.qcow2",
    },
    .target_architecture = .x86_64,
    .backend = .rebuild,
    .reproducibility = .{
        .seed = [_]u8{0x24} ** 32,
        .source_date_epoch = 1_735_689_600,
    },
    .operations = &.{
        .{ .overwrite_file = .{
            .path = "/etc/appliance.conf",
            .source = .{ .path = b.path("config/appliance.conf") },
        } },
        .{ .overwrite_file = .{
            .path = "/etc/build-id",
            .source = .{ .inline_bytes = "release-24\n" },
        } },
        .{ .remove_file = "/etc/obsolete.conf" },
        .{ .remove_tree = "/var/cache/obsolete" },
    },
    .os = .{
        .filesystem = &.{
            .{ .put_file = .{
                .path = "/etc/new-appliance.conf",
                .source = .{ .inline_bytes = "created-by=rebuild\n" },
            } },
            .{ .put_directory = .{ .path = "/opt/appliance" } },
        },
        .hostname = "updated-appliance",
    },
});
```

The disk, every transitive qcow2 backing or external-data file, the generated operation configuration, and every replacement are tracked `LazyPath` inputs; inline bytes are materialized through `WriteFiles`. Runtime preflight opens the disk read-only and requires the declared dependency set to exactly match its actual transitive qcow2 closure. The host-native runner preserves the source virtual size, flattens qcow2 dependencies into a standalone output, and returns the same result, preflight, and status-gate artifacts as `addImage`, including when the dependency was configured for a foreign target. GPT and MBR selectors are one-based.

`addPreservedImage` defaults to `.backend = .native_edit`, which only overwrites existing regular files, removes existing non-directories, and recursively removes existing directories. Select `.backend = .rebuild` to strictly import a writer-compatible `zvmi_ext4_v1` filesystem into owned storage, create/remove files, directories, and symlinks, change represented metadata, apply the pure OS customization model, and generalize the image before rebuilding only the selected partition. Rebuild preserves the ext4 UUID, exact label field, geometry, global timestamp, supported node contents/metadata/xattrs, and every byte outside the selected filesystem; it rejects arbitrary ext4 features, hardlinks, special or sparse files, divergent timestamps, noncanonical root metadata, and partition padding rather than discarding them. Native edit and rebuild do not resize partitions, run package managers, regenerate initramfs, or execute guest code.

Select `.backend = .unsafe_chroot` with `.acknowledge_unsafe = true` to use the first privileged preserved-image executor. It is Linux-only, requires effective root plus `CAP_SYS_CHROOT`, `CAP_SYS_ADMIN`, and `CAP_MKNOD`, and supports only same-architecture execution against an explicitly selected Linux ext4 partition. The current slice accepts online unlocked package install/remove actions through `/usr/bin/tdnf`, literal repository IDs with explicit trust material, and dracut regeneration for explicit kernel releases with `--no-hostonly`; dracut builds the replacement on the executor's private `/run` tmpfs before copying it over the existing guest initramfs, avoiding transient or duplicate persistent-space requirements. It rejects package updates, cache-only and version-lock policies, package paths/URLs/RPM files, existing-path and OS customization, generalization, hooks, SELinux changes, boot-policy changes, and cross-architecture runners before workspace mutation.

The unsafe executor runs in private mount and PID namespaces with a fresh minimal `/dev`, `/proc`, read-only `/sys`, tmpfs `/run`, isolated TDNF repository configuration, and optional read-only resolver binding. **This is cleanup isolation, not a security sandbox:** package managers and package scriptlets execute as root against the host kernel. Cleanup must unmount every child and detach the selected-partition loop device before publication; uncertain cleanup retains the transaction and active lease instead of deleting potentially mounted storage. Successful provenance records tool versions, exact mutation commands, and the final installed package NEVRAs.

Lower-level backends can use `zvmi.preserved_image.transactRaw` to flatten a source read-only into an exclusive raw stage, receive the selected partition geometry through a mutation hook, and publish raw, VHD, VHDX, or QCOW2 only after the hook releases every child, mount, loop attachment, and file reference. The transaction runtime pins staging-file identity and uses an external sealed lease barrier so cleanup never recursively removes an active backend workspace.

## Runtime customization API

The library exposes the same versioned request-plan runtime used by `addImage`:

```zig
const std = @import("std");
const customize = @import("zvmi").customize;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const request = customize.Request{
        .target_architecture = .x86_64,
        .input = .{ .iso_oci = .{
            .iso_path = "azurelinux.iso",
            .container_path = "oci-layout",
            .rootfs_path_in_iso = "images/rootfs.squashfs",
        } },
        .output = .{ .path = "appliance.qcow2", .format = .qcow2, .size = 4 * 1024 * 1024 * 1024 },
        .storage = .{ .fresh = .{} },
        .os = .{
            .filesystem = &.{
                .{ .put_file = .{
                    .path = "/etc/appliance.conf",
                    .source = .{ .host_path = "config/appliance.conf" },
                } },
            },
            .hostname = "appliance",
            .services = &.{.{ .name = "sshd.service", .state = .enabled }},
        },
        .generalization = .{ .azure = .{ .reset_hostname = false } },
        .execution = .{ .workspace_path = "." },
        .reproducibility = .{
            .seed = .{ .bytes = [_]u8{0x42} ** 32 },
            .source_date_epoch = 1_735_689_600,
        },
    };

    var resolved = try customize.resolve(allocator, &request, .{ .host_architecture = .x86_64 });
    defer resolved.deinit(allocator);
    if (resolved.plan == null) return error.InvalidConfiguration;

    var capabilities = try customize.preflight(allocator, init.io, &resolved.plan.?, customize.Platform.system());
    defer capabilities.deinit(allocator);
    if (!capabilities.ready()) return error.PreflightFailed;

    var outcome = try customize.execute(allocator, init.io, &resolved.plan.?, customize.Platform.system(), null);
    defer outcome.deinit(allocator);
    if (outcome.result == null) return error.ImageBuildFailed;
}
```

`resolve` is deterministic and does not inspect or mutate the host. The `native_fresh`, `native_edit`, strict `rebuild`, and `unsafe_chroot` backends require `workspace_path` to be the parent directory of `output.path`, keeping all planned scratch state on the destination filesystem for atomic publication. `preflight` returns all missing capabilities, and `execute` repeats preflight before mutation, stages the image in a planned transaction directory, verifies that source hashes remain unchanged, and atomically publishes the final output. Validation, preflight, and execution diagnostics are structured and independently owned; successful results include source hashes, resolved configuration, generated or preserved-image metadata, source/final rebuild tree manifests, and the final artifact hash.

`customize.current_api_version` identifies the v3 request contract. `adaptV2NativeFresh` explicitly converts the frozen v2 ISO+OCI/native request shape; v3 validation never silently reinterprets a request labeled as v2. Plan and provenance JSON have independent `schema_version` fields so artifact consumers can reject or migrate formats separately.

The v3 contract implements rootless `native_fresh`, constrained `native_edit`, strict writer-compatible `rebuild`, and the limited Linux `unsafe_chroot` package/initramfs slice described above. It also models the unimplemented `vm` backend, ordered hooks, SELinux policy, and cross-architecture runners; unsupported combinations derive semantic capabilities and fail preflight before workspace creation. Direct `customize.execute` users must provide a `Platform` with unsafe runtime callbacks, while `addPreservedImage` wires the host-native preserved-image builder automatically.

`zvmi.root_tree.RootTree` is the lower-level owned filesystem API. It spools bounded file and symlink content independently of ISO, SquashFS, OCI, or ext4 reader lifetimes; owns paths and POSIX metadata; applies deterministic replacement and recursive removal; and exposes a stable manifest digest. `ext4View()` adapts a validated tree to `zvmi.ext4.populate`, while `populateFat32()` either requires FAT-representable metadata or applies the caller's explicit lossy POSIX-metadata policy. Unsupported hardlinks, special files, timestamps, or metadata are rejected rather than silently discarded.

`zvmi.preserved_image.edit` is the lower-level constrained existing-path API, while `zvmi.preserved_image.rebuild` performs the strict full-tree rebuild described above. Both accept raw, VHD, VHDX, or qcow2 disks, copy guest-visible bytes into exclusive raw staging, flatten qcow2 backing chains, operate on an explicitly selected one-based GPT or MBR partition, convert to a standalone output, and publish without replacing an existing destination. Sources and backing files are opened read-only.

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
zvmi azure derive --input-sha256 <hex> input.qcow2 output.vhd  # transactional aligned Gen2 VHD + GPT relocation
zvmi azure fixup --generation 1|2 disk.vhd  # checks MBR/GPT; refuses unsafe GPT growth
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
zvmi qemu
zvmi qemu --snapshot
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
that minimal path (`zvminit` does this -- see `zvminit/README.md`). Generalized
images using `zvminit` must add `zvminit.mode=persistent` to the kernel command
line so provisioned users, SSH keys, host keys, and the azagent sentinel are
written to the root filesystem instead of ephemeral overlays. `zvminit` defaults
to `zvminit.azure=auto`: readable provisioning media or DHCP option 245 selects
Azure, while a completed DHCP lease with neither signal selects non-Azure and
skips `azagent`. Persistent decisions are stored under `/var/lib/azagent` and
bound to the current DMI product UUID; `zvmi azure deprovision` clears them.
Use `zvminit.azure=on` or `off` as a per-boot diagnostic override. Also add
`init=/sbin/zvminit` when the container includes systemd as an OpenSSH dependency,
ensuring the initramfs launches `zvminit` rather than systemd directly.
The serial root shell is disabled by default and released core-image command
lines do not enable it. `zvminit.shell=on` is an explicit diagnostic-only boot
override. PID 1 logs through `/dev/console`, discovers `ttyS*`/`ttyAMA*` and
other serial console names from the kernel command line or active-console
sysfs state, and emits `ZVMINIT_PID1_READY supervisor loop active` after
entering its child-reaping supervisor loop.

`azagent` validates OVF usernames using the conservative policy
`[a-z][a-z0-9_-]{0,31}` (no trailing `-`, and `root` is reserved) and validates
every public key as one printable line of at most 16 KiB containing a plausible
authorized_keys key-type/base64 pair. Local provisioning writes the existing
`/var/lib/azagent/provisioned` sentinel before Azure Ready acknowledgement.
Every normal invocation reports Ready even when that sentinel already exists,
and a WireServer failure is returned so `zvminit` retries without recreating
the account or keys. Synthetic local OVF media must contain the explicit
`zvmi-local-provisioning` marker; under the default `zvminit.azure=auto`,
only that marker makes `zvminit` invoke `azagent --skip-ready`. An unmarked OVF
document retains normal Azure Ready acknowledgement.
Azure still requires every generalized-VM deployment to supply an
`adminUsername`; use `g` for this image convention. The generated
`waagent.conf` mounts the temporary resource disk at `/d` and enables
managed-data-disk activation by stable Azure LUN at `/e` through `/z`. Managed
disks are mount-only: existing ext4 partition 1 is mounted, while blank and
unknown layouts are left untouched.

### Minimal generalized Azure Linux 4 QCOW2

Host-side image builders can reuse `zvmi.artifact_pipeline` for bounded SHA-256-verified acquisition and transactional publication. Download callbacks receive only a pipeline-owned writer rather than a staging path, `decompressXz` requires an explicit XZ Utils executable plus compressed-input digest, memory limit, and output-size limit, and Linux-only `finalizeQcow2` converts a digest-pinned raw or standalone QCOW2 source to a validated standalone QCOW2. `zvmi.azure.deriveFixedVhd` converts a digest-pinned standalone GPT QCOW2 into a 1 MiB-aligned fixed VHD through a descriptor-pinned atomic stage, strictly cross-validates the primary and backup GPT copies, preserves the raw partition array and every partition extent, relocates the backup GPT, and revalidates the VHD and both GPT copies before publication. All operations preserve an existing destination until validation succeeds.

`scripts/build_generalized_azurelinux4.zig` (run via
`zig build -Dazurelinux-arch=x86_64|aarch64 generalized-azurelinux4`) builds
the architecture-matched **core** recipe from
`mcr.microsoft.com/azurelinux-beta/base/core:4.0`: OpenSSH, static
`zvminit`/`azagent`, and no host identity. The build graph compiles those two
guest executables for the selected architecture while the CLI, builder, and
preload library remain native to the build host. A single architecture
descriptor pins and validates the official Azure Linux ISO digest, selected
OCI manifest, RPM key/package/stub, OCI config architecture, GPT root type,
UKI PE machine, fallback EFI filename, and serial console.

The recipe creates a bounded multi-layer OCI layout, builds a 1184 MiB Gen2
QCOW2 with a 512 MiB ESP and 670 MiB root partition, validates the finalized
disk and UKI structure, and compresses it to maximum zstd level via an
LD_PRELOAD intercept library (`scripts/zstd_max_preload.zig`). The x86_64
image uses `linuxx64.efi.stub`, `EFI/BOOT/BOOTX64.EFI`, and `ttyS0`; AArch64
uses `linuxaa64.efi.stub`, `EFI/BOOT/BOOTAA64.EFI`, and `ttyAMA0`.

The OpenSSH/sudo package transaction is also reproducibly locked: each
descriptor pins the Azure Linux base repository's `repomd.xml` SHA-256. The
builder verifies the live metadata, populates an isolated per-build DNF
cache/persist directory, verifies DNF's cached `repomd.xml`, and performs the
transaction with metadata expiration disabled globally and for
`azurelinux-base`. That prevents metadata refresh while allowing DNF to
download uncached RPM payloads. DNF then verifies RPM signatures and package
payload checksums from that pinned metadata. The cached and live metadata are
verified again after the transaction; a repository change fails the build. The
newly installed, sorted NEVRA closure is emitted and recorded under the builder
work directory's `provenance/` directory.

The image boots directly through `UEFI -> EFI/BOOT/BOOTX64.EFI` (x86_64) or
`EFI/BOOT/BOOTAA64.EFI` (AArch64) `-> UKI -> kernel/initramfs -> zvminit`; it
does not require shim, GRUB, or BLS configuration. The generated UKI is
currently unsigned, so Secure Boot must remain disabled. UKI signing and
Azure/QEMU trust are tracked in issue #168.

```console
# Defaults: AzureLinux-4.0-x86_64.core.qcow2 and
# .scratch/azurelinux4-core-x86_64
zig build -Dazurelinux-arch=x86_64 generalized-azurelinux4 --

# Defaults: AzureLinux-4.0-aarch64.core.qcow2 and
# .scratch/azurelinux4-core-aarch64
zig build -Dazurelinux-arch=aarch64 generalized-azurelinux4 --

# Either architecture may override its isolated output/cache namespace.
zig build -Dazurelinux-arch=aarch64 generalized-azurelinux4 -- \
  --work-dir /path/to/build-cache \
  --output /path/to/AzureLinux-4.0-aarch64.core.qcow2
```

The builder requires Zig 0.16, `curl`, `dnf`, GNU tar, `qemu-img`, and
passwordless or interactive `sudo`. On a host that differs from the selected
guest architecture, the matching enabled binfmt registration plus
`qemu-x86_64-static` or `qemu-aarch64-static` is required so RPM scriptlets
can run inside the target rootfs; the temporary interpreter is removed before
the OCI layout is produced. `--iso` accepts an already-downloaded ISO, but it
is still validated against the architecture's pinned official SHA-256. Use
`--size` to override the 1184 MiB virtual disk size. The fixed 512 MiB ESP is
retained when the total size is overridden, with the root partition consuming
the remaining aligned capacity. The build system automatically passes the
selected architecture and paths of the built native zvmi, guest
zvminit/azagent binaries, and preload library; no separate `zig build`
invocation is needed.

The release workflow matrix, QEMU acceptance, and Azure deployment remain
separate issue #178 work. This builder slice only provides the reproducible
architecture-aware core artifacts and structural validation; it does not
publish or deploy either image.

### Generalized FreeBSD 15.1 AArch64 QCOW2

The FreeBSD builder downloads the official `FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz`, verifies its pinned compressed SHA-256, and decompresses it with explicit memory and output limits. It boots a private mutable QCOW2 under AArch64 UEFI QEMU with a nonce-bound NoCloud seed, installs the pinned `azure-agent-2.15.0.1` package, enables SSH and generic `vtnet*` plus Azure `hn0` DHCP, applies FreeBSD's official Azure multi-console/115200-baud serial loader settings, removes the OS-disk swap entry, locks root, removes the default `freebsd` user, deprovisions waagent, and clears guest identity during a normal shutdown. Only an exact authenticated success marker followed by a clean QEMU exit permits transactional publication as a standalone zstd-compressed QCOW2.

```
zig build generalized-freebsd15-aarch64 -- \
  --work-dir /path/to/build-cache \
  --output /path/to/FreeBSD-15.1-RELEASE-arm64-aarch64-generalized.qcow2
```

The builder is Linux-only and requires Zig 0.16, `curl`, XZ Utils, `qemu-img`, `qemu-system-aarch64`, `xorriso`, AArch64 EDK2/AAVMF firmware, and outbound guest networking for the signed FreeBSD package installation. Use `--source` to supply the official compressed image without downloading it; the pinned checksum is still required unless explicitly overridden with `--source-sha256`. Firmware is discovered at the common `/usr/share/AAVMF` and `/usr/share/edk2/aarch64` locations or may be supplied with `--uefi-code` and `--uefi-vars`. `--accel auto` uses KVM on an AArch64 Linux host when `/dev/kvm` is accessible and TCG otherwise. `--base-only` retains the earlier verified-base behavior and does not require QEMU, firmware, xorriso, or guest networking.

The known-good local boot shape is `qemu-system-aarch64 -machine virt,accel=tcg -cpu max -smp 2 -m 2048` with a read-only AAVMF code pflash, a private writable copy of the AAVMF vars pflash, the QCOW2 as a virtio disk, a `cidata` ISO as a read-only virtio disk, a `virtio-net-pci` user-network device, `virtio-rng-pci`, and a serial console. The builder assembles this invocation automatically and supports explicit tool and firmware paths.

Run the opt-in acceptance test against a completed image:

```text
ZVMI_FREEBSD15_AARCH64_IMAGE=/path/to/FreeBSD-15.1-RELEASE-arm64-aarch64-generalized.qcow2 \
ZVMI_FREEBSD15_AARCH64_QEMU=/usr/bin/qemu-system-aarch64 \
zig build test-freebsd15-aarch64-boot
```

The test clearly skips when `ZVMI_FREEBSD15_AARCH64_IMAGE` is absent. When enabled, it boots two independent disposable overlays with fresh NoCloud seeds, proves each injected SSH key works, verifies the generalized agent/network/swap/account/identity state, reboots and reconnects to each guest, and powers off cleanly. Each guest's SSH host fingerprint and host UUID must remain stable across its reboot, while both values must differ between the two guests.

The manually dispatched **Rebuild FreeBSD 15.1 AArch64 release image** GitHub Actions workflow runs on a native `ubuntu-24.04-arm` hosted runner, caches the digest-pinned upstream source, builds and validates the generalized image, runs the dual-instance acceptance, and creates the versioned `FreeBSD15.1-aarch64-20260716.1` release with the QCOW2, checksum file, and complete source/build provenance. Build and test jobs have read-only repository access; a separate publication job receives the write token and refuses to use an existing release or tag.

The released QCOW2 can be derived into an Azure fixed VHD without changing its partitions:

```text
input_sha256=$(awk '{print $1}' FreeBSD-15.1-RELEASE-arm64-aarch64-generalized.qcow2.sha256)
zvmi azure derive \
  --input-sha256 "$input_sha256" \
  --expected-virtual-size 6477643776 \
  FreeBSD-15.1-RELEASE-arm64-aarch64-generalized.qcow2 \
  FreeBSD-15.1-RELEASE-arm64-aarch64-generalized.vhd
```

The released QCOW2 has SHA-256 `fa7f673b05702d26a06b614a6c1bd63b21c621f3ae2b4eb4c90ece112ebfd47c`. The resulting VHD has SHA-256 `2d05663027aa0c7df4b11def41749a6b4d802fe98fc86da0e4caa9cd729f438f`, a 6,478,102,528-byte aligned data region, and a 512-byte fixed-VHD footer. The source backup header at LBA 12,651,647 moves to LBA 12,652,543, its array moves immediately before it, and partition-array bytes and extents remain unchanged. The exact VHD was published as an Arm64 Gen2 Azure Compute Gallery version and validated on a fresh `Standard_D2pls_v5` VM: provisioning and `waagent` reached Ready, the injected SSH key and `hn0` DHCP worked, root remained locked with no swap, a guest-initiated reboot preserved host identity and SSH host keys, and managed Boot Diagnostics captured the complete 115200-baud FreeBSD kernel and rc startup without guest-side changes.

### Booting the release image with QEMU

Install QEMU once through ghr:

```text
ghr install cataggar/qemu
```

Then run the command from the directory where the VM disk should live:

```text
zvmi qemu
```

If `AzureLinux-4.0-x86_64.qcow2` is absent, `zvmi` runs the verified ghr
download for
`cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714`.
Existing images are never refreshed or overwritten. QEMU and its matching
EDK2 firmware are resolved from the `cataggar/qemu` ghr installation first,
then from a system QEMU/OVMF installation.

The published image uses the direct UKI boot path described above. Local QEMU
launches must keep Secure Boot disabled until the UKI signing work in issue
#168 is complete.

The default boot is persistent: QEMU writes directly to the image, and a
matching `AzureLinux-4.0-x86_64.vars.fd` UEFI variables file is created once
beside it and reused. Use snapshot mode when guest changes should be discarded:

```text
zvmi qemu --snapshot
```

Snapshot mode uses the sibling `qemu-img` binary to create a temporary qcow2
overlay plus a temporary UEFI variables copy; `zvmi` removes both when QEMU
exits. The automatic accelerator is WHPX on x86_64 Windows, HVF on x86_64
macOS, KVM on x86_64 Linux when `/dev/kvm` is available, and TCG otherwise.
Override it when needed:

```text
zvmi qemu --accel tcg
```

An explicit image path must already exist and is still launched as an x86_64
Gen2/UEFI VM:

```text
zvmi qemu custom.qcow2
```

Use `--qemu`, `--ovmf-code`, and `--ovmf-vars` for non-standard installations.
Arguments after `--` are appended directly to QEMU. The terminal is attached to
QEMU's `-nographic` serial console; use QEMU's `Ctrl+A`, then `X`, escape to
exit. With the default secure command line, a successful local boot reaches
the PID 1 readiness marker without exposing a root shell:

```text
[zvminit] non-Azure environment detected; skipping azagent
[zvminit] diagnostic root shell disabled
[zvminit] ZVMINIT_PID1_READY supervisor loop active
```

This command is intentionally a focused launcher for the published x86_64
Gen2 Azure Linux image, not a general VM configuration manager.

`convert` skips all-zero chunks (aligned to the destination's block size for
sparse block formats such as dynamic vhd and vhdx), so converting a
mostly-empty raw image into a sparse image stays sparse instead of eagerly
allocating every block it touches.

MBR/GPT partition-table read/write is available as a library API
(`zvmi.mbr`, `zvmi.gpt`, `zvmi.guid`) with round-trip test coverage, used by
`zvmi azure fixup` to validate the disk's partition style against the
requested Hyper-V generation (Gen1 = plain MBR, Gen2 = protective MBR + GPT).
Gen2 validation cross-checks both GPT headers and byte-identical partition
arrays. In-place fixup rejects unaligned GPT images before mutation; use
`zvmi azure derive` for transactional alignment and relocation.
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
