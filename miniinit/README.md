# miniinit

A minimal (~160 KB), statically-linked PID 1 replacement for real-boot
testing of images built with `zvmi build-image --skip-iso-rootfs`, e.g.
against a real Azure VM. It exists to validate the fix for
[issue #88](https://github.com/cataggar/zvmi/issues/88) end-to-end on real
hardware rather than only structurally/in QEMU, and to serve as a small
reference for what a from-scratch container-image init needs to do.

## What it does

- Mounts `/proc`, `/sys`, `/dev`, `/run`, and a writable tmpfs overlay for
  `/var`, `/tmp`, and `/etc` (root stays read-only, matching the
  dm-verity/immutable-image philosophy elsewhere in this project).
- Loads the kernel modules this appliance needs directly via a raw
  `init_module()` syscall (decompressing the shipped `.ko.xz` with
  `std.compress.xz`): `overlay` (for the `/etc` overlay mount) and
  `hv_netvsc` (Hyper-V's synthetic NIC driver). There's no udev/mdev daemon
  here to drive the kernel's usual uevent-triggered
  `request_module()` -> `/sbin/modprobe` autoload path, and no modprobe/kmod
  binary is shipped either -- see issue #88's discussion for why. Since both
  modules have no further dependencies (checked via `modules.dep`), a direct
  syscall is simpler and more self-contained than adding a kmod dependency.
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

## Building

```
cd miniinit
zig build
```

Always cross-compiles to static `x86_64-linux` regardless of host, since
that's what real Azure Gen2 VMs run; there's no `-Doptimize=` toggle since
the whole point of this binary is to be tiny (this hardcodes
`ReleaseSmall`).

## Using it

Add the built `zig-out/bin/miniinit` binary to a container image as
`sbin/init` (plus `sbin/poweroff`/`sbin/reboot`/`sbin/shutdown` symlinks
pointing at it), then build a bootable disk image with:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-miniinit> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```
