# `zvmi qemu` Implementation Plan

## Overview

Add a convenience command that boots the published Azure Linux 4 x86_64 Gen2 image interactively under QEMU:

```text
zvmi qemu [<image>] [--snapshot] [--accel auto|whpx|kvm|hvf|tcg]
          [--qemu <path>] [--ovmf-code <path>] [--ovmf-vars <path>]
          [-- <extra-qemu-args...>]
```

With no image argument, the command uses `AzureLinux-4.0-x86_64.qcow2` in the current directory. If that default file is absent, it runs:

```text
ghr download cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714 --output AzureLinux-4.0-x86_64.qcow2
```

The VM is writable by default. `--snapshot` provides an explicitly ephemeral boot. QEMU must already be installed; when it cannot be found, the command stops with an actionable `ghr install cataggar/qemu` diagnostic rather than installing or upgrading it implicitly.

## Implementation Progress

- [x] Phase 1: Add command surface and pure launch planning.
- [x] Phase 2: Add QEMU/firmware discovery and conditional image download.
- [x] Phase 3: Prepare VM state, launch interactively, and document the workflow.

## Current State Analysis

- The CLI is a direct command dispatcher with one module per subcommand (`cli/src/main.zig:8-18`, `cli/src/main.zig:57-75`).
- The repository already has QEMU executable lookup, OVMF discovery, writable-vars copying, QEMU argument construction, and clean process-control patterns in the boot-smoke test (`tests/boot_smoke.zig:151-227`, `tests/boot_smoke.zig:308-410`).
- Interactive subprocess execution with inherited standard streams and explicit exit-status handling already exists in the generalized image builder (`scripts/build_generalized_azurelinux4.zig:47-75`).
- The release workflow publishes and replaces a stable `AzureLinux-4.0-x86_64.qcow2` asset (`.github/workflows/azurelinux4-release.yml:16`, `.github/workflows/azurelinux4-release.yml:73-80`, `.github/workflows/azurelinux4-release.yml:116-126`).
- `ghr download` supports a specific release asset, an explicit output path, atomic `.part` publication, and GitHub digest verification.
- A `cataggar/qemu` ghr installation records the selected archive and relative executable paths in `<ghr tools>/cataggar/qemu/ghr.json`; its QEMU binary and `share/edk2-*.fd` firmware remain together in the extracted tool directory even though PATH shims are copied into the ghr bin directory.
- The existing CI build already compiles and runs CLI module tests through `zig build test` (`build.zig:75-95`, `build.zig:451`).

## Desired End State

Running `zvmi qemu` from an empty working directory:

1. Resolves a usable x86_64 QEMU binary and UEFI firmware.
2. Downloads the verified Azure Linux release image only when the default image is absent.
3. Creates or reuses a writable UEFI variables file beside the image.
4. Launches QEMU with an interactive serial console, user-mode networking, 2 GiB RAM, two vCPUs, and host-appropriate acceleration.
5. Waits for QEMU and returns its exit status.

The successful console path should reach the Azure Linux root shell and include:

```text
[zvminit] non-Azure environment detected; skipping azagent
[root@azurelinux /]#
```

Re-running the command must not invoke `ghr download` while the image exists. `--snapshot` must avoid persisting guest disk and UEFI-variable changes.

### Key Discoveries

- The published image is specifically x86_64, Gen2/UEFI, qcow2, and directly bootable with QEMU; the first command version should model that concrete artifact rather than claim to be a generic VM manager.
- The ghr PATH copy of `qemu-system-x86_64` is insufficient for deterministic firmware discovery on Windows. Reading `ghr path tools` plus `cataggar/qemu/ghr.json` identifies the real extracted package and adjacent `share` directory.
- The boot-smoke helpers are currently private test code. Extracting generic host-QEMU and OVMF discovery avoids creating a second implementation with different platform behavior.
- QMP is unnecessary for the interactive command. Inherited stdin/stdout/stderr plus `child.wait()` provides the expected `-nographic` terminal experience and lets Ctrl+C reach QEMU naturally.

## What We Are NOT Doing

- Automatically installing or upgrading QEMU.
- Re-downloading, refreshing, or overwriting an image that already exists.
- Discovering the newest release dynamically; the workflow intentionally replaces the asset on the stable `AzureLinux4.0-20260714` release.
- Supporting aarch64, Gen1/BIOS, arbitrary machine definitions, or a general VM configuration store in the first version.
- Adding SSH port forwarding, daemon/background mode, graphical display management, or QMP lifecycle automation.
- Cloning the image before every persistent boot.
- Bypassing ghr verification with `--skip-verify`.

## Implementation Approach

Keep side effects behind a small launch-planning layer:

1. Parse user intent into a typed `Options`.
2. Resolve QEMU, its data directory, and OVMF firmware without downloading the image.
3. Resolve the image, invoking `ghr download` only for the missing default.
4. Prepare persistent UEFI variables, or temporary variables plus a qcow2 overlay.
5. Build an argv array without shell interpolation.
6. Spawn QEMU with inherited streams, wait, clean temporary snapshot state, and propagate the child result.

This separation makes argument parsing, download decisions, ghr metadata handling, accelerator selection, and QEMU argv construction unit-testable without network access or a real hypervisor.

## Phase 1: Add Command Surface and Pure Launch Planning

### Overview

Introduce the subcommand, define its narrow x86_64 Gen2 contract, and isolate argument/argv construction from filesystem and subprocess side effects.

### Changes Required

#### 1. Add the command module

**File**: `cli/src/commands/qemu.zig`

**Changes**:

- Add the command help text and parser for:
  - optional positional image path;
  - `--snapshot`;
  - `--accel auto|whpx|kvm|hvf|tcg`;
  - `--qemu <path>`;
  - `--ovmf-code <path>`;
  - `--ovmf-vars <path>`;
  - `--` followed by literal additional QEMU arguments.
- Default to `AzureLinux-4.0-x86_64.qcow2` and record whether the image path was explicit. Only the implicit default is eligible for automatic download.
- Define constants for the default asset name and exact ghr release spec.
- Define typed planning structures similar to:

```zig
const Options = struct {
    image_path: []const u8 = default_image_name,
    image_was_explicit: bool = false,
    snapshot: bool = false,
    accel: Accel = .auto,
    qemu_path: ?[]const u8 = null,
    ovmf_code_path: ?[]const u8 = null,
    ovmf_vars_path: ?[]const u8 = null,
    extra_qemu_args: []const []const u8 = &.{},
};

const LaunchPlan = struct {
    qemu_path: []const u8,
    qemu_data_dir: ?[]const u8,
    image_path: []const u8,
    image_format: zvmi.Format,
    ovmf_code_path: []const u8,
    ovmf_vars_path: []const u8,
    snapshot: bool,
    accel: Accel,
    extra_qemu_args: []const []const u8,
};
```

- Add pure helpers for:
  - default-versus-explicit image download decisions;
  - host/architecture-based `auto` accelerator selection;
  - `zvmi.Format` to QEMU format mapping (`vhd` maps to `vpc`);
  - stable persistent vars naming;
  - final QEMU argv construction.
- Build the existing successful boot shape:
  - `-L <ghr-qemu-share>` when a packaged data directory is known;
  - `-M q35,accel=<resolved>`;
  - `-cpu Nehalem-v1`;
  - `-m 2G`;
  - `-smp 2`;
  - read-only OVMF code pflash;
  - writable vars pflash;
  - the detected-format image as a virtio drive;
  - `-nic user,model=virtio-net-pci`;
  - `-no-reboot`;
  - `-nographic`;
  - the selected base image normally, or an explicit temporary qcow2 overlay
    when snapshot mode is requested;
  - literal passthrough arguments last.

#### 2. Register the subcommand

**File**: `cli/src/main.zig`

**Changes**:

- Import `commands/qemu.zig`.
- Add `qemu` to the top-level usage text.
- Dispatch `zvmi qemu` to `qemu_cmd.run`.
- Include the module in the root test block.
- Update the file-level command list.

### Success Criteria

- `zvmi --help` documents `qemu`.
- Parser tests cover defaults, an explicit image, every supported option, passthrough arguments, missing values, invalid accelerators, and extra positional arguments.
- Launch-plan tests assert the exact persistent and snapshot QEMU argv shapes.
- An absent explicit custom image produces an error plan rather than downloading the Azure Linux default under an unexpected name.

**Implementation Note**: Pause after this phase to review the CLI grammar and generated argv before adding discovery and subprocess side effects.

---

## Phase 2: Add QEMU/Firmware Discovery and Conditional Image Download

### Overview

Resolve all external prerequisites deterministically, preferring the known ghr QEMU package while preserving compatibility with system installations.

### Changes Required

#### 1. Extract reusable host-QEMU discovery

**File**: `qemu/host.zig`

**Changes**:

- Move/generalize the reusable executable lookup and OVMF candidate search currently embedded in `tests/boot_smoke.zig:151-227`.
- Return optional owned values rather than printing test-specific skip messages.
- Support:
  - executable lookup on PATH, including the host executable suffix;
  - explicit code/vars overrides;
  - existing Linux OVMF candidates;
  - adjacent/package `share` directories;
  - common Homebrew/macOS QEMU data locations;
  - readable-file and executable checks.
- Keep policy out of this module: callers decide whether missing prerequisites mean skip or failure.

#### 2. Wire the shared module

**File**: `build.zig`

**Changes**:

- Create a `qemu_host` module from `qemu/host.zig`.
- Import it into the `zvmi` CLI root module.
- Import it into `tests/boot_smoke.zig`.

**File**: `tests/boot_smoke.zig`

**Changes**:

- Replace the duplicated PATH and OVMF discovery helpers with `qemu_host`.
- Preserve the current opportunistic skip diagnostics and behavior.
- Do not change boot-smoke launch semantics or coverage.

#### 3. Discover ghr-managed QEMU

**File**: `cli/src/commands/qemu.zig`

**Changes**:

- If explicit QEMU/firmware paths are not complete, locate `ghr` on PATH.
- Capture `ghr path tools` without a shell and trim its single path result.
- Read `<tools>/cataggar/qemu/ghr.json` with `std.json`.
- Find the recorded `qemu-system-x86_64` relative bin entry, then derive:
  - the real executable path;
  - its extracted package root;
  - `<package-root>/share`;
  - `share/edk2-x86_64-code.fd`;
  - `share/edk2-i386-vars.fd`.
- Prefer this coherent package result over the PATH shim because it guarantees the matching firmware/data directory.
- If no usable ghr package is installed, fall back to `qemu_host` system executable and OVMF discovery.
- If QEMU remains unavailable, fail before downloading the image and print:

```text
qemu: qemu-system-x86_64 was not found
install it with: ghr install cataggar/qemu
```

- If QEMU is found but firmware is not, report the searched locations and point to `--ovmf-code`/`--ovmf-vars`.

#### 4. Download only the missing default image

**File**: `cli/src/commands/qemu.zig`

**Changes**:

- Check the selected image path after QEMU preflight.
- When the implicit default is absent, spawn:

```text
ghr download cataggar/zvmi/AzureLinux-4.0-x86_64.qcow2@AzureLinux4.0-20260714 \
  --output AzureLinux-4.0-x86_64.qcow2
```

- Inherit output so ghr progress and verification results remain visible.
- Treat any non-zero/abnormal ghr termination as a command failure.
- Verify the final output exists after ghr succeeds; do not accept a success-shaped fallback.
- Never invoke ghr when the file already exists.
- Open the image with `zvmi.Image.openPath` to reject unreadable/unsupported images and obtain the explicit QEMU drive format.

### Success Criteria

- Unit tests parse representative `ghr.json` content and resolve the package executable plus firmware paths.
- Discovery tests cover explicit overrides, ghr package success, ghr absence with system fallback, missing firmware, and missing QEMU.
- Download-decision tests prove that only the absent implicit default generates ghr argv.
- No network or real QEMU process is required by `zig build test`.
- Existing boot-smoke prerequisite behavior remains unchanged after helper extraction.

**Implementation Note**: Pause after this phase to test discovery against an actual `ghr install cataggar/qemu` on Windows and a system QEMU/OVMF installation on Linux.

---

## Phase 3: Prepare VM State, Launch Interactively, and Document the Workflow

### Overview

Perform the stateful launch, preserve writes by default, provide snapshot isolation, and document the supported workflow.

### Changes Required

#### 1. Prepare UEFI variables safely

**File**: `cli/src/commands/qemu.zig`

**Changes**:

- Persistent mode:
  - derive `<image-stem>.vars.fd` beside the image;
  - copy the OVMF vars template only when the file is absent;
  - reuse it on later boots so firmware state persists with disk state.
- Snapshot mode:
  - create a uniquely named vars copy in the system temporary directory;
  - use the sibling `qemu-img` binary to create a uniquely named temporary
    qcow2 overlay backed by the selected image;
  - boot the overlay instead of using QEMU's global `-snapshot`, which also
    tries to snapshot writable pflash on Windows;
  - delete the temporary vars copy and overlay after QEMU exits or launch fails.
- Copy files through `std.Io` APIs and surface read/write failures with the source and destination paths.

#### 2. Launch and propagate status

**File**: `cli/src/commands/qemu.zig`

**Changes**:

- Print a concise pre-launch summary showing image, QEMU binary, accelerator, persistent/snapshot mode, and vars path.
- Spawn QEMU directly with argv entries; never construct a shell command string.
- Inherit stdin, stdout, and stderr so `-nographic` exposes the serial root shell.
- Wait for QEMU to exit.
- Return QEMU's numeric exit code when representable; report signals/abnormal termination as failure.
- Ensure snapshot cleanup runs on normal exit, spawn failure, and abnormal termination.

#### 3. Document the command

**File**: `README.md`

**Changes**:

- Add `zvmi qemu` to the layout and CLI examples.
- Add a focused section near the generalized Azure Linux image documentation (`README.md:392-404`) covering:
  - required preinstallation: `ghr install cataggar/qemu`;
  - first run from an empty directory;
  - automatic verified image download;
  - persistent default behavior;
  - `--snapshot`;
  - custom image and explicit QEMU/OVMF overrides;
  - host acceleration selection and `--accel tcg` fallback;
  - expected non-Azure/root-shell console markers.
- State that the first version launches x86_64 Gen2/UEFI images and is not a generic VM manager.

### Success Criteria

- From an empty temporary directory with QEMU installed, `zvmi qemu` downloads the release image and reaches the root serial shell.
- A second invocation uses the existing image and vars file without invoking ghr.
- A file created in the guest persists across normal boots.
- The same guest write made under `--snapshot` is absent on the next boot.
- Missing QEMU fails before downloading and prints the exact install guidance.
- An existing custom image launches without any release download.
- QEMU receives terminal input and its exit status is propagated.
- The console shows the non-Azure `azagent` skip behavior fixed by issue #143.

---

## Testing Strategy

### Unit Tests

- CLI parsing and help behavior.
- Default versus explicit image selection.
- Exact ghr release spec and output argv.
- `ghr.json` parsing and executable selection.
- QEMU format mapping.
- Host accelerator resolution using injected OS/architecture/KVM-access inputs.
- Persistent and snapshot vars-path planning.
- Exact QEMU argv ordering.
- Child termination to CLI exit-code mapping.
- Error messages for missing image, ghr, QEMU, and firmware.

### Existing Integration Tests

- Refactor `tests/boot_smoke.zig` to consume shared host discovery, then run its existing opportunistic real-QEMU tests unchanged.
- Keep network/download behavior out of the default unit suite.

### Manual End-to-End Tests

1. Build the CLI in `../zvmi`.
2. Create an empty temporary directory.
3. Confirm `ghr list` contains `cataggar/qemu`.
4. Run `zvmi qemu`.
5. Confirm ghr downloads and verifies `AzureLinux-4.0-x86_64.qcow2`.
6. Confirm the serial console reaches `[root@azurelinux /]#`.
7. Confirm the console includes `non-Azure environment detected; skipping azagent` and does not repeat `retrying azagent`.
8. Create a marker file, shut down the VM, relaunch, and confirm persistence.
9. Run with `--snapshot`, create a different marker, exit, relaunch normally, and confirm the snapshot marker is absent.
10. Temporarily hide the ghr QEMU installation and verify system-QEMU fallback.
11. Hide both QEMU sources and verify the command fails before any image download.

## Performance Considerations

- The approximately 239 MiB image is downloaded once and reused.
- ghr owns streaming, retry, atomic publication, and release-asset verification; `zvmi` must not buffer or re-hash the full image.
- QEMU and firmware discovery should read only small metadata and directory entries.
- Persistent mode boots the qcow2 directly without making a full copy.

## Security and Reliability Considerations

- Use argv-based process spawning for both ghr and QEMU to avoid shell injection.
- Keep ghr verification enabled and rely on its atomic `.part` rename.
- Validate every resolved executable, firmware, image, and vars path before launch.
- Do not silently fall back from a requested accelerator or explicit path.
- Do not overwrite existing images or vars files.
- Clean only temporary files created by the current snapshot invocation.

## Migration Notes

There is no data or CLI migration. This is a new command. Existing QEMU boot-smoke tests retain their behavior while sharing generic discovery helpers.

## References

- Requested behavior and verified boot command: https://github.com/cataggar/zvmi/issues/143
- CLI dispatch: `cli/src/main.zig:8-18`, `cli/src/main.zig:57-75`
- Existing QEMU discovery and launch behavior: `tests/boot_smoke.zig:151-227`, `tests/boot_smoke.zig:308-410`
- Existing inherited subprocess pattern: `scripts/build_generalized_azurelinux4.zig:47-75`
- Published image asset: `.github/workflows/azurelinux4-release.yml:16`, `.github/workflows/azurelinux4-release.yml:116-126`
- Generalized image documentation: `README.md:392-404`
