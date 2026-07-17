# zvminit

A minimal (~160 KB), statically-linked PID 1 replacement for real-boot testing of images built with `zvmi build-image --skip-iso-rootfs`, e.g. against a real Azure VM. It exists to validate the fix for [issue #88](https://github.com/cataggar/zvmi/issues/88) end-to-end on real hardware rather than only structurally/in QEMU, and to serve as a small reference for what a from-scratch container-image init needs to do.

## What it does

- Mounts `/proc`, `/sys`, `/dev`, and `/run`. Immutable mode is the default: root stays read-only, `/var` and `/tmp` use tmpfs, and `/etc` uses a tmpfs-backed overlay. The opt-in `zvminit.mode=persistent` kernel option instead remounts root read-write, leaves `/etc`, `/var`, and `/home` persistent, and mounts only `/tmp` as tmpfs. If `/etc/machine-id` is empty after image generalization, zvminit generates and persists a new 128-bit machine ID.
- Loads the kernel modules this appliance needs directly via a raw `init_module()` syscall (decompressing the shipped `.ko.xz` with `std.compress.xz`): `overlay` for immutable `/etc`, `hv_netvsc` for Hyper-V networking, and `crc-itu-t`/`udf`/`isofs` for Azure's provisioning DVD. There's no udev/mdev daemon to drive `request_module()` through modprobe/kmod, so zvminit loads the fixed dependency order itself.
- Mounts the ESP, sets the hostname, brings up loopback, then runs a small
  DHCP client on the first non-`lo` interface it finds and writes
  `/etc/resolv.conf`. DHCP replies are received on a raw `AF_PACKET` socket
  bound to the interface rather than a plain UDP socket: on Azure's SDN
  fabric (unlike simpler local QEMU networking), the kernel's normal IPv4
  input path drops broadcast-destined DHCP replies before they reach a
  `recvfrom()` on an `AF_INET`/`SOCK_DGRAM` socket, because the interface
  has no IP configured yet and there's no local route to validate the relay
  address against (logged as `IPv4: martian source ... on dev ethN`). A raw
  packet socket taps the device's receive path before that check applies --
  the same technique real DHCP clients (dhclient/udhcpc/systemd-networkd)
  use.
- Installs `SIGTERM`/`SIGINT` handlers that cleanly power off/reboot, and
  doubles as `/sbin/poweroff`, `/sbin/reboot`, `/sbin/shutdown` (dispatched
  by `argv[0]`) so the kernel's `orderly_poweroff()` usermode-helper path
  (driven by Hyper-V's shutdown integration service) has something to exec.
- Loops forever spawning an interactive shell on `/dev/ttyS0`, respawning it
  if it ever exits (PID 1 exiting panics the kernel), and reaping all other
  zombie children along the way.
- Detects Azure before launching `azagent`. Automatic detection accepts either
  a readable `ovf-env.xml` provisioning disc or DHCP option 245, and classifies
  a completed DHCP lease with neither signal as non-Azure. Persistent mode
  stores the result in `/var/lib/azagent/azure-environment`, bound to the
  current DMI product UUID so moving the disk to a different VM forces
  redetection. Failed DHCP or not-yet-readable media remains unknown and is
  retried without repeatedly launching `azagent`.
- If `/usr/sbin/azagent` (the guest provisioning agent, see `azagent/`, issue #112) is present, fork+execs it after networking is up so a `--skip-iso-rootfs` image can reach a provisioned login instead of only a bare shell. Immutable mode retains a single best-effort run when detection is inconclusive. Persistent mode retries every five seconds only after Azure is detected or forced, while keeping the serial shell available.
- If `/usr/sbin/sshd` is present, fork+execs it after provisioning succeeds. In persistent mode, an existing provisioning sentinel also permits SSH to start when `azagent` is skipped, while a fresh non-Azure image remains serial-only. This remains one hardcoded fork+exec rather than a general service supervisor and uses the configuration shipped by the container image.

## Building

Built as part of the repo-root build graph (there's no separate `zvminit/build.zig`):

```
zig build
zig build test-zvminit
```

The installed executable always cross-compiles to static `x86_64-linux` regardless of host, since that's what these real Azure Gen2 VM fixtures run; there's no `-Doptimize=` toggle because the binary hardcodes `ReleaseSmall`. The tests build for the selected native test target.

## Using it

Add the built `zig-out/bin/zvminit` binary to a container image as
`sbin/zvminit`, with relative `sbin/init`, `sbin/poweroff`, `sbin/reboot`, and
`sbin/shutdown` symlinks pointing to `zvminit`, then build an immutable bootable
disk image with:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-zvminit> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```

For a generalized Azure image, include `/usr/sbin/azagent`, `/usr/sbin/sshd`, `ssh-keygen`, and their runtime dependencies in the container, then opt into persistent mode:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-zvminit-agent-sshd> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "init=/sbin/zvminit zvminit.mode=persistent zvminit.azure=auto console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```

`init=/sbin/zvminit` is required when the packaged OpenSSH dependency set includes systemd; otherwise the systemd-based initramfs selects `/usr/lib/systemd/systemd` directly instead of zvminit. Persistent mode is intentionally incompatible with a read-only dm-verity root. If the root remount fails, zvminit leaves provisioning and SSH disabled and retains serial-console access for diagnosis.

`zvminit.azure=auto` is the default. Use `zvminit.azure=on` to force provisioning retries when Azure's early-boot signals are unavailable, or `zvminit.azure=off` to suppress `azagent` explicitly. Overrides apply only to the current boot and do not replace the cached automatic decision. `zvmi azure deprovision` removes `/var/lib/azagent`, including both the provisioning sentinel and cached environment decision.

Generalized Azure deployments must still provide `adminUsername`; use `g` for
the project image convention. With the builder's `waagent.conf`, azagent mounts
the temporary resource disk at `/d`, then mounts existing ext4 partition 1 on
managed disks by stable Azure LUN at `/e` through `/z`. Blank and unknown
managed-disk layouts are never modified.
