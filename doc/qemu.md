# QEMU

Use `zvmi qemu` to acquire and boot cataloged Azure Linux images with architecture-matched QEMU and firmware. See [Azure Linux images](azure-linux.md) for the full/core image comparison and release security model.

## Booting the release image with QEMU

Install QEMU once through ghr:

```text
ghr install cataggar/qemu
```

Then run the command from the directory where the VM disk should live:

```text
zvmi qemu AzureLinux
zvmi qemu AzureLinux-4.0-x86_64
```

If `AzureLinux-4.0-x86_64.qcow2` is absent, `zvmi` runs the verified ghr
download for
`cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux-4.0-20260723`.
Existing images are never refreshed or overwritten. QEMU and its matching
EDK2 firmware are resolved from the `cataggar/qemu` ghr installation first,
then from a system QEMU/UEFI installation. Directory-prefixed aliases such as
`zvmi qemu images/AzureLinux-4.0-x86_64` place the downloaded disk and
firmware under that directory.

The published images use the signed direct UKI boot path described in
[Azure Linux images](azure-linux.md). `zvmi qemu` does not silently enroll
release trust or claim Secure Boot; use the release acceptance path or
explicitly create enrolled variables. On Ubuntu x86_64, for example:

```text
virt-fw-vars \
  --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
  --output AzureLinux-4.0-x86_64.secboot-vars.fd \
  --add-db 7f32d4a1-7c10-4e6d-8a89-15ba3f4db734 release.crt \
  --secure-boot
qemu-system-x86_64 \
  -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,unit=1,format=raw,file=AzureLinux-4.0-x86_64.secboot-vars.fd \
  -drive file=AzureLinux-4.0-x86_64.qcow2,format=qcow2,if=virtio
```

Use `/usr/share/AAVMF/AAVMF_CODE.secboot.fd` and `/usr/share/AAVMF/AAVMF_VARS.ms.fd` for the equivalent AArch64 enrollment. `--architecture x86_64|aarch64` selects q35/OVMF or
virt/AAVMF respectively; `--architecture auto` requires an unambiguous
architecture-bearing GPT root/USR GUID or UKI PE header. `AzureLinux` remains
the short alias for the x86_64 Azure Linux image, while exact catalog aliases
select their corresponding architecture.

Inside a full image, equivalent manual checks are `mokutil --sb-state`, `mokutil --db`, `mokutil --dbx`, `cat /sys/kernel/security/lockdown`, and `sudo dmesg | grep -Ei 'secure boot|lockdown|module verification'`. Release acceptance parses the EFI variables directly so the core image does not need `mokutil`.

Before launch, the command creates or reuses a complete image-adjacent bundle:

```text
AzureLinux-4.0-x86_64.qcow2
AzureLinux-4.0-x86_64.code.fd
AzureLinux-4.0-x86_64.vars.fd
```

QEMU and matching EDK2 firmware are resolved from the `cataggar/qemu` ghr
installation first, then from a system QEMU/UEFI installation. Missing bundle
firmware is copied from raw sources or decompressed from `.fd.bz2` sources.
The installed QEMU package is never changed.

The default boot is persistent: QEMU writes directly to the image and its
`.vars.fd` guest UEFI state. Use snapshot mode when guest changes should be
discarded:

```text
zvmi qemu AzureLinux --snapshot
```

Snapshot mode uses the sibling `qemu-img` binary to create a temporary qcow2
overlay and creates temporary UEFI variables directly from the pristine
firmware source, not from the persistent `.vars.fd`. `zvmi` removes both when
QEMU exits. The automatic accelerator is WHPX for x86_64 Windows, HVF for
same-architecture macOS guests, KVM for same-architecture Linux guests when
`/dev/kvm` is available, and TCG otherwise. Override it when needed:

```text
zvmi qemu AzureLinux --accel tcg
```

An explicit image path must already exist. Without an architecture option it
keeps the x86_64 default; exact Azure Linux catalog filenames select their
corresponding architecture, and `aarch64` or `auto` can be used for other
Arm64 images:

```text
zvmi qemu ./AzureLinux-4.0-x86_64.qcow2
zvmi qemu custom.qcow2
```

The AArch64 profile is already wired for `qemu-system-aarch64`, `virt`, and
AArch64 EDK2 firmware:

```text
zvmi qemu AzureLinux-4.0-aarch64
```

The exact `AzureLinux-4.0-aarch64.qcow2` asset is downloaded from release
`AzureLinux-4.0-20260723` when it is not already present.

Use `--qemu`, `--firmware-code`, and `--firmware-vars` (or the compatible
`--ovmf-code`/`--ovmf-vars` names) for non-standard installations. Arguments
after `--` are appended directly to QEMU. The terminal is attached to
QEMU's `-nographic` serial console; use QEMU's `Ctrl+A`, then `X`, escape to
exit. With the default secure command line, a successful local boot reaches
the full image's systemd startup and login prompt. It does not emit
`zvminit` readiness markers.

Those markers apply only when an explicit `*.core.qcow2` image is selected.
A successful unprovisioned core boot reports that automatic Azure detection is
still pending, the diagnostic root shell is disabled, and the
`ZVMINIT_PID1_READY supervisor loop active` marker.

To provision an administrator at launch, supply
`--admin-username <name> --ssh-public-key <path>` together. `--ssh-port`
(default `2222`) forwards localhost TCP to guest SSH. The command creates a
short-lived hybrid `cidata` ISO containing NoCloud metadata/user-data, Azure
`ovf-env.xml`, and the explicit `zvmi-local-provisioning` marker, then removes
the seed and temporary launch state when QEMU exits.

This command is intentionally a focused launcher for the cataloged Azure Linux
Gen2 images plus compatible explicit disks, not a general VM configuration
manager.
