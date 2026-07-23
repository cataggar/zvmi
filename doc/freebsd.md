# FreeBSD images

## Generalized FreeBSD 15.1 AArch64 QCOW2

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

See [Image building](image-building.md) for the shared image-format and Azure VHD tooling.
