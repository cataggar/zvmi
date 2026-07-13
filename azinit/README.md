# azinit

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
- If `/usr/sbin/azagent` (the guest provisioning agent, see `azagent/`,
  issue #112) is present, fork+execs it once after networking is up, so a
  `--skip-iso-rootfs` image can reach an actually-provisioned login (real
  hostname, a user account, SSH access) instead of just a bare shell.
  Entirely optional: a no-op if `azagent` isn't present (most azinit-based
  test images don't have it), and tolerant of it failing or exiting non-zero
  (e.g. no provisioning CD-ROM attached, or no route to the WireServer yet)
  -- a provisioning failure never blocks reaching the fallback shell. This
  is `zvmi build-image`'s automatic systemd-unit wiring's counterpart for
  the `--skip-iso-rootfs` path, which has no guaranteed systemd to hook a
  unit into (see the root README's build-image section); any other
  from-scratch init wanting the same behavior should do the equivalent.
- If `/usr/sbin/sshd` is present, fork+execs it once right after
  `runAzagentIfPresent()` (so any SSH host keys/`authorized_keys` azagent
  deployed already exist by the time sshd starts), so a
  `--skip-iso-rootfs` image can actually be reached over SSH -- the
  primary way anyone interacts with a headless Linux VM (issue #129).
  Entirely optional: a no-op if `sshd` isn't present (most azinit-based
  test images, including the boot-smoke QEMU tests, don't have it).
  Unlike `azagent`, sshd daemonizes itself and runs forever, so azinit
  doesn't wait for it -- it just launches it and continues into the shell
  loop, whose existing zombie-reaping loop transparently reaps the
  transient first-generation sshd process once it exits after
  daemonizing. This is one hardcoded fork+exec, not a general service
  supervisor, and doesn't configure sshd beyond whatever the container
  image already ships.

## Building

Built as part of the repo-root build graph (there's no separate
`azinit/build.zig`):

```
zig build
```

Always cross-compiles to static `x86_64-linux` regardless of host, since
that's what real Azure Gen2 VMs run; there's no `-Doptimize=` toggle since
the whole point of this binary is to be tiny (this hardcodes
`ReleaseSmall`).

## Using it

Add the built `zig-out/bin/azinit` binary to a container image as
`sbin/init` (plus `sbin/poweroff`/`sbin/reboot`/`sbin/shutdown` symlinks
pointing at it), then build a bootable disk image with:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-azinit> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```
