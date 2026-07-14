# azinit

A minimal (~160 KB), statically-linked PID 1 replacement for real-boot testing of images built with `zvmi build-image --skip-iso-rootfs`, e.g. against a real Azure VM. It exists to validate the fix for [issue #88](https://github.com/cataggar/zvmi/issues/88) end-to-end on real hardware rather than only structurally/in QEMU, and to serve as a small reference for what a from-scratch container-image init needs to do.

## What it does

- Mounts `/proc`, `/sys`, `/dev`, and `/run`. Immutable mode is the default: root stays read-only, `/var` and `/tmp` use tmpfs, and `/etc` uses a tmpfs-backed overlay. The opt-in `azinit.mode=persistent` kernel option instead remounts root read-write, leaves `/etc`, `/var`, and `/home` persistent, and mounts only `/tmp` as tmpfs. If `/etc/machine-id` is empty after image generalization, azinit generates and persists a new 128-bit machine ID.
- Loads the kernel modules this appliance needs directly via a raw `init_module()` syscall (decompressing the shipped `.ko.xz` with `std.compress.xz`): `overlay` for immutable `/etc`, `hv_netvsc` for Hyper-V networking, and `crc-itu-t`/`udf`/`isofs` for Azure's provisioning DVD. There's no udev/mdev daemon to drive `request_module()` through modprobe/kmod, so azinit loads the fixed dependency order itself.
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
- If `/usr/sbin/azagent` (the guest provisioning agent, see `azagent/`, issue #112) is present, fork+execs it after networking is up so a `--skip-iso-rootfs` image can reach a provisioned login instead of only a bare shell. Immutable mode retains the original best-effort behavior: azagent runs once, and failure does not block the fallback serial shell or optional sshd. Persistent mode requires azagent and retries it every five seconds in a child supervisor while keeping the serial shell available.
- If `/usr/sbin/sshd` is present, fork+execs it after azagent. In persistent mode, sshd does not start until azagent succeeds, ensuring account data, host keys, and `authorized_keys` exist first. This remains one hardcoded fork+exec rather than a general service supervisor and uses the configuration shipped by the container image.

## Building

Built as part of the repo-root build graph (there's no separate `azinit/build.zig`):

```
zig build
zig build test-azinit
```

The installed executable always cross-compiles to static `x86_64-linux` regardless of host, since that's what these real Azure Gen2 VM fixtures run; there's no `-Doptimize=` toggle because the binary hardcodes `ReleaseSmall`. The tests build for the selected native test target.

## Using it

Add the built `zig-out/bin/azinit` binary to a container image as `sbin/init` (plus `sbin/poweroff`/`sbin/reboot`/`sbin/shutdown` symlinks pointing at it), then build an immutable bootable disk image with:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-azinit> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```

For a generalized Azure image, include `/usr/sbin/azagent`, `/usr/sbin/sshd`, `ssh-keygen`, and their runtime dependencies in the container, then opt into persistent mode:

```
zvmi build-image --iso <azurelinux.iso> --container <oci-layout-with-azinit-agent-sshd> \
  --generation 2 --size 768M --skip-iso-rootfs \
  --extra-kernel-options "init=/sbin/init azinit.mode=persistent console=tty0 console=ttyS0,115200n8" \
  -o out.vhd -O vhd
```

`init=/sbin/init` is required when the packaged OpenSSH dependency set includes systemd; otherwise the systemd-based initramfs selects `/usr/lib/systemd/systemd` directly instead of azinit. Persistent mode is intentionally incompatible with a read-only dm-verity root. If the root remount fails, azinit leaves provisioning and SSH disabled and retains serial-console access for diagnosis.
