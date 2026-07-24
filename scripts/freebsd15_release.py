#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


EXPECTED = {
    "aarch64": {
        "asset_name": "FreeBSD-15.1-aarch64.qcow2",
        "source_name": (
            "FreeBSD-15.1-RELEASE-arm64-aarch64-"
            "BASIC-CLOUDINIT-ufs.qcow2.xz"
        ),
        "source_sha256": (
            "9722aea499610802de9a14bb645707fc4f6df49ff765cd9ce372b783c4693963"
        ),
        "virtual_size": 6_477_643_776,
    },
    "x86_64": {
        "asset_name": "FreeBSD-15.1-x86_64.qcow2",
        "source_name": (
            "FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
        ),
        "source_sha256": (
            "e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f"
        ),
        "virtual_size": 6_477_709_312,
    },
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_sha256(value: str, label: str) -> None:
    if not SHA256_RE.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase SHA-256")


def candidate_command(args: argparse.Namespace) -> None:
    expected = EXPECTED[args.architecture]
    asset = args.asset.resolve(strict=True)
    if asset.name != expected["asset_name"]:
        raise ValueError(
            f"{args.architecture} asset must be {expected['asset_name']}"
        )
    require_sha256(args.validated_sha256, "validated SHA-256")
    actual_sha256 = sha256(asset)
    if actual_sha256 != args.validated_sha256:
        raise ValueError("validated SHA-256 does not match the candidate")
    if args.virtual_size != expected["virtual_size"]:
        raise ValueError("candidate virtual size does not match the pinned profile")
    if args.source_name != expected["source_name"]:
        raise ValueError("source filename does not match the pinned profile")
    if args.source_sha256 != expected["source_sha256"]:
        raise ValueError("source SHA-256 does not match the pinned profile")
    require_sha256(args.source_sha256, "source SHA-256")
    if args.source_bytes <= 0:
        raise ValueError("source size must be positive")
    if not COMMIT_RE.fullmatch(args.source_commit):
        raise ValueError("source commit must be a lowercase 40-character SHA")
    if not args.source_url.startswith("https://download.freebsd.org/"):
        raise ValueError("source URL must use the official FreeBSD download host")
    if not args.qemu_version.strip() or not args.runner.strip():
        raise ValueError("QEMU version and runner must be recorded")

    document = {
        "schema": 1,
        "type": "zvmi-freebsd15-candidate",
        "architecture": args.architecture,
        "asset_name": asset.name,
        "asset_bytes": asset.stat().st_size,
        "asset_sha256": actual_sha256,
        "virtual_size": args.virtual_size,
        "source": {
            "name": args.source_name,
            "url": args.source_url,
            "bytes": args.source_bytes,
            "sha256": args.source_sha256,
        },
        "source_commit": args.source_commit,
        "validation": {
            "qemu_version": args.qemu_version.strip(),
            "runner": args.runner.strip(),
            "run_id": str(args.run_id),
            "run_attempt": str(args.run_attempt),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def validate_candidate(
    manifest_path: Path,
    source_commit: str,
) -> tuple[dict, Path]:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    if document.get("schema") != 1:
        raise ValueError(f"{manifest_path}: unsupported schema")
    if document.get("type") != "zvmi-freebsd15-candidate":
        raise ValueError(f"{manifest_path}: unexpected candidate type")
    architecture = document.get("architecture")
    if architecture not in EXPECTED:
        raise ValueError(f"{manifest_path}: unexpected architecture")
    expected = EXPECTED[architecture]
    for key in ("asset_name", "source_name", "source_sha256", "virtual_size"):
        actual = (
            document["source"][key.removeprefix("source_")]
            if key.startswith("source_")
            else document[key]
        )
        if actual != expected[key]:
            raise ValueError(f"{manifest_path}: {key} does not match profile")
    if document.get("source_commit") != source_commit:
        raise ValueError(f"{manifest_path}: source commit mismatch")
    asset = manifest_path.parent / document["asset_name"]
    if not asset.is_file():
        raise ValueError(f"{manifest_path}: candidate asset is missing")
    if asset.stat().st_size != document.get("asset_bytes"):
        raise ValueError(f"{manifest_path}: candidate size mismatch")
    if sha256(asset) != document.get("asset_sha256"):
        raise ValueError(f"{manifest_path}: candidate digest mismatch")
    require_sha256(document["asset_sha256"], "candidate SHA-256")
    require_sha256(document["source"]["sha256"], "source SHA-256")
    return document, asset


def release_notes(candidates: list[dict], source_commit: str) -> str:
    lines = [
        "Generalized FreeBSD 15.1-RELEASE UFS images built with zvmi.",
        "",
        "## Highlights",
        "",
        "- Added matching AArch64 and x86_64 release images.",
        "- Each asset is a standalone zstd-compressed QCOW2 with no backing file.",
        "- Both architectures passed dual-instance UEFI QEMU acceptance with "
        "NoCloud provisioning, key-only SSH, reboot, and identity separation.",
        "- Images include Azure Agent, generic and Hyper-V DHCP configuration, "
        "and FreeBSD's Azure serial-console settings.",
        "",
        "## Assets",
        "",
        "| Architecture | Asset | File size | Virtual size | SHA-256 |",
        "| --- | --- | ---: | ---: | --- |",
    ]
    for candidate in candidates:
        lines.append(
            "| {architecture} | `{asset_name}` | {asset_bytes} | "
            "{virtual_size} | `{asset_sha256}` |".format(**candidate)
        )
    lines.extend(
        [
            "",
            "## Provenance",
            "",
            f"- Source commit: `{source_commit}`",
        ]
    )
    for candidate in candidates:
        source = candidate["source"]
        validation = candidate["validation"]
        lines.extend(
            [
                f"- {candidate['architecture']} source: `{source['name']}`",
                f"  - URL: {source['url']}",
                f"  - File size: {source['bytes']} bytes",
                f"  - SHA-256: `{source['sha256']}`",
                f"  - QEMU acceptance: `{validation['qemu_version']}` on "
                f"`{validation['runner']}`",
            ]
        )
    lines.extend(
        [
            "",
            "The QCOW2 assets are not directly uploadable to Azure. Derive an "
            "aligned fixed VHD with `zvmi azure derive` before upload. The exact "
            "release candidates were validated under UEFI QEMU; this release "
            "does not claim exact-candidate Azure validation.",
            "",
            "No checksum sidecar assets are published.",
            "",
        ]
    )
    return "\n".join(lines)


def stage_command(args: argparse.Namespace) -> None:
    if not COMMIT_RE.fullmatch(args.source_commit):
        raise ValueError("source commit must be a lowercase 40-character SHA")
    manifests = sorted(args.candidates.rglob("candidate.json"))
    if len(manifests) != len(EXPECTED):
        raise ValueError(f"expected {len(EXPECTED)} candidate manifests")

    by_architecture = {}
    assets = {}
    for manifest in manifests:
        candidate, asset = validate_candidate(manifest, args.source_commit)
        architecture = candidate["architecture"]
        if architecture in by_architecture:
            raise ValueError(f"duplicate {architecture} candidate")
        by_architecture[architecture] = candidate
        assets[architecture] = asset
    if set(by_architecture) != set(EXPECTED):
        raise ValueError("candidate architecture matrix is incomplete")

    args.output.mkdir(parents=True, exist_ok=True)
    candidates = [by_architecture[name] for name in EXPECTED]
    for candidate in candidates:
        destination = args.output / candidate["asset_name"]
        if destination.exists():
            raise ValueError(f"staged asset already exists: {destination}")
        shutil.copyfile(assets[candidate["architecture"]], destination)
        if sha256(destination) != candidate["asset_sha256"]:
            raise ValueError("staged asset digest mismatch")

    manifest = {
        "schema": 1,
        "type": "zvmi-freebsd15-release",
        "release_tag": args.release_tag,
        "source_commit": args.source_commit,
        "assets": [
            {
                "architecture": candidate["architecture"],
                "asset_name": candidate["asset_name"],
                "bytes": candidate["asset_bytes"],
                "sha256": candidate["asset_sha256"],
            }
            for candidate in candidates
        ],
    }
    (args.output / "publish-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    args.notes.write_text(
        release_notes(candidates, args.source_commit),
        encoding="utf-8",
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    candidate = commands.add_parser("candidate")
    candidate.add_argument("--architecture", choices=EXPECTED, required=True)
    candidate.add_argument("--asset", type=Path, required=True)
    candidate.add_argument("--validated-sha256", required=True)
    candidate.add_argument("--virtual-size", type=int, required=True)
    candidate.add_argument("--source-name", required=True)
    candidate.add_argument("--source-url", required=True)
    candidate.add_argument("--source-sha256", required=True)
    candidate.add_argument("--source-bytes", type=int, required=True)
    candidate.add_argument("--source-commit", required=True)
    candidate.add_argument("--qemu-version", required=True)
    candidate.add_argument("--runner", required=True)
    candidate.add_argument("--run-id", required=True)
    candidate.add_argument("--run-attempt", required=True)
    candidate.add_argument("--output", type=Path, required=True)
    candidate.set_defaults(handler=candidate_command)

    stage = commands.add_parser("stage")
    stage.add_argument("--candidates", type=Path, required=True)
    stage.add_argument("--source-commit", required=True)
    stage.add_argument("--release-tag", required=True)
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--notes", type=Path, required=True)
    stage.set_defaults(handler=stage_command)
    return result


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
