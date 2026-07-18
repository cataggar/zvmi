import json
import os
import shutil
import types
import unittest
from pathlib import Path

from scripts import azurelinux4_release as release


class AzureLinuxReleaseTest(unittest.TestCase):
    def setUp(self):
        self.root = (
            Path.cwd()
            / ".scratch"
            / f"azurelinux4-release-test-{os.getpid()}-{self._testMethodName}"
        )
        self.candidates = self.root / "candidates"
        self.azure = self.root / "azure"
        self.source_commit = "a" * 40
        self.root.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def make_bundle(self, key):
        architecture, flavor, asset_name = release.EXPECTED[key]
        candidate_dir = self.candidates / key
        candidate_dir.mkdir(parents=True)
        asset = candidate_dir / asset_name
        asset.write_bytes((key + "\n").encode())
        provenance = candidate_dir / "internal-provenance"
        provenance.mkdir()
        (provenance / "inputs.txt").write_text(f"{key}\n", encoding="utf-8")
        digest = release.sha256(asset)
        manifest = candidate_dir / "candidate.json"
        release.candidate_command(
            types.SimpleNamespace(
                key=key,
                architecture=architecture,
                flavor=flavor,
                asset=asset,
                accepted_sha256=digest,
                virtual_size=1024,
                source_commit=self.source_commit,
                provenance_dir=provenance,
                runner=f"runner-{architecture}",
                qemu_version="QEMU 10",
                run_id="1",
                run_attempt="1",
                output=manifest,
            )
        )

        azure_dir = self.azure / key
        azure_dir.mkdir(parents=True)
        vhd = azure_dir / "temporary.vhd"
        vhd.write_bytes((key + "-vhd\n").encode())
        release.azure_result_command(
            types.SimpleNamespace(
                manifest=manifest,
                asset=asset,
                vhd=vhd,
                key=key,
                source_commit=self.source_commit,
                location="eastus2",
                vm_size="Standard_D2ds_v5",
                resource_group=f"rg-{key}",
                run_id="1",
                run_attempt="1",
                output=azure_dir / "azure-result.json",
            )
        )
        vhd.unlink()

    def make_all_bundles(self):
        for key in release.EXPECTED:
            self.make_bundle(key)

    def stage(self):
        output = self.root / "staged"
        notes = self.root / "notes.md"
        release.stage_command(
            types.SimpleNamespace(
                candidates=self.candidates,
                azure_results=self.azure,
                source_commit=self.source_commit,
                release_tag="AzureLinux-4.0-20260717",
                output=output,
                notes=notes,
            )
        )
        return output, notes

    def test_stage_requires_and_copies_exact_four_bound_assets(self):
        self.make_all_bundles()
        output, notes = self.stage()
        manifest = json.loads((output / "publish-manifest.json").read_text())
        self.assertEqual(
            [item["asset_name"] for item in manifest["assets"]],
            [release.EXPECTED[key][2] for key in release.RELEASE_ORDER],
        )
        self.assertEqual(
            sorted(path.name for path in output.glob("*.qcow2")),
            sorted(item[2] for item in release.EXPECTED.values()),
        )
        self.assertIn("No checksum sidecar assets are published", notes.read_text())

    def test_stage_rejects_absent_azure_matrix_entry(self):
        self.make_all_bundles()
        (self.azure / "aarch64-core" / "azure-result.json").unlink()
        with self.assertRaises(SystemExit):
            self.stage()

    def test_stage_rejects_azure_digest_not_bound_to_candidate(self):
        self.make_all_bundles()
        path = self.azure / "x86_64-full" / "azure-result.json"
        document = json.loads(path.read_text())
        document["azure_accepted_sha256"] = "0" * 64
        path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.stage()

    def test_stage_rejects_checksum_sidecar(self):
        self.make_all_bundles()
        (self.candidates / "forbidden.sha256").write_text("0" * 64, encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.stage()

    def test_stage_rejects_tampered_internal_provenance(self):
        self.make_all_bundles()
        path = self.candidates / "x86_64-full" / "internal-provenance" / "inputs.txt"
        path.write_text("tampered\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.stage()


if __name__ == "__main__":
    unittest.main()
