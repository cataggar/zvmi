# `zvmi 0.1.0` Tagged Release Implementation Plan

## Overview

Publish the first general `zvmi` CLI release from the `v0.1.0` Git tag. The
release must be built from a commit where `build.zig.zon` declares version
`0.1.0`, and each platform archive must contain only the `zvmi` executable plus
the repository license and readme.

Follow the proven structure in `~/ms/wabt/.github/workflows/release.yml` for
tag parsing, matrix builds, archive naming, SBOM generation, artifact fan-in,
build-provenance attestation, and GitHub Release creation. Deliberately omit
minisign because this repository has no configured Actions signing secrets.

## Implementation Progress

- [x] Phase 1: Prepare version metadata and a CLI-only build step.
- [x] Phase 2: Add the tag-triggered GitHub Release workflow.
- [ ] Phase 3: Document, validate, tag, and verify `v0.1.0`.

## Current State Analysis

- `build.zig.zon` still declares version `0.0.0`
  (`build.zig.zon:2-5`).
- The target-aware `zvmi` executable is defined and installed through the
  default build graph (`build.zig:92-105`).
- The default install graph also builds and installs several unrelated tools,
  so invoking plain `zig build` is broader than the requested release package.
- CI builds and tests only on Ubuntu and does not publish artifacts
  (`.github/workflows/ci.yml:1-29`).
- The existing boot-smoke workflow already runs for every pushed tag, so
  pushing `v0.1.0` will independently exercise the release commit
  (`.github/workflows/boot-smoke.yml:1-10`).
- The only existing GitHub Release is the separately managed Azure Linux image
  release; there is no generic CLI release workflow.
- `wabt` demonstrates the desired `v*` trigger, version extraction, target
  matrix, packaging, SBOM, artifact collection, attestation, and release
  creation (`~/ms/wabt/.github/workflows/release.yml:1-11`,
  `:14-101`, `:128-184`).
- A local `ReleaseSafe` probe succeeded for `x86_64-linux-musl`,
  `aarch64-linux-musl`, `x86_64-macos`, `aarch64-macos`,
  `x86_64-windows`, and `aarch64-windows`.

## Desired End State

Pushing an annotated `v0.1.0` tag on the prepared release commit:

1. Starts the new `Release` workflow and the existing release boot-smoke
   workflow.
2. Rejects the release if the tag version and `build.zig.zon` version differ.
3. Builds only the `zvmi` CLI for six target platforms in `ReleaseSafe` mode.
4. Creates one install-friendly `.tar.gz` archive and one SPDX JSON SBOM per
   target.
5. Attests the six archives with GitHub build provenance.
6. Creates a non-prerelease GitHub Release named `zvmi 0.1.0`.
7. Documents installation with:

   ```console
   ghr install cataggar/zvmi@v0.1.0
   ```

The release is complete when all six archives and six SBOMs are attached, the
provenance attestations are visible, and both the release and boot-smoke
workflow runs are green.

### Release Assets

| Target | Runner | Archive |
| --- | --- | --- |
| `x86_64-linux-musl` | `ubuntu-22.04` | `zvmi-0.1.0-linux-musl-x64.tar.gz` |
| `aarch64-linux-musl` | `ubuntu-22.04-arm` | `zvmi-0.1.0-linux-musl-arm64.tar.gz` |
| `x86_64-macos` | `ubuntu-22.04` | `zvmi-0.1.0-macos-x64.tar.gz` |
| `aarch64-macos` | `macos-14` | `zvmi-0.1.0-macos-arm64.tar.gz` |
| `x86_64-windows` | `windows-latest` | `zvmi-0.1.0-windows-x64.tar.gz` |
| `aarch64-windows` | `ubuntu-22.04` | `zvmi-0.1.0-windows-arm64.tar.gz` |

Each archive has this layout:

```text
zvmi-0.1.0-<platform>/
  bin/
    zvmi[.exe]
  LICENSE
  README.md
```

## What We Are NOT Doing

- Packaging `azagent`, `azinit`, `nbd`, `qmp`, `qcow2`, code generators, image
  builders, shared libraries, PDB files, or Azure Linux QCOW2 assets.
- Adding a separately generated source archive; GitHub already exposes source
  archives for the tag.
- Adding minisign keys, signatures, or Actions secrets.
- Adding macOS code signing/notarization or Windows Authenticode signing.
- Embedding the package version into the CLI or adding a new `zvmi --version`
  command.
- Changing the Azure Linux image release workflow.
- Refactoring or gating the existing tag-triggered boot-smoke workflow.
- Publishing to a package registry.

## Implementation Approach

Add a narrow build step that installs only the CLI, then use it from a
tag-triggered workflow. A dedicated verification job extracts the version from
the tag and compares it to `build.zig.zon` before any matrix build starts. The
release job fans in the matrix artifacts, attests only the distributable
archives, and publishes the archives and SBOM sidecars.

This keeps the release reusable for later `v*` tags while making `v0.1.0` the
first valid release and preventing a tag from publishing stale manifest
metadata.

## Phase 1: Prepare Version Metadata and a CLI-Only Build Step

### Overview

Set the release version in the package manifest and isolate the requested
artifact from the repository's broader default install graph.

### Changes Required

#### 1. Update the package version

**File**: `build.zig.zon`

**Changes**:

- Change `.version` from `"0.0.0"` to `"0.1.0"`.
- Leave the package fingerprint and minimum Zig version unchanged.
- Make this change in the release-preparation commit before creating the tag.

#### 2. Add a named CLI-only install step

**File**: `build.zig`

**Changes**:

- Replace the direct `b.installArtifact(cli_exe)` registration with a shared
  `addInstallArtifact` step.
- Keep that install artifact attached to the default install step so ordinary
  `zig build` behavior remains unchanged.
- Add an `install-zvmi` build step that depends only on the CLI install
  artifact.
- Use the description `Install only the zvmi CLI`.

The intended shape is:

```zig
const install_cli = b.addInstallArtifact(cli_exe, .{});
b.getInstallStep().dependOn(&install_cli.step);

const install_cli_step = b.step("install-zvmi", "Install only the zvmi CLI");
install_cli_step.dependOn(&install_cli.step);
```

### Success Criteria

- `zig build --help` lists `install-zvmi`.
- `zig build install-zvmi -Doptimize=ReleaseSafe --prefix <empty-dir>` creates
  only `<empty-dir>/bin/zvmi` on the host.
- The default `zig build` still installs the same artifacts it did before.
- `zig build test --summary all` remains green.

**Implementation Note**: Pause after this phase to confirm the isolated build
step and manifest diff before adding publication automation.

---

## Phase 2: Add the Tag-Triggered GitHub Release Workflow

### Overview

Add a reusable `v*` release workflow whose first release is triggered by
`v0.1.0`, with a hard tag-to-manifest version gate and packaging limited to
`zvmi`.

### Changes Required

#### 1. Create the workflow

**File**: `.github/workflows/release.yml`

**Trigger and permissions**:

- Name the workflow `Release`.
- Trigger on pushed tags matching `v*`, following the `wabt` example.
- Default to `contents: read`.
- Grant only the final release job:
  - `contents: write`;
  - `id-token: write`;
  - `attestations: write`.

#### 2. Add a version verification job

**Job**: `verify`

**Changes**:

- Check out the tagged commit.
- Derive the release version with `${GITHUB_REF_NAME#v}`.
- Extract the single `.version` value from `build.zig.zon`.
- Fail with an explicit diagnostic unless both versions are exactly equal.
- Publish the verified version as a job output for all downstream jobs.
- Reject an empty version or malformed manifest extraction rather than using a
  fallback.

For `v0.1.0`, this job must prove:

```text
tag version:      0.1.0
manifest version: 0.1.0
```

#### 3. Build and package the six targets

**Job**: `build`

**Changes**:

- Depend on `verify`.
- Use the six-entry target matrix in the Release Assets table.
- Use `fail-fast: false` so every target reports its result.
- Check out the tagged commit.
- Install Zig 0.16.0 using the repository's existing
  `cataggar/ghr/actions/install@v0.6.6` pattern and checksum
  (`.github/workflows/ci.yml:14-21`).
- Build with:

  ```console
  zig build install-zvmi \
    -Doptimize=ReleaseSafe \
    -Dtarget=<matrix-target>
  ```

- Do not copy `wabt`'s `-Dversion`, `-Dstrip`, or `-Dstack-protector` flags;
  `zvmi` does not define those build options.
- Package only `zig-out/bin/zvmi` or `zig-out/bin/zvmi.exe`, plus `LICENSE` and
  `README.md`, using the archive layout above.
- Fail if the expected executable is absent.
- Generate an SPDX JSON SBOM named
  `zvmi-0.1.0-<platform>.sbom.spdx.json` from the built executable.
- Upload the archive and SBOM as one Actions artifact named after the matrix
  platform.
- Pin third-party Actions to immutable commits, using the versions already
  proven in the `wabt` workflow where applicable.

#### 4. Attest and publish the release

**Job**: `release`

**Changes**:

- Depend on all `build` matrix jobs.
- Check out the tagged commit.
- Download and merge all matrix artifacts.
- Assert that exactly six `zvmi-*.tar.gz` archives and six
  `zvmi-*.sbom.spdx.json` files exist before publishing.
- Attest the six `.tar.gz` archives with
  `actions/attest-build-provenance`.
- Create the GitHub Release with `softprops/action-gh-release`.
- Set:
  - release name: `zvmi 0.1.0`;
  - tag: the triggering tag;
  - draft: `false`;
  - prerelease: true only when the verified version contains a SemVer
    prerelease suffix;
  - generated release notes enabled;
  - body containing the `ghr install cataggar/zvmi@v0.1.0` command.
- Attach only the six archives and six SBOM files.

### Success Criteria

- A temporary nonrelease tag whose version does not match `build.zig.zon`
  fails in `verify` before any build starts.
- All six matrix entries build from the tagged commit and produce the expected
  archive layout.
- No archive contains any executable other than `zvmi` or `zvmi.exe`.
- The release job refuses incomplete artifact sets.
- The workflow requires no repository secrets beyond the automatic
  `GITHUB_TOKEN`.

**Implementation Note**: Pause after this phase to review the workflow diff,
especially tag validation, permissions, target names, and release asset globs.

---

## Phase 3: Document, Validate, Tag, and Verify `v0.1.0`

### Overview

Document installation, run release-preparation checks, and create the tag only
after the version and workflow changes are present on a green `main` commit.

### Changes Required

#### 1. Document binary installation

**File**: `README.md`

**Changes**:

- Add an `Install` section near the top of the readme.
- Document:

  ```console
  ghr install cataggar/zvmi@v0.1.0
  ```

- State that the release packages only the `zvmi` CLI.
- Keep source-build instructions as the alternative for the other repository
  tools.

#### 2. Validate the release-preparation commit

Run the existing project checks:

```console
zig fmt --check .
zig build
zig build test --summary all
```

Also exercise the release-only build with fresh prefixes for representative
native and cross targets, then inspect archive contents:

```console
zig build install-zvmi -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
zig build install-zvmi -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
zig build install-zvmi -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

Confirm the committed `build.zig.zon` contains exactly:

```zig
.version = "0.1.0",
```

#### 3. Create and push the release tag

After the release-preparation changes are merged to `main` and CI is green:

```console
git switch main
git pull --ff-only origin main
git status --short
git tag -a v0.1.0 -m "zvmi 0.1.0"
git push origin v0.1.0
```

Do not tag a local-only commit or move an existing `v0.1.0` tag.

#### 4. Verify the published release

- Confirm the `Release` workflow completed successfully for `v0.1.0`.
- Confirm the existing `Release boot smoke` workflow also completed
  successfully for the same commit.
- Confirm the GitHub Release is named `zvmi 0.1.0`, is not a prerelease, and
  points at the expected commit.
- Confirm all 12 intended assets are present.
- Download at least one Linux and one non-Linux archive and inspect the file
  layout.
- Run the host-appropriate downloaded binary with `help`.
- Run:

  ```console
  ghr install cataggar/zvmi@v0.1.0
  zvmi help
  ```

- Announce the release only after both tag-triggered workflows are green.

### Success Criteria

- `v0.1.0` points to the green release-preparation commit on `main`.
- The tag and manifest both identify version `0.1.0`.
- All intended archives install and expose a working `zvmi` executable.
- No unrelated repository executables are present in the release assets.

---

## Testing Strategy

### Build-System Tests

- Verify `install-zvmi` is isolated from the default install graph.
- Verify the default install graph is unchanged.
- Run the existing full Zig test step.

### Workflow Tests

- Test the version extraction and mismatch failure with local shell commands.
- Exercise representative archive creation locally and inspect with
  `tar -tzf`.
- On the real tag, rely on the six-target matrix for complete compilation
  coverage.

### Release Verification

- Check asset count, names, and archive layout.
- Verify SBOM sidecars correspond one-to-one with archives.
- Verify GitHub provenance attestations for the archives.
- Smoke-test installation through `ghr`.

## Security and Reliability Considerations

- Build from the immutable tagged commit, never from moving `main`.
- Require exact tag-to-manifest version equality.
- Pin third-party Actions to immutable commit SHAs.
- Use least-privilege job permissions.
- Attest the final distributable archives.
- Fail closed on missing binaries, malformed versions, or incomplete artifact
  sets.
- Do not add signing secrets until a separate key-management decision is made.

## Rollback and Failure Handling

- If a matrix or release job fails, fix only after identifying whether the
  tagged commit or workflow environment is at fault.
- Rerun failed jobs when the tagged source is correct and the failure is
  transient.
- Do not move or overwrite a published `v0.1.0` tag.
- If a source defect escapes after publication, leave `v0.1.0` immutable and
  prepare the next patch release.

## References

- Package version: `build.zig.zon:2-5`
- CLI build artifact: `build.zig:92-105`
- Existing Zig installation pattern: `.github/workflows/ci.yml:14-21`
- Existing tag smoke trigger: `.github/workflows/boot-smoke.yml:1-10`
- Release reference: `~/ms/wabt/.github/workflows/release.yml:1-184`
- Release reference package version: `~/ms/wabt/build.zig.zon:1-5`
