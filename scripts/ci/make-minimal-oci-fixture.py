#!/usr/bin/env python3
"""Builds a minimal, from-scratch OCI image layout for use as the
`--container`/`ZVMI_BOOT_TEST_OCI` fixture in CI, without depending on
network access to a container registry.

The resulting layout contains a single tiny layer (just a `/hello` text
file) -- enough for `zvmi build-image` to have a valid OCI container to
merge on top of the real ISO/squashfs rootfs, matching the "container
becomes the effective root filesystem" documentation in README.md without
needing anything from it beyond `architecture`/`os` and one harmless file.

Usage: make-minimal-oci-fixture.py <output-dir>
"""

import gzip
import hashlib
import json
import os
import sys
import tarfile
import io


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <output-dir>", file=sys.stderr)
        return 2

    out_dir = sys.argv[1]
    os.makedirs(f"{out_dir}/blobs/sha256", exist_ok=True)

    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w") as tar:
        content = b"hello from zvmi CI\n"
        info = tarfile.TarInfo(name="hello.txt")
        info.size = len(content)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(content))
    tar_bytes = tar_buf.getvalue()
    diff_id = hashlib.sha256(tar_bytes).hexdigest()

    gz_bytes = gzip.compress(tar_bytes, compresslevel=6)
    layer_digest = hashlib.sha256(gz_bytes).hexdigest()
    with open(f"{out_dir}/blobs/sha256/{layer_digest}", "wb") as f:
        f.write(gz_bytes)

    config = {
        "architecture": "amd64",
        "os": "linux",
        "config": {},
        "rootfs": {"type": "layers", "diff_ids": [f"sha256:{diff_id}"]},
    }
    config_bytes = json.dumps(config).encode()
    config_digest = hashlib.sha256(config_bytes).hexdigest()
    with open(f"{out_dir}/blobs/sha256/{config_digest}", "wb") as f:
        f.write(config_bytes)

    manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": f"sha256:{config_digest}",
            "size": len(config_bytes),
        },
        "layers": [
            {
                "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                "digest": f"sha256:{layer_digest}",
                "size": len(gz_bytes),
            }
        ],
    }
    manifest_bytes = json.dumps(manifest).encode()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    with open(f"{out_dir}/blobs/sha256/{manifest_digest}", "wb") as f:
        f.write(manifest_bytes)

    index = {
        "schemaVersion": 2,
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": f"sha256:{manifest_digest}",
                "size": len(manifest_bytes),
            }
        ],
    }
    with open(f"{out_dir}/index.json", "w") as f:
        json.dump(index, f)

    with open(f"{out_dir}/oci-layout", "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)

    print(f"built minimal OCI layout at {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
