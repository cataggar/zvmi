import json
import os
import shutil
import types
import unittest
from pathlib import Path

from scripts import freebsd15_release as release


class FreeBSD15ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.root = (
            Path.cwd()
            / ".scratch"
            / f"freebsd15-release-test-{os.getpid()}-{self._testMethodName}"
        )
        self.candidates = self.root / "candidates"
        self.output = self.root / "output"
        self.notes = self.root / "notes.md"
        self.source_commit = "a" * 40
        self.root.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def make_candidate(self, architecture):
        expected = release.EXPECTED[architecture]
        candidate_dir = self.candidates / architecture
        candidate_dir.mkdir(parents=True)
        asset = candidate_dir / expected["asset_name"]
        asset.write_bytes(f"{architecture}\n".encode())
        digest = release.sha256(asset)
        manifest = candidate_dir / "candidate.json"
        release.candidate_command(
            types.SimpleNamespace(
                architecture=architecture,
                asset=asset,
                validated_sha256=digest,
                virtual_size=expected["virtual_size"],
                source_name=expected["source_name"],
                source_url=(
                    "https://download.freebsd.org/releases/VM-IMAGES/"
                    f"15.1-RELEASE/{architecture}/Latest/{expected['source_name']}"
                ),
                source_sha256=expected["source_sha256"],
                source_bytes=123,
                source_commit=self.source_commit,
                qemu_version="QEMU emulator version 10.0",
                runner=f"ubuntu-24.04-{architecture}",
                run_id="1",
                run_attempt="1",
                output=manifest,
            )
        )
        return manifest

    def stage(self):
        release.stage_command(
            types.SimpleNamespace(
                candidates=self.candidates,
                source_commit=self.source_commit,
                release_tag="FreeBSD-15.1-20260724",
                output=self.output,
                notes=self.notes,
            )
        )

    def test_stages_exact_two_asset_release(self):
        for architecture in release.EXPECTED:
            self.make_candidate(architecture)
        self.stage()

        manifest = json.loads(
            (self.output / "publish-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            {asset["asset_name"] for asset in manifest["assets"]},
            {
                "FreeBSD-15.1-aarch64.qcow2",
                "FreeBSD-15.1-x86_64.qcow2",
            },
        )
        self.assertEqual(
            {path.name for path in self.output.glob("*.qcow2")},
            {
                "FreeBSD-15.1-aarch64.qcow2",
                "FreeBSD-15.1-x86_64.qcow2",
            },
        )
        notes = self.notes.read_text(encoding="utf-8")
        self.assertIn("No checksum sidecar assets are published.", notes)
        self.assertIn(self.source_commit, notes)

    def test_rejects_incomplete_matrix(self):
        self.make_candidate("aarch64")
        with self.assertRaisesRegex(ValueError, "expected 2 candidate manifests"):
            self.stage()

    def test_rejects_changed_candidate(self):
        for architecture in release.EXPECTED:
            self.make_candidate(architecture)
        changed = (
            self.candidates
            / "x86_64"
            / release.EXPECTED["x86_64"]["asset_name"]
        )
        changed.write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "candidate (size|digest) mismatch"):
            self.stage()


if __name__ == "__main__":
    unittest.main()
