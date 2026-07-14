#!/usr/bin/env python3
"""Build a minimal generalized Azure Linux 4 Gen2 VHD."""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


BASE_IMAGE = "azurelinux-beta/base/core"
BASE_TAG = "4.0"
MCR_BASE = "https://mcr.microsoft.com/v2"
AZL4_REPO = "https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64"
ISO_URL = "https://aka.ms/azurelinux-4.0-x86_64.iso"
ISO_CHECKSUM_URL = "https://aka.ms/azurelinux-4.0-x86_64-iso-checksum"
ISO_NAME = "AzureLinux-4.0-x86_64.iso"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_INDEX = "application/vnd.oci.image.index.v1+json"
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_INDEX = "application/vnd.docker.distribution.manifest.list.v2+json"
ZVMI_MAX_LAYER_SIZE = 128 * 1024 * 1024


def run(args: list[str | Path], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    command = [str(arg) for arg in args]
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, check=True, text=True, **kwargs)


def sudo(args: list[str | Path], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return run(["sudo", *args], **kwargs)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_bytes(url: str, accept: str | None = None) -> tuple[bytes, str]:
    headers = {"Accept": accept} if accept else {}
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read(), response.headers.get_content_type()


def download_blob(repository: str, digest: str, destination: Path) -> None:
    expected = digest.removeprefix("sha256:")
    if destination.exists() and sha256_file(destination) == expected:
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".part")
    request = urllib.request.Request(f"{MCR_BASE}/{repository}/blobs/{digest}")
    actual = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
            actual.update(chunk)
    if actual.hexdigest() != expected:
        partial.unlink(missing_ok=True)
        raise RuntimeError(f"digest mismatch for {digest}")
    partial.replace(destination)


def resolve_manifest(repository: str, reference: str) -> tuple[dict[str, Any], str]:
    accept = ", ".join((OCI_INDEX, DOCKER_INDEX, OCI_MANIFEST, DOCKER_MANIFEST))
    manifest_bytes, content_type = fetch_bytes(
        f"{MCR_BASE}/{repository}/manifests/{reference}", accept
    )
    document = json.loads(manifest_bytes)
    media_type = document.get("mediaType", content_type)
    if media_type not in (OCI_INDEX, DOCKER_INDEX):
        return document, f"sha256:{hashlib.sha256(manifest_bytes).hexdigest()}"

    descriptor = next(
        (
            item
            for item in document["manifests"]
            if item.get("platform", {}).get("os") == "linux"
            and item.get("platform", {}).get("architecture") == "amd64"
        ),
        None,
    )
    if descriptor is None:
        raise RuntimeError(f"{repository}:{reference} has no linux/amd64 manifest")

    manifest_bytes, _ = fetch_bytes(
        f"{MCR_BASE}/{repository}/manifests/{descriptor['digest']}", accept
    )
    actual = f"sha256:{hashlib.sha256(manifest_bytes).hexdigest()}"
    if actual != descriptor["digest"]:
        raise RuntimeError(f"manifest digest mismatch: expected {descriptor['digest']}, got {actual}")
    return json.loads(manifest_bytes), actual


def safe_layer_path(name: str) -> PurePosixPath | None:
    stripped = name.removeprefix("./").lstrip("/")
    if not stripped:
        return None
    path = PurePosixPath(stripped)
    if ".." in path.parts:
        raise RuntimeError(f"unsafe OCI layer path: {name}")
    return path


def remove_opaque_children(rootfs: Path, relative: PurePosixPath) -> None:
    target = rootfs.joinpath(*relative.parts)
    if not target.exists():
        return
    sudo(
        [
            "find",
            target,
            "-mindepth",
            "1",
            "-maxdepth",
            "1",
            "-exec",
            "rm",
            "-rf",
            "--",
            "{}",
            "+",
        ]
    )


def extract_layer(layer: Path, rootfs: Path) -> None:
    whiteouts: list[PurePosixPath] = []
    opaque_directories: list[PurePosixPath] = []
    with tarfile.open(layer, "r:*") as archive:
        for member in archive:
            path = safe_layer_path(member.name)
            if path is None:
                continue
            basename = path.name
            if basename == ".wh..wh..opq":
                opaque_directories.append(path.parent)
            elif basename.startswith(".wh."):
                whiteouts.append(path.parent / basename.removeprefix(".wh."))

    for relative in opaque_directories:
        remove_opaque_children(rootfs, relative)
    for relative in whiteouts:
        sudo(["rm", "-rf", "--", rootfs.joinpath(*relative.parts)])

    sudo(["tar", "-xzf", layer, "-C", rootfs, "--numeric-owner"])
    sudo(["find", rootfs, "-name", ".wh.*", "-delete"])


def pull_rootfs(work_dir: Path, rootfs: Path) -> str:
    manifest, manifest_digest = resolve_manifest(BASE_IMAGE, BASE_TAG)
    print(f"Resolved mcr.microsoft.com/{BASE_IMAGE}:{BASE_TAG} to {manifest_digest}")

    if rootfs.exists():
        sudo(["rm", "-rf", "--", rootfs])
    rootfs.mkdir(parents=True)

    blobs = work_dir / "downloads" / "blobs"
    for descriptor in manifest["layers"]:
        digest = descriptor["digest"]
        layer = blobs / digest.removeprefix("sha256:")
        download_blob(BASE_IMAGE, digest, layer)
        extract_layer(layer, rootfs)
    return manifest_digest


def detect_binfmt_interpreter() -> Path | None:
    if platform.machine() in ("x86_64", "amd64"):
        return None

    registration = Path("/proc/sys/fs/binfmt_misc/qemu-x86_64")
    if not registration.exists():
        raise RuntimeError(
            "x86_64 binfmt is not registered; install and enable qemu-user-static-x86"
        )
    lines = registration.read_text().splitlines()
    if not lines or lines[0] != "enabled":
        raise RuntimeError("the qemu-x86_64 binfmt registration is disabled")
    interpreter_line = next((line for line in lines if line.startswith("interpreter ")), None)
    if interpreter_line is None:
        raise RuntimeError("the qemu-x86_64 binfmt registration has no interpreter")

    static_qemu = shutil.which("qemu-x86_64-static")
    if static_qemu is None:
        raise RuntimeError(
            "qemu-x86_64-static is required on non-x86 hosts; on Azure Linux run "
            "`sudo tdnf install -y qemu-user-static-x86`"
        )
    return Path(interpreter_line.split(" ", 1)[1])


def write_root_file(rootfs: Path, relative: str, content: str, mode: str) -> None:
    temporary = rootfs.parent / (Path(relative).name + ".tmp")
    temporary.write_text(content)
    destination = rootfs / relative
    sudo(["install", "-D", "-o", "root", "-g", "root", "-m", mode, temporary, destination])
    temporary.unlink()


def install_guest_content(repo_root: Path, work_dir: Path, rootfs: Path) -> None:
    native_prefix = work_dir / "native"
    guest_prefix = work_dir / "guest"
    run(["zig", "build", "--prefix", native_prefix], cwd=repo_root)
    run(
        [
            "zig",
            "build",
            "-Dtarget=x86_64-linux",
            "-Doptimize=ReleaseSmall",
            "--prefix",
            guest_prefix,
        ],
        cwd=repo_root,
    )

    binfmt_interpreter = detect_binfmt_interpreter()
    if binfmt_interpreter is not None:
        guest_interpreter = rootfs / binfmt_interpreter.relative_to("/")
        sudo(["install", "-D", "-m", "0755", shutil.which("qemu-x86_64-static"), guest_interpreter])

    signing_key = rootfs / "etc/pki/rpm-gpg/RPM-GPG-KEY-azurelinux-4.0-x86_64"
    host_signing_key = work_dir / "RPM-GPG-KEY-azurelinux-4.0-x86_64"
    sudo(["install", "-m", "0644", signing_key, host_signing_key])

    sudo(
        [
            "dnf",
            "-y",
            "--installroot",
            rootfs,
            "--releasever=4.0",
            "--forcearch=x86_64",
            "--repo=azurelinux-base",
            f"--setopt=azurelinux-base.gpgkey=file://{host_signing_key}",
            "--setopt=install_weak_deps=False",
            "install",
            "openssh-server",
            "sudo",
        ]
    )

    sudo(["rm", "-f", rootfs / "sbin/init"])
    sudo(["install", "-m", "0755", guest_prefix / "bin/azinit", rootfs / "sbin/init"])
    for command in ("poweroff", "reboot", "shutdown"):
        link = rootfs / "sbin" / command
        sudo(["rm", "-f", link])
        sudo(["ln", "-s", "init", link])
    sudo(["install", "-m", "0755", guest_prefix / "bin/azagent", rootfs / "usr/sbin/azagent"])

    write_root_file(
        rootfs,
        "etc/ssh/sshd_config.d/10-azinit.conf",
        "PasswordAuthentication no\n"
        "PermitEmptyPasswords no\n"
        "PubkeyAuthentication yes\n",
        "0600",
    )
    write_root_file(
        rootfs,
        "etc/waagent.conf",
        "ResourceDisk.Format=y\n"
        "ResourceDisk.Filesystem=ext4\n"
        "ResourceDisk.MountPoint=/mnt/resource\n"
        "ResourceDisk.EnableSwap=n\n",
        "0644",
    )

    sudo(["chroot", rootfs, "/usr/bin/rpm", "-q", "openssh-server", "sudo"])
    sudo(["chroot", rootfs, "/usr/bin/ssh-keygen", "-A"])
    sudo(["chroot", rootfs, "/usr/sbin/sshd", "-t"])

    sudo(["find", rootfs / "etc/ssh", "-maxdepth", "1", "-name", "ssh_host_*", "-delete"])
    sudo(["rm", "-f", rootfs / "etc/hostname", rootfs / "var/lib/dbus/machine-id"])
    sudo(["rm", "-rf", rootfs / "var/lib/azagent"])
    sudo(["install", "-d", "-m", "0755", rootfs / "home", rootfs / "var/lib"])
    sudo(["truncate", "-s", "0", rootfs / "etc/machine-id"])

    if binfmt_interpreter is not None:
        sudo(["rm", "-f", rootfs / binfmt_interpreter.relative_to("/")])

    sudo(
        [
            "dnf",
            "--installroot",
            rootfs,
            "--releasever=4.0",
            "--forcearch=x86_64",
            "--repo=azurelinux-base",
            "clean",
            "all",
        ]
    )
    sudo(["rm", "-rf", rootfs / "var/cache/dnf", rootfs / "var/log/dnf.log"])

    run(["file", rootfs / "sbin/init", rootfs / "usr/sbin/azagent", rootfs / "usr/sbin/sshd"])


def write_json_blob(blobs: Path, document: dict[str, Any]) -> tuple[str, int]:
    content = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
    digest = hashlib.sha256(content).hexdigest()
    (blobs / digest).write_bytes(content)
    return f"sha256:{digest}", len(content)


def create_oci_layer(
    work_dir: Path,
    rootfs: Path,
    blobs: Path,
    index: int,
    includes: list[str],
    excludes: list[str] | None = None,
) -> tuple[dict[str, Any], str]:
    layer_tar = work_dir / f"rootfs-{index}.tar"
    layer_gzip = work_dir / f"rootfs-{index}.tar.gz"
    command: list[str | Path] = [
        "tar",
        "--sort=name",
        "--mtime=@0",
        "--numeric-owner",
        "--format=pax",
        "--pax-option=delete=atime,delete=ctime",
    ]
    for excluded in excludes or []:
        command.append(f"--exclude={excluded}")
    command.extend(["-C", rootfs, "-cf", layer_tar, *includes])
    sudo(command)
    sudo(["chown", f"{os.getuid()}:{os.getgid()}", layer_tar])
    if layer_tar.stat().st_size > ZVMI_MAX_LAYER_SIZE:
        raise RuntimeError(
            f"{layer_tar} is {layer_tar.stat().st_size} bytes, exceeding zvmi's "
            f"{ZVMI_MAX_LAYER_SIZE}-byte decompressed-layer limit"
        )

    with layer_tar.open("rb") as source, layer_gzip.open("wb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0, compresslevel=9) as output:
            shutil.copyfileobj(source, output, 1024 * 1024)

    diff_id = f"sha256:{sha256_file(layer_tar)}"
    layer_digest = f"sha256:{sha256_file(layer_gzip)}"
    layer_size = layer_gzip.stat().st_size
    shutil.copyfile(layer_gzip, blobs / layer_digest.removeprefix("sha256:"))
    return (
        {
            "digest": layer_digest,
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "size": layer_size,
        },
        diff_id,
    )


def create_oci_layout(work_dir: Path, rootfs: Path, base_digest: str) -> Path:
    layout = work_dir / "oci-generalized"
    if layout.exists():
        shutil.rmtree(layout)
    blobs = layout / "blobs/sha256"
    blobs.mkdir(parents=True)

    # zvmi deliberately caps each decompressed OCI layer at 128 MiB. Split
    # the flattened rootfs by its two largest trees so each tar stays well
    # below that safety bound without changing the resulting filesystem.
    layer_specs = [
        (
            sorted(path.name for path in rootfs.iterdir()),
            ["usr/share", "usr/lib64"],
        ),
        (["usr/share"], None),
        (["usr/lib64"], None),
    ]
    layers: list[dict[str, Any]] = []
    diff_ids: list[str] = []
    for index, (includes, excludes) in enumerate(layer_specs):
        descriptor, diff_id = create_oci_layer(
            work_dir, rootfs, blobs, index, includes, excludes
        )
        layers.append(descriptor)
        diff_ids.append(diff_id)

    created = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    config_digest, config_size = write_json_blob(
        blobs,
        {
            "architecture": "amd64",
            "config": {
                "Entrypoint": ["/sbin/init"],
                "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            },
            "created": created,
            "history": [
                {
                    "comment": f"Based on mcr.microsoft.com/{BASE_IMAGE}:{BASE_TAG} ({base_digest})",
                    "created": created,
                    "created_by": "scripts/build-generalized-azurelinux4.py",
                }
            ],
            "os": "linux",
            "rootfs": {"diff_ids": diff_ids, "type": "layers"},
        },
    )
    manifest_digest, manifest_size = write_json_blob(
        blobs,
        {
            "config": {
                "digest": config_digest,
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "size": config_size,
            },
            "layers": layers,
            "mediaType": OCI_MANIFEST,
            "schemaVersion": 2,
        },
    )
    (layout / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}\n')
    (layout / "index.json").write_text(
        json.dumps(
            {
                "manifests": [
                    {
                        "annotations": {
                            "org.opencontainers.image.ref.name": "generalized",
                        },
                        "digest": manifest_digest,
                        "mediaType": OCI_MANIFEST,
                        "size": manifest_size,
                    }
                ],
                "schemaVersion": 2,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    )
    return layout


def download_iso(work_dir: Path) -> Path:
    iso = work_dir / ISO_NAME
    checksum_bytes, _ = fetch_bytes(ISO_CHECKSUM_URL)
    expected = checksum_bytes.decode().split()[0]
    if iso.exists() and sha256_file(iso) == expected:
        return iso

    partial = iso.with_suffix(".iso.part")
    run(["curl", "-fL", "--retry", "3", "-C", "-", "-o", partial, ISO_URL])
    if sha256_file(partial) != expected:
        raise RuntimeError(f"checksum mismatch for {ISO_NAME}")
    partial.replace(iso)
    return iso


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iso", type=Path, help="Azure Linux 4 x86_64 ISO; downloaded if omitted")
    parser.add_argument("--output", type=Path, default=Path("zvmi-azurelinux4-generalized.vhd"))
    parser.add_argument("--size", default="768M")
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path(".scratch/generalized-azurelinux4"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    work_dir = args.work_dir.resolve()
    output = args.output.resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)

    iso = args.iso.resolve() if args.iso else download_iso(work_dir)
    if not iso.is_file():
        raise RuntimeError(f"ISO does not exist: {iso}")

    rootfs = work_dir / "rootfs"
    base_digest = pull_rootfs(work_dir, rootfs)
    install_guest_content(repo_root, work_dir, rootfs)
    layout = create_oci_layout(work_dir, rootfs, base_digest)

    output.unlink(missing_ok=True)
    zvmi = work_dir / "native/bin/zvmi"
    run(
        [
            zvmi,
            "build-image",
            "--iso",
            iso,
            "--container",
            layout,
            "--generation",
            "2",
            "--size",
            args.size,
            "--skip-iso-rootfs",
            "--extra-kernel-options",
            "init=/sbin/init azinit.mode=persistent console=tty0 console=ttyS0,115200n8",
            "-o",
            output,
            "-O",
            "vhd",
            "-v",
        ]
    )
    print(f"Built {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
