import json
import os
import re
import shutil
import types
import unittest
from pathlib import Path

from scripts import azurelinux4_release as release


ROOT = Path(__file__).resolve().parents[1]


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

    def test_fixed_vhd_alignment_applies_to_virtual_size_not_footer(self):
        virtual_size = 2 * release.AZURE_VHD_ALIGNMENT
        info = {
            "format": "vpc",
            "virtual-size": virtual_size,
            "format-specific": {"data": {"type": "fixed"}},
        }
        file_size = virtual_size + release.VHD_FOOTER_BYTES
        self.assertNotEqual(file_size % release.AZURE_VHD_ALIGNMENT, 0)
        self.assertEqual(
            release.validate_azure_vhd_info(info, file_size), virtual_size
        )

    def test_fixed_vhd_rejects_unaligned_virtual_size(self):
        virtual_size = 2 * release.AZURE_VHD_ALIGNMENT + 512
        info = {
            "format": "vpc",
            "virtual-size": virtual_size,
            "format-specific": {"data": {"type": "fixed"}},
        }
        with self.assertRaises(SystemExit):
            release.validate_azure_vhd_info(
                info, virtual_size + release.VHD_FOOTER_BYTES
            )

    def test_fixed_vhd_requires_exact_footer_relationship(self):
        virtual_size = 2 * release.AZURE_VHD_ALIGNMENT
        info = {
            "format": "vpc",
            "virtual-size": virtual_size,
            "format-specific": {"data": {"type": "fixed"}},
        }
        with self.assertRaises(SystemExit):
            release.validate_azure_vhd_info(info, virtual_size)

    def test_release_artifacts_use_visible_attempt_bound_staging(self):
        workflow = (ROOT / ".github/workflows/azurelinux4-release.yml").read_text()
        staging = dict(
            (name, value.strip())
            for name, value in re.findall(
                r"^[ \t]+(BUNDLE_DIR|RESULT_DIR):[ \t]+([^\n]+)$",
                workflow,
                re.MULTILINE,
            )
        )
        self.assertEqual(set(staging), {"BUNDLE_DIR", "RESULT_DIR"})
        for path in staging.values():
            self.assertFalse(any(part.startswith(".") for part in Path(path).parts))

        artifact_references = [
            line.strip()
            for line in workflow.splitlines()
            if re.match(r"\s+(name|pattern): azurelinux4-(candidate|azure)-", line)
        ]
        self.assertEqual(len(artifact_references), 5)
        for reference in artifact_references:
            self.assertIn("${{ needs.prepare.outputs.source_commit }}", reference)
            self.assertIn("${{ github.run_attempt }}", reference)

    def test_release_builds_use_native_github_hosted_runners(self):
        workflow = (ROOT / ".github/workflows/azurelinux4-release.yml").read_text()
        self.assertIn("runs-on: ${{ matrix.runner }}", workflow)
        self.assertEqual(workflow.count("runner: ubuntu-24.04\n"), 2)
        self.assertEqual(workflow.count("runner: ubuntu-24.04-arm\n"), 2)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("runner_arch:", workflow)

    def test_ci_actions_are_pinned_to_audited_commits(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        actions = re.findall(
            r"^[ \t]*-?[ \t]*uses:[ \t]+(\S+)[ \t]+#[ \t]+(\S+)$",
            workflow,
            re.MULTILINE,
        )
        self.assertEqual(
            actions,
            [
                (
                    "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5",
                    "v4",
                ),
                (
                    "cataggar/ghr/actions/install@"
                    "7d8c3ef0886dd428a97727fce3b74909d6eace78",
                    "v0.6.6",
                ),
            ],
        )
        for action, _ in actions:
            self.assertRegex(action, r"@[0-9a-f]{40}$")

    def test_resource_group_state_precedes_create_and_cleanup_is_guarded(self):
        script = (ROOT / "scripts/azurelinux4_azure_acceptance.sh").read_text()
        persist = script.index("printf '%s\\n' \"$resource_group\" >\"$STATE_FILE\"")
        create = script.index("if ! az group create")
        self.assertLess(persist, create)
        self.assertIn('[[ "$resource_group" == "$expected_resource_group" ]]', script)
        ownership_guard = script.index("if ! python3 - \"$metadata_file\"")
        delete = script.index("if ! az group delete")
        self.assertLess(ownership_guard, delete)

    def test_qemu_readme_distinguishes_default_full_and_core_output(self):
        readme = (ROOT / "README.md").read_text()
        section = readme.split("### Booting the release image with QEMU", 1)[1]
        self.assertIn("full image's systemd startup and login prompt", section)
        self.assertIn("only when an explicit `*.core.qcow2` image", section)
        self.assertNotIn(
            "default secure command line, a successful local boot reaches\n"
            "the PID 1 readiness marker",
            section,
        )


if __name__ == "__main__":
    unittest.main()
