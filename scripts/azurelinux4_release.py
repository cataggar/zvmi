#!/usr/bin/env python3
"""Validate and bind Azure Linux release artifacts across workflow jobs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
EXPECTED = {
    "x86_64-full": ("x86_64", "full", "AzureLinux-4.0-x86_64.qcow2"),
    "aarch64-full": ("aarch64", "full", "AzureLinux-4.0-aarch64.qcow2"),
    "x86_64-core": ("x86_64", "core", "AzureLinux-4.0-x86_64.core.qcow2"),
    "aarch64-core": ("aarch64", "core", "AzureLinux-4.0-aarch64.core.qcow2"),
}
RELEASE_ORDER = tuple(EXPECTED)
AZURE_CONTRACTS = {
    "matching-architecture-gen2",
    "key-only-ssh",
    "agent-ready",
    "root-growth",
    "resource-disk",
    "managed-data-disk",
    "reboot-reconnect",
    "runtime-flavor-identity",
}
AZURE_VHD_ALIGNMENT = 1024 * 1024
VHD_FOOTER_BYTES = 512


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        fail(f"{label} is not a lowercase SHA-256")
    return value


def require_commit(value: object, label: str = "source_commit") -> str:
    if not isinstance(value, str) or COMMIT_RE.fullmatch(value) is None:
        fail(f"{label} is not a full lowercase commit SHA")
    return value


def validate_azure_vhd_info(info: dict[str, object], file_size: int) -> int:
    if info.get("format") != "vpc":
        fail("derived upload image is not VHD/VPC")
    data = (info.get("format-specific") or {})
    if not isinstance(data, dict):
        fail("derived upload VHD format metadata is invalid")
    format_data = data.get("data") or {}
    if not isinstance(format_data, dict) or format_data.get("type") != "fixed":
        fail("derived upload VHD is not fixed")
    virtual_size = info.get("virtual-size")
    if type(virtual_size) is not int or virtual_size <= 0:
        fail("derived upload VHD virtual size is invalid")
    if virtual_size % AZURE_VHD_ALIGNMENT != 0:
        fail("derived upload VHD virtual size is not 1 MiB aligned")
    if file_size != virtual_size + VHD_FOOTER_BYTES:
        fail("derived upload VHD file size does not equal virtual size plus footer")
    return virtual_size


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_identity(
    document: dict[str, object],
    *,
    expected_type: str,
    key: str | None = None,
    source_commit: str | None = None,
) -> tuple[str, str, str, str]:
    if document.get("schema") != 1 or document.get("type") != expected_type:
        fail(f"invalid {expected_type} schema")
    actual_key = document.get("key")
    if not isinstance(actual_key, str) or actual_key not in EXPECTED:
        fail(f"invalid candidate key: {actual_key!r}")
    if key is not None and actual_key != key:
        fail(f"candidate key mismatch: expected {key}, got {actual_key}")
    architecture, flavor, asset_name = EXPECTED[actual_key]
    if document.get("architecture") != architecture:
        fail(f"{actual_key}: architecture mismatch")
    if document.get("flavor") != flavor:
        fail(f"{actual_key}: flavor mismatch")
    if document.get("asset_name") != asset_name:
        fail(f"{actual_key}: asset name mismatch")
    actual_commit = require_commit(document.get("source_commit"))
    if source_commit is not None and actual_commit != source_commit:
        fail(f"{actual_key}: source commit mismatch")
    return actual_key, architecture, flavor, asset_name


def provenance_records(root: Path) -> list[dict[str, object]]:
    if not root.is_dir():
        fail(f"provenance directory is missing: {root}")
    records: list[dict[str, object]] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        records.append(
            {
                "path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    if not records:
        fail(f"provenance directory is empty: {root}")
    return records


def provenance_digest(records: list[dict[str, object]]) -> str:
    encoded = json.dumps(records, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()


def candidate_command(args: argparse.Namespace) -> None:
    asset = args.asset.resolve()
    if not asset.is_file():
        fail(f"candidate asset is missing: {asset}")
    if args.key not in EXPECTED:
        fail(f"unknown candidate key: {args.key}")
    architecture, flavor, asset_name = EXPECTED[args.key]
    if args.architecture != architecture or args.flavor != flavor:
        fail(f"{args.key}: architecture/flavor arguments do not match")
    if asset.name != asset_name:
        fail(f"{args.key}: expected asset {asset_name}, got {asset.name}")
    source_commit = require_commit(args.source_commit)
    records = provenance_records(args.provenance_dir.resolve())
    digest = sha256(asset)
    if args.validated_sha256 != digest:
        fail(f"{args.key}: build validation digest does not match candidate bytes")
    if args.virtual_size <= 0:
        fail("virtual size must be positive")
    write_json(
        args.output,
        {
            "schema": 1,
            "type": "azurelinux4-candidate",
            "key": args.key,
            "architecture": architecture,
            "flavor": flavor,
            "asset_name": asset_name,
            "source_commit": source_commit,
            "sha256": digest,
            "bytes": asset.stat().st_size,
            "virtual_size": args.virtual_size,
            "build_validation": {
                "status": "success",
                "validated_sha256": args.validated_sha256,
                "runner": args.runner,
            },
            "provenance": {
                "digest": provenance_digest(records),
                "files": records,
            },
            "workflow": {
                "run_id": args.run_id,
                "run_attempt": args.run_attempt,
            },
        },
    )


def verify_candidate(
    manifest_path: Path,
    asset_path: Path,
    *,
    key: str | None = None,
    source_commit: str | None = None,
) -> dict[str, object]:
    document = read_json(manifest_path)
    actual_key, _, _, asset_name = validate_identity(
        document,
        expected_type="azurelinux4-candidate",
        key=key,
        source_commit=source_commit,
    )
    if asset_path.name != asset_name or not asset_path.is_file():
        fail(f"{actual_key}: exact candidate asset is missing")
    digest = require_sha256(document.get("sha256"), f"{actual_key} candidate digest")
    if sha256(asset_path) != digest:
        fail(f"{actual_key}: candidate bytes do not match the bound digest")
    if document.get("bytes") != asset_path.stat().st_size:
        fail(f"{actual_key}: candidate size mismatch")
    virtual_size = document.get("virtual_size")
    if not isinstance(virtual_size, int) or virtual_size <= 0:
        fail(f"{actual_key}: invalid virtual size")
    build_validation = document.get("build_validation")
    if (
        not isinstance(build_validation, dict)
        or build_validation.get("status") != "success"
    ):
        fail(f"{actual_key}: build validation is not explicitly successful")
    if build_validation.get("validated_sha256") != digest:
        fail(f"{actual_key}: build validation did not validate published bytes")
    provenance = document.get("provenance")
    if not isinstance(provenance, dict):
        fail(f"{actual_key}: provenance is absent")
    require_sha256(provenance.get("digest"), f"{actual_key} provenance digest")
    files = provenance.get("files")
    if not isinstance(files, list) or not files:
        fail(f"{actual_key}: provenance file bindings are absent")
    provenance_root = manifest_path.parent / "internal-provenance"
    actual_paths = {
        path.relative_to(provenance_root).as_posix()
        for path in provenance_root.rglob("*")
        if path.is_file()
    }
    bound_paths: set[str] = set()
    for record in files:
        if not isinstance(record, dict):
            fail(f"{actual_key}: invalid provenance record")
        relative = record.get("path")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or relative in bound_paths
        ):
            fail(f"{actual_key}: invalid provenance path")
        path = provenance_root / relative
        if not path.is_file() or record.get("bytes") != path.stat().st_size:
            fail(f"{actual_key}: provenance file/size mismatch for {relative}")
        if record.get("sha256") != sha256(path):
            fail(f"{actual_key}: provenance digest mismatch for {relative}")
        bound_paths.add(relative)
    if bound_paths != actual_paths:
        fail(f"{actual_key}: provenance file allowlist mismatch")
    if provenance.get("digest") != provenance_digest(files):
        fail(f"{actual_key}: aggregate provenance digest mismatch")
    return document


def verify_candidate_command(args: argparse.Namespace) -> None:
    document = verify_candidate(
        args.manifest,
        args.asset,
        key=args.key,
        source_commit=args.source_commit,
    )
    print(document["sha256"])
    print(document["bytes"])
    print(document["virtual_size"])


def verify_vhd_command(args: argparse.Namespace) -> None:
    vhd = args.vhd.resolve()
    if not vhd.is_file():
        fail(f"derived VHD is missing: {vhd}")
    file_size = vhd.stat().st_size
    virtual_size = validate_azure_vhd_info(read_json(args.info), file_size)
    print(virtual_size)
    print(file_size)


def azure_result_command(args: argparse.Namespace) -> None:
    candidate = verify_candidate(
        args.manifest,
        args.asset,
        key=args.key,
        source_commit=args.source_commit,
    )
    vhd = args.vhd.resolve()
    if not vhd.is_file():
        fail(f"derived VHD is missing: {vhd}")
    write_json(
        args.output,
        {
            "schema": 1,
            "type": "azurelinux4-azure-acceptance",
            "key": candidate["key"],
            "architecture": candidate["architecture"],
            "flavor": candidate["flavor"],
            "asset_name": candidate["asset_name"],
            "source_commit": candidate["source_commit"],
            "qcow_sha256": candidate["sha256"],
            "azure_accepted_sha256": sha256(args.asset),
            "derived_vhd_sha256": sha256(vhd),
            "derived_vhd_bytes": vhd.stat().st_size,
            "status": "success",
            "location": args.location,
            "vm_size": args.vm_size,
            "resource_group": args.resource_group,
            "contracts": sorted(AZURE_CONTRACTS),
            "workflow": {
                "run_id": args.run_id,
                "run_attempt": args.run_attempt,
            },
        },
    )


def find_documents(root: Path, filename: str) -> dict[str, tuple[Path, dict[str, object]]]:
    result: dict[str, tuple[Path, dict[str, object]]] = {}
    paths = sorted(root.rglob(filename))
    if len(paths) != len(EXPECTED):
        fail(f"expected exactly four {filename} files under {root}, found {len(paths)}")
    for path in paths:
        document = read_json(path)
        key = document.get("key")
        if not isinstance(key, str) or key in result:
            fail(f"duplicate or invalid key in {path}")
        result[key] = (path, document)
    if set(result) != set(EXPECTED):
        fail(f"{filename} candidate set is not exact")
    return result


def stage_command(args: argparse.Namespace) -> None:
    source_commit = require_commit(args.source_commit)
    candidates_root = args.candidates.resolve()
    azure_root = args.azure_results.resolve()
    forbidden = list(candidates_root.rglob("*.sha256")) + list(azure_root.rglob("*.sha256"))
    if forbidden:
        fail("SHA-256 sidecar files are forbidden")

    candidates = find_documents(candidates_root, "candidate.json")
    azure_results = find_documents(azure_root, "azure-result.json")
    qcow_paths = sorted(candidates_root.rglob("*.qcow2"))
    if len(qcow_paths) != len(EXPECTED):
        fail(f"expected exactly four candidate QCOW2 files, found {len(qcow_paths)}")

    output = args.output.resolve()
    if output.exists():
        if any(output.iterdir()):
            fail(f"staging directory is not empty: {output}")
    else:
        output.mkdir(parents=True)

    staged: list[dict[str, object]] = []
    for key in RELEASE_ORDER:
        manifest_path, candidate = candidates[key]
        _, architecture, flavor, asset_name = validate_identity(
            candidate,
            expected_type="azurelinux4-candidate",
            key=key,
            source_commit=source_commit,
        )
        asset_path = manifest_path.parent / asset_name
        candidate = verify_candidate(
            manifest_path,
            asset_path,
            key=key,
            source_commit=source_commit,
        )

        _, azure = azure_results[key]
        validate_identity(
            azure,
            expected_type="azurelinux4-azure-acceptance",
            key=key,
            source_commit=source_commit,
        )
        digest = require_sha256(candidate.get("sha256"), f"{key} candidate digest")
        if azure.get("status") != "success":
            fail(f"{key}: Azure acceptance is not explicitly successful")
        if azure.get("qcow_sha256") != digest or azure.get("azure_accepted_sha256") != digest:
            fail(f"{key}: Azure acceptance did not validate published bytes")
        require_sha256(azure.get("derived_vhd_sha256"), f"{key} VHD digest")
        contracts = azure.get("contracts")
        if not isinstance(contracts, list) or set(contracts) != AZURE_CONTRACTS:
            fail(f"{key}: Azure contract results are absent")
        if not isinstance(azure.get("derived_vhd_bytes"), int) or azure["derived_vhd_bytes"] <= 0:
            fail(f"{key}: derived VHD size binding is absent")
        if not isinstance(azure.get("location"), str) or not azure["location"]:
            fail(f"{key}: Azure location is absent")
        if not isinstance(azure.get("vm_size"), str) or not azure["vm_size"]:
            fail(f"{key}: Azure VM size is absent")

        destination = output / asset_name
        try:
            os.link(asset_path, destination)
        except OSError:
            shutil.copyfile(asset_path, destination)
        if sha256(destination) != digest:
            fail(f"{key}: staging changed candidate bytes")
        build_validation = candidate["build_validation"]
        provenance = candidate["provenance"]
        if not isinstance(build_validation, dict) or not isinstance(provenance, dict):
            fail(f"{key}: validated metadata changed type")
        staged.append(
            {
                "key": key,
                "architecture": architecture,
                "flavor": flavor,
                "asset_name": asset_name,
                "sha256": digest,
                "bytes": destination.stat().st_size,
                "virtual_size": candidate["virtual_size"],
                "build_runner": build_validation.get("runner"),
                "provenance_digest": provenance.get("digest"),
                "azure_location": azure.get("location"),
                "azure_vm_size": azure.get("vm_size"),
                "derived_vhd_sha256": azure.get("derived_vhd_sha256"),
            }
        )

    write_json(
        output / "publish-manifest.json",
        {
            "schema": 1,
            "release_tag": args.release_tag,
            "source_commit": source_commit,
            "assets": staged,
        },
    )

    lines = [
        "Azure Linux 4.0 generalized Gen2 images built from the accepted source commit "
        f"`{source_commit}`. Every published QCOW2 passed hosted structural validation and "
        "protected-environment native validation on a matching Azure architecture.",
        "",
        "| Asset | SHA-256 | Bytes | Azure validation | Derived VHD SHA-256 (not published) |",
        "| --- | --- | ---: | --- | --- |",
    ]
    for item in staged:
        lines.append(
            f"| `{item['asset_name']}` | `{item['sha256']}` | {item['bytes']} | "
            f"`{item['azure_location']}` / `{item['azure_vm_size']}` | "
            f"`{item['derived_vhd_sha256']}` |"
        )
    lines.extend(
        [
            "",
            "The **full** images boot systemd and use cloud-init for account/key provisioning, "
            "WALinuxAgent for Azure Ready/extensions, and `sshd.service`. The **core** images "
            "boot `zvminit`, provision through `azagent`, and directly supervise OpenSSH. "
            "Core therefore requires a public SSH key in the Azure provisioning profile.",
            "",
            "Acceptance required key-only SSH, agent Ready, runtime architecture/flavor identity, "
            "root growth on an enlarged OS disk, temporary-resource-disk policy, managed-data-disk "
            "policy, and reboot/reconnect. Candidate and derived-VHD hashes were checked at every "
            "handoff; temporary VHDs and Azure resources were deleted.",
            "",
            "Secure Boot is disabled because the UKIs are currently unsigned (issue #168). "
            "**No checksum sidecar assets are published**; SHA-256 digests are recorded only "
            "in these notes and the workflow job summary.",
            "",
            "Internal provenance bindings:",
            "",
        ]
    )
    for item in staged:
        lines.append(
            f"- `{item['asset_name']}`: provenance `{item['provenance_digest']}`; "
            f"hosted build on `{item['build_runner']}`"
        )
    args.notes.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    candidate = commands.add_parser("candidate")
    candidate.add_argument("--key", required=True)
    candidate.add_argument("--architecture", required=True)
    candidate.add_argument("--flavor", required=True)
    candidate.add_argument("--asset", type=Path, required=True)
    candidate.add_argument("--validated-sha256", required=True)
    candidate.add_argument("--virtual-size", type=int, required=True)
    candidate.add_argument("--source-commit", required=True)
    candidate.add_argument("--provenance-dir", type=Path, required=True)
    candidate.add_argument("--runner", required=True)
    candidate.add_argument("--run-id", required=True)
    candidate.add_argument("--run-attempt", required=True)
    candidate.add_argument("--output", type=Path, required=True)
    candidate.set_defaults(function=candidate_command)

    verify = commands.add_parser("verify-candidate")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--asset", type=Path, required=True)
    verify.add_argument("--key", required=True)
    verify.add_argument("--source-commit", required=True)
    verify.set_defaults(function=verify_candidate_command)

    verify_vhd = commands.add_parser("verify-vhd")
    verify_vhd.add_argument("--info", type=Path, required=True)
    verify_vhd.add_argument("--vhd", type=Path, required=True)
    verify_vhd.set_defaults(function=verify_vhd_command)

    azure = commands.add_parser("azure-result")
    azure.add_argument("--manifest", type=Path, required=True)
    azure.add_argument("--asset", type=Path, required=True)
    azure.add_argument("--vhd", type=Path, required=True)
    azure.add_argument("--key", required=True)
    azure.add_argument("--source-commit", required=True)
    azure.add_argument("--location", required=True)
    azure.add_argument("--vm-size", required=True)
    azure.add_argument("--resource-group", required=True)
    azure.add_argument("--run-id", required=True)
    azure.add_argument("--run-attempt", required=True)
    azure.add_argument("--output", type=Path, required=True)
    azure.set_defaults(function=azure_result_command)

    stage = commands.add_parser("stage")
    stage.add_argument("--candidates", type=Path, required=True)
    stage.add_argument("--azure-results", type=Path, required=True)
    stage.add_argument("--source-commit", required=True)
    stage.add_argument("--release-tag", required=True)
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--notes", type=Path, required=True)
    stage.set_defaults(function=stage_command)
    return result


def main() -> None:
    args = parser().parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
