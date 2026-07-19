# QEMU Image-Adjacent Firmware Bundles Implementation Plan

## Overview

Fix issue [#166](https://github.com/cataggar/zvmi/issues/166) by making
`zvmi qemu` materialize a complete, reusable VM bundle beside the selected
disk instead of requiring uncompressed firmware inside the installed QEMU
package or extracting firmware into a user cache.

The supported Azure Linux bundle is:

```text
AzureLinux-4.0-x86_64.qcow2
AzureLinux-4.0-x86_64.code.fd
AzureLinux-4.0-x86_64.vars.fd
```

The same contract applies to `AzureLinux-4.0-aarch64` once
`AzureLinux-4.0-aarch64.qcow2` is published:

```text
AzureLinux-4.0-aarch64.qcow2
AzureLinux-4.0-aarch64.code.fd
AzureLinux-4.0-aarch64.vars.fd
```

`zvmi qemu ./AzureLinux-4.0-x86_64.qcow2` must use the existing disk and
create any missing firmware files. `zvmi qemu AzureLinux-4.0-x86_64` must
resolve the known image alias, download the missing QCOW2 with `ghr`, and
copy or decompress the matching firmware beside it.

## Current State Analysis

- The command is hard-coded to one x86_64 image filename and release spec
  (`cli/src/commands/qemu.zig:10-11`).
- An explicit positional image is treated as an arbitrary path. Automatic
  download only applies when no positional image was supplied
  (`cli/src/commands/qemu.zig:397-411`, `cli/src/commands/qemu.zig:897-926`).
- Persistent mode already derives `<image-stem>.vars.fd`, copies it once,
  and preserves it across boots (`cli/src/commands/qemu.zig:471-527`).
- QEMU still reads code firmware directly from the QEMU/system installation;
  no image-adjacent `.code.fd` is created
  (`cli/src/commands/qemu.zig:968-1036`).
- Firmware discovery accepts only readable uncompressed pairs
  (`qemu/host.zig:88-150`, `qemu/host.zig:153-177`).
- The current `cataggar/qemu` macOS package contains compressed firmware:
  `edk2-x86_64-code.fd.bz2`, `edk2-i386-vars.fd.bz2`,
  `edk2-aarch64-code.fd.bz2`, and `edk2-arm-vars.fd.bz2`.
- Ghr package resolution is hard-coded to `qemu-system-x86_64`
  (`cli/src/commands/qemu.zig:729-746`, `cli/src/commands/qemu.zig:842-895`),
  although current QEMU packages also include `qemu-system-aarch64`.
- Launch planning is x86_64-specific: `q35`, `Nehalem-v1`, and an x86_64-only
  accelerator decision (`cli/src/commands/qemu.zig:413-424`,
  `cli/src/commands/qemu.zig:968-1036`).
- The repository already has a proven AArch64 UEFI launch shape using
  `qemu-system-aarch64`, `virt`, `host` for native acceleration, `max` for
  TCG, and AAVMF firmware
  (`scripts/build_generalized_freebsd15_aarch64.zig:399-424`,
  `scripts/build_generalized_freebsd15_aarch64.zig:665-713`).
- `artifact_pipeline.acquireVerified` demonstrates bounded streaming into
  `createFileAtomic` followed by publication only after validation
  (`packages/zvmi/src/artifact_pipeline.zig:240-288`).
- `build.zig.zon` currently has no dependencies, and `qemu_host` is a shared
  module tested independently and imported by the CLI
  (`build.zig.zon`, `build.zig:52-59`, `build.zig:94-103`).

## Desired End State

### Invocation Resolution

| Invocation | Resolved disk | Guest profile | Acquisition |
|---|---|---|---|
| `zvmi qemu AzureLinux` | `AzureLinux-4.0-x86_64.qcow2` | x86_64 | Download disk if absent |
| `zvmi qemu AzureLinux-4.0-x86_64` | `AzureLinux-4.0-x86_64.qcow2` | x86_64 | Download disk if absent |
| `zvmi qemu ./AzureLinux-4.0-x86_64.qcow2` | Exact path | x86_64 | Disk must already exist |
| `zvmi qemu AzureLinux-4.0-aarch64` | `AzureLinux-4.0-aarch64.qcow2` | AArch64 | Download disk if published and absent |
| `zvmi qemu ./AzureLinux-4.0-aarch64.qcow2` | Exact path | AArch64 | Disk must already exist |

Known aliases may include a directory prefix. For example,
`zvmi qemu images/AzureLinux-4.0-x86_64` resolves all three bundle files
under `images/`.

Unknown positional values preserve the existing explicit-path behavior.
Unknown custom images continue to use the x86_64 profile unless they exactly
match a known catalog filename; generic architecture probing is not added.

### Bundle Preparation

For a resolved disk `<stem>.qcow2`, persistent and snapshot launches first
ensure:

```text
<stem>.code.fd
<stem>.vars.fd
```

- Existing readable, regular, nonempty bundle files are reused.
- Existing bundle files are never overwritten.
- Persistent mode requires the existing vars file to be writable because it
  contains guest UEFI state. Snapshot mode only requires it to be readable.
- If an existing file is invalid, fail with an actionable error and require
  the user to move or delete it; do not silently replace possible user state.
- Missing files are copied from uncompressed firmware sources or streamed
  through embedded bzip2 decompression from `.fd.bz2` sources.
- Each destination is staged in the destination directory, flushed, closed,
  and published with no-replace rename semantics.
- Concurrent first launches may race, but every process either publishes a
  complete file or validates and uses the winner. No process observes or uses
  a partially written file.
- If one process stops after publishing only one member, the next invocation
  safely fills the missing member before launching QEMU.
- Snapshot mode preserves current behavior by creating its temporary vars
  file from the pristine resolved firmware source, not from potentially
  modified persistent bundle state. The image-adjacent vars file is still
  created/reused as part of the durable bundle, but snapshot mode does not
  read or mutate its guest state.

### Architecture Profiles

| Profile | QEMU binary | Packaged firmware pair | Machine/CPU |
|---|---|---|---|
| x86_64 | `qemu-system-x86_64` | `edk2-x86_64-code.fd` + `edk2-i386-vars.fd` | `q35`; `Nehalem-v1` |
| AArch64 | `qemu-system-aarch64` | `edk2-aarch64-code.fd` + `edk2-arm-vars.fd` | `virt`; `host` when natively accelerated, otherwise `max` |

Both packaged pairs must accept either uncompressed names or matching
`.bz2` names. System firmware candidates remain supported, including the
existing x86_64 OVMF paths and AArch64 AAVMF/QEMU pflash paths.

Automatic acceleration becomes guest-aware:

- x86_64 guest on x86_64 Windows: WHPX.
- x86_64 guest on x86_64 macOS: HVF.
- Same-architecture Linux guest with accessible `/dev/kvm`: KVM.
- AArch64 guest on AArch64 macOS: HVF.
- Cross-architecture or otherwise unsupported combinations: TCG.

### AArch64 Publication Contract

Add the AArch64 catalog entry now with the exact release spec:

```text
cataggar/zvmi/AzureLinux-4.0-aarch64.qcow2@AzureLinux4.0-20260714
```

Before that asset exists, ghr's inherited stderr reports that no matching
asset exists, `zvmi` reports the download failure, and no partial bundle is
left behind.
Uploading that exact asset to the existing stable Azure Linux 4.0 release
makes the alias operational without another launcher change.

## What We Are NOT Doing

- Building or publishing the Azure Linux AArch64 image in this issue.
- Dynamically searching all GitHub releases for similarly named assets.
- Probing arbitrary disk contents to infer guest architecture.
- Adding a general VM manifest/configuration format.
- Updating or modifying files inside the installed `cataggar/qemu` package.
- Refreshing or replacing existing QCOW2, code, or vars bundle files.
- Adding cache pruning, migration from an issue-166 cache prototype, or
  support for compression formats other than bzip2.
- Changing explicit `--ovmf-code`/`--ovmf-vars` semantics: complete explicit
  overrides remain authoritative and bypass bundle firmware materialization.

## Implementation Approach

Introduce a typed image/profile catalog, separate firmware source discovery
from destination materialization, and make the launch plan consume only the
resolved local bundle paths.

The high-level order is:

1. Parse the positional value and resolve a known alias or explicit path.
2. Select the x86_64 or AArch64 guest profile.
3. Resolve the matching QEMU binary and firmware source pair.
4. Download only a missing known release disk.
5. Materialize missing image-adjacent code and vars firmware.
6. Detect disk format and prepare persistent or snapshot state.
7. Build profile-specific QEMU argv and launch.

## Implementation Status

- [x] Phase 1: known-image catalog, aliases, bundle paths, and acquisition.
- [x] Phase 2: embedded bzip2 discovery and atomic firmware materialization.
- [x] Phase 3: architecture-specific QEMU resolution, acceleration, and argv.
- [x] Phase 4: hermetic tests, compressed-package exercise, and six-target builds.
- [ ] Manual real-QEMU boot acceptance on the installed `cataggar/qemu` package.

QEMU preflight remains before disk download so a missing emulator does not
cause a large image download that cannot be used.

## Phase 1: Resolve Known Images and Bundle Paths

### Overview

Replace the single default-image constants with a catalog that drives alias
resolution, release acquisition, architecture selection, and destination
filenames.

### Changes Required

#### 1. Add typed image and guest profiles

**File**: `cli/src/commands/qemu.zig`

Add:

```zig
const GuestArch = enum {
    x86_64,
    aarch64,
};

const KnownImage = struct {
    alias: []const u8,
    disk_name: []const u8,
    release_spec: []const u8,
    guest_arch: GuestArch,
};

const ResolvedImage = struct {
    disk_path: []u8,
    code_path: []u8,
    vars_path: []u8,
    guest_arch: GuestArch,
    release_spec: ?[]const u8,
    download_allowed: bool,
};
```

Define catalog rows for:

- `AzureLinux-4.0-x86_64`;
- `AzureLinux-4.0-aarch64`.

Require an image argument and map the short `AzureLinux` alias to x86_64.

#### 2. Resolve aliases without weakening explicit-path behavior

**File**: `cli/src/commands/qemu.zig`

- Match known aliases only when the final path component equals a catalog
  alias and has no disk extension.
- Preserve the parent directory and append `.qcow2`.
- Recognize exact known disk basenames, including `./` and directory-prefixed
  paths, to select the corresponding architecture.
- Treat every other positional value as the existing explicit path.
- Derive `.code.fd` and `.vars.fd` by removing the selected disk extension.
- Replace `image_was_explicit` with explicit acquisition policy on
  `ResolvedImage`; a known alias may download, while an explicit disk path
  may not.

#### 3. Generalize disk acquisition

**File**: `cli/src/commands/qemu.zig`

- Change `ensureImage` and `ghrDownloadArgv` to consume `ResolvedImage`.
- Use the catalog release spec and resolved destination path.
- Ensure the destination parent directory exists before invoking ghr.
- Preserve ghr verification and its atomic download behavior.
- Distinguish:
  - unknown explicit disk missing;
  - ghr missing;
  - known asset not yet published;
  - download failed;
  - successful ghr exit without the requested output.

### Success Criteria

- Both x86_64 command forms resolve to the same three paths.
- The explicit `./AzureLinux-4.0-x86_64.qcow2` form does not download.
- The alias form downloads only when the QCOW2 is missing.
- Directory-prefixed aliases place all bundle files in that directory.
- The AArch64 alias produces the exact future release spec and preserves
  ghr's clear missing-asset diagnostic today.
- Unknown custom-image behavior remains compatible.

---

## Phase 2: Discover and Materialize Compressed Firmware

### Overview

Extend shared firmware discovery to describe raw or bzip2-compressed sources,
then safely create the image-adjacent code and vars files.

### Changes Required

#### 1. Add embedded bzip2 support

**Files**:

- `build.zig.zon`
- `build.zig`
- `qemu/bzip2.zig`
- `THIRD_PARTY_NOTICES.md`
- `.github/workflows/release.yml`

Changes:

- Add a pinned `silver-signal/zig-bzip2` dependency that builds bzip2 1.0.8
  as a static library without its command-line tools.
- Add a small Zig FFI wrapper that `@cImport`s `bzlib.h` and exposes the
  streaming `BZ2_bzDecompressInit`, `BZ2_bzDecompress`, and
  `BZ2_bzDecompressEnd` operations with Zig error mapping.
- Link the static `bz2` artifact wherever `qemu_host` is compiled:
  target module tests, CLI, host-only QEMU consumers, and acceptance tests.
- Enable libc linking on every affected target and host module; the vendored C
  implementation and `@cImport` binding must work for native and
  cross-compiled release targets.
- Add bzip2 and wrapper license notices.
- Include `THIRD_PARTY_NOTICES.md` in package paths.
- Include `THIRD_PARTY_NOTICES.md` in every release archive beside
  `LICENSE` and `README.md`.
- Keep the released `zvmi` binary self-contained; do not shell out to
  `bzip2`, `bunzip2`, Python, or package-manager tools.

#### 2. Make firmware discovery architecture-aware

**File**: `qemu/host.zig`

Replace the path-only firmware candidate with a source description:

```zig
pub const GuestArch = enum {
    x86_64,
    aarch64,
};

pub const FirmwareEncoding = enum {
    raw,
    bzip2,
};

pub const FirmwareSource = struct {
    path: []u8,
    encoding: FirmwareEncoding,
};

pub const FirmwareSourcePair = struct {
    code: FirmwareSource,
    vars: FirmwareSource,
};
```

- Add `guest_arch` to `FirmwareSearchOptions`.
- Preserve complete explicit overrides as raw sources.
- Search all uncompressed candidates before any compressed candidates so a
  later raw pair beats an earlier `.bz2` pair.
- x86_64 packaged candidates:
  - `edk2-x86_64-code.fd`;
  - `edk2-i386-vars.fd`.
- AArch64 packaged candidates:
  - `edk2-aarch64-code.fd`;
  - `edk2-arm-vars.fd`.
- Add `.bz2` variants for both pairs.
- Preserve current x86_64 system paths.
- Add AArch64 system candidates already proven by the FreeBSD builder:
  - `/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd` +
    `/usr/share/AAVMF/AAVMF_VARS.fd` for Ubuntu, where the generic code name
    is a symlink and firmware inputs remain restricted to regular files;
  - `/usr/share/AAVMF/AAVMF_CODE.fd` +
    `/usr/share/AAVMF/AAVMF_VARS.fd`;
  - `/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw` +
    `/usr/share/edk2/aarch64/vars-template-pflash.raw`.
- Require both members from the same candidate pair.
- Validate source paths as readable regular nonempty files, not merely
  accessible paths.

#### 3. Add no-replace firmware materialization

**File**: `qemu/host.zig`

Add a single-file materializer used by a pair-level helper. The pair helper
accepts a `FirmwareSourcePair` plus exact destination code and vars paths;
snapshot preparation can use the single-file helper to create a pristine
temporary vars file directly from the source.

For each missing destination:

1. Open and pin the source as a regular file.
2. Create a random atomic stage in the destination directory.
3. Stream-copy raw input or stream-decompress bzip2 input with bounded
   buffers and a maximum firmware size.
4. Validate bzip2 status, CRC, end-of-stream, nonempty output, and size.
5. Flush and close the stage.
6. Revalidate that the source identity/size/timestamps did not change.
7. Publish with no-replace rename semantics.
8. If another process already published the destination, discard the local
   stage and validate the winner.

Do not use replace semantics for either destination. In particular, never
replace `.vars.fd`, because it becomes mutable guest state after the first
boot.

Return owned destination paths only after both files pass validation.
Clean every losing or failed stage.

#### 4. Thread local bundle destinations through the CLI

**File**: `cli/src/commands/qemu.zig`

- Change QEMU resolution to return the executable/data directory and
  architecture-matched firmware sources.
- After the disk is ready, materialize sources to
  `ResolvedImage.code_path`/`ResolvedImage.vars_path`.
- Make `LaunchPlan.ovmf_code_path` always use the local `.code.fd`.
- In persistent mode, use the local `.vars.fd` directly instead of copying
  from a separate template.
- In snapshot mode, use the original raw/compressed vars source to create the
  temporary vars file, preserving the current factory-template behavior even
  when the local persistent vars file has changed.
- Complete explicit firmware overrides continue to bypass materialization and
  preserve current literal-path behavior; snapshot mode continues copying the
  explicit vars override into its temporary file.

### Success Criteria

- A ghr QEMU tree containing only x86_64 `.fd.bz2` files creates the exact
  image-adjacent code/vars files and launches from them.
- Raw system firmware is copied to the same local bundle contract.
- Re-running does not rewrite either local file.
- A modified persistent vars file is preserved byte-for-byte.
- Snapshot mode starts from pristine source vars and neither requires nor
  changes persistent vars contents.
- Malformed, truncated, or CRC-invalid bzip2 input publishes no destination.
- Concurrent cold materialization returns one valid pair to every caller and
  leaves no temporary stages.
- A valid pre-existing code file plus missing vars file, and the inverse,
  both recover by publishing only the missing member.
- Installed QEMU files are never modified.

---

## Phase 3: Generalize QEMU Resolution and Launch Planning for AArch64

### Overview

Make the selected guest profile drive the QEMU binary, acceleration, firmware
pair, machine, CPU, and exact argv.

### Changes Required

#### 1. Resolve the architecture-specific emulator

**Files**:

- `cli/src/commands/qemu.zig`
- `qemu/host.zig`

Changes:

- Replace `isQemuSystemX86_64Name` with a profile-driven executable-name
  matcher.
- Parse ghr metadata for `qemu-system-x86_64` or
  `qemu-system-aarch64` as requested.
- Derive the same package root/data directory for either binary.
- Search PATH for the requested emulator name during system fallback.
- Validate an explicit `--qemu` path as executable but let the selected
  profile define firmware and argv behavior.
- Include the requested emulator name in missing-QEMU diagnostics.

#### 2. Make acceleration guest-aware

**File**: `cli/src/commands/qemu.zig`

- Pass `guest_arch` into `resolveAccel`.
- Use native acceleration only when host and guest architectures match.
- Preserve the existing OS-specific x86_64 decisions.
- Add AArch64 HVF on AArch64 macOS and KVM on AArch64 Linux.
- Fall back to TCG for cross-architecture launches.
- Keep explicit accelerator arguments literal; QEMU remains authoritative
  for unsupported forced combinations.

#### 3. Build profile-specific argv

**File**: `cli/src/commands/qemu.zig`

Extend `LaunchPlan` with `guest_arch`, then generate:

**x86_64**

```text
-M q35,accel=<accel>
-cpu Nehalem-v1
```

**AArch64**

```text
-M virt,accel=<accel>
-cpu host     # native HVF/KVM
-cpu max      # TCG
```

Both profiles retain:

- 2 GiB RAM and two vCPUs;
- read-only code pflash and writable vars pflash;
- detected image format over virtio;
- user-mode virtio networking;
- serial `-nographic` interaction;
- snapshot overlay behavior;
- passthrough arguments last.

Use the proven AArch64 pflash form without x86-specific `unit=` arguments.

#### 4. Update help and diagnostics

**Files**:

- `cli/src/commands/qemu.zig`
- `README.md`

Changes:

- Document alias and explicit-disk forms.
- Document the three-file VM bundle.
- Explain that QEMU firmware may be copied or decompressed from the installed
  package, which is never changed.
- Document x86_64 and AArch64 profile selection.
- State the exact future AArch64 asset publication contract.
- Explain snapshot behavior: the local vars file is persistent-mode state,
  while snapshot mode starts from a fresh copy/decompression of the pristine
  firmware source and discards its changes.

### Success Criteria

- The current x86_64 exact argv remains unchanged except for local code path.
- AArch64 TCG argv matches the proven `virt`/`max` boot shape.
- Native AArch64 acceleration selects `host`.
- Ghr metadata tests resolve both system emulators from one package.
- The launcher is ready for the future AArch64 asset without structural code
  changes.

---

## Phase 4: Integration and Real-Package Validation

### Overview

Prove the behavior against synthetic package trees in automated tests and the
current compressed `cataggar/qemu` package in manual acceptance.

### Changes Required

#### 1. Expand unit tests

**Files**:

- `qemu/host.zig`
- `cli/src/commands/qemu.zig`

Add coverage for:

- x86_64 and AArch64 catalog resolution;
- directory-prefixed aliases;
- exact explicit Azure Linux QCOW2 paths;
- unknown explicit paths;
- exact ghr argv for both catalog entries;
- architecture-specific QEMU metadata selection;
- uncompressed-over-compressed preference across all search roots;
- x86_64 and AArch64 compressed package pairs;
- raw copy and bzip2 decompression output;
- malformed/truncated/CRC-invalid compressed data;
- output size limits and empty output rejection;
- source mutation during copy/decompression;
- pre-existing valid code and vars reuse;
- one valid destination plus one missing destination;
- pre-existing invalid destination rejection;
- preservation of modified vars;
- concurrent first-run publication and cleanup;
- persistent vars reuse and pristine-source snapshot vars behavior;
- host/guest acceleration matrix;
- exact x86_64 and AArch64 argv.

Use checked-in small bzip2 fixtures or generate deterministic fixture bytes at
test compile time. Tests must not require a system `bzip2` executable,
network, ghr installation, or real QEMU.

#### 2. Preserve existing integration coverage

**Files**:

- `tests/boot_smoke.zig`
- `tests/freebsd15_aarch64_boot.zig`

Update shared API calls for architecture-aware firmware discovery without
changing the opt-in semantics of either acceptance suite.

#### 3. Manual acceptance

Run on the current macOS Arm64 ghr package:

1. In an empty directory, run `zvmi qemu AzureLinux-4.0-x86_64`.
2. Verify the QCOW2 is downloaded and both firmware files are decompressed.
3. Verify QEMU reads only the local `.code.fd`/`.vars.fd`.
4. Shut down and confirm a second launch reuses all three files.
5. Hash `.code.fd`, modify UEFI state through a boot, and confirm neither
   file is regenerated.
6. Run `--snapshot` and confirm the local vars hash is unchanged.
7. Repeat with `./AzureLinux-4.0-x86_64.qcow2`.
8. After the AArch64 asset is published, repeat with
   `AzureLinux-4.0-aarch64` on Arm64 macOS and Linux, then exercise an x86_64
   host TCG launch.

### Success Criteria

- `zig fmt --check .`, `zig build`, and `zig build test --summary all` pass.
- `zig build install-zvmi -Doptimize=ReleaseSafe -Dtarget=<target>` succeeds
  for all six release targets in `.github/workflows/release.yml:75-99`:
  x86_64/aarch64 Linux musl, x86_64/aarch64 macOS, and
  x86_64/aarch64 Windows.
- Issue #166 reproduces before the change and succeeds after it with the
  packaged compressed-only firmware.
- Both requested x86_64 command forms produce and use the three-file bundle.
- The AArch64 alias needs only publication of the predefined release asset.

## Testing Strategy

### Unit Tests

Keep acquisition, materialization, and argv tests hermetic. Inject temporary
directories, explicit host capability values, synthetic ghr metadata, and
small compressed fixtures.

### Integration Tests

Use synthetic ghr package trees to cover end-to-end resolver behavior without
network access. Preserve the existing optional real-QEMU suites.

### Manual Tests

Use the current `cataggar/qemu` macOS Arm64 package because it contains the
exact compressed-only layout that triggered issue #166. Test repeated
persistent and snapshot boots to verify that firmware preparation does not
destroy persistent UEFI state and that snapshot mode still starts from
pristine source vars.

## Performance Considerations

- Firmware is streamed with fixed-size buffers and never fully loaded into
  memory.
- Decompression happens only when the local destination is absent.
- The QCOW2 remains the only large network download.
- No content-addressed cache is needed because each image directory owns its
  durable firmware bundle.

## Security and Reliability Considerations

- Continue spawning ghr and QEMU with argv arrays, never shell strings.
- Preserve ghr release-asset verification.
- Pin and stat firmware sources before and after streaming.
- Reject symlink/non-regular destinations and inputs where the existing
  filesystem APIs permit no-follow opens.
- Bound decompressed output size to prevent decompression bombs.
- Validate bzip2 CRC/end-of-stream status.
- Never overwrite existing disk, code, or vars files.
- Publish only complete individual files and clean all failed staging files.
- Keep installed QEMU packages read-only.

## Migration Notes

Users who previously ran `zvmi qemu` may already have
`AzureLinux-4.0-x86_64.vars.fd`. It remains authoritative and is reused.
The first launch after this change creates only the missing
`AzureLinux-4.0-x86_64.code.fd`.

There is no migration from the cache layout proposed in the existing issue
comment because that implementation has not landed. The image-adjacent bundle
supersedes that proposal.

## References

- Issue #166: https://github.com/cataggar/zvmi/issues/166
- Existing QEMU command: `cli/src/commands/qemu.zig`
- Shared host discovery: `qemu/host.zig`
- Existing launcher plan:
  `thoughts/zvmi-qemu/plans/implementation-plan.md`
- Atomic artifact publication:
  `packages/zvmi/src/artifact_pipeline.zig:240-288`
- AArch64 firmware and launch prior art:
  `scripts/build_generalized_freebsd15_aarch64.zig:399-424`,
  `scripts/build_generalized_freebsd15_aarch64.zig:665-713`
- Azure Linux release publication:
  `.github/workflows/azurelinux4-release.yml:12-17`,
  `.github/workflows/azurelinux4-release.yml:73-126`
- Six-target zvmi release matrix:
  `.github/workflows/release.yml:69-114`
