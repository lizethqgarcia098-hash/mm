import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from write_build_manifest import PATCH_SCRIPT_PAIRS, SOURCE_PATHS, build_manifest, main


class BuildManifestTests(unittest.TestCase):
    def _make_repository(self, root: Path) -> None:
        for index, relative_path in enumerate(SOURCE_PATHS):
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"source-{index}".encode())
        for index, (source, patch) in enumerate(PATCH_SCRIPT_PAIRS):
            script = f"ClientMenu.registerAction('test-{index}');\n".encode()
            (root / source).write_bytes(script)
            (root / patch).write_bytes(script)
        loader = root / "ClientLoader/ClientLoader.dylib"
        loader.write_bytes(b"test-loader-binary")

    def test_manifest_binds_sources_build_and_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._make_repository(root)

            manifest = build_manifest(
                root,
                source_commit="abc123",
                xcode_version="Xcode 17",
                iphoneos_sdk_version="18.0",
                runner_os="macOS",
                built_at_utc="2026-10-16T00:00:00+00:00",
            )

            self.assertEqual(manifest["source_commit"], "abc123")
            self.assertEqual(manifest["build_status"], "BUILT")
            self.assertEqual(manifest["target"]["architecture"], "arm64")
            self.assertFalse(manifest["target"]["minecraft_executable_included"])
            self.assertEqual(manifest["toolchain"]["iphoneos_sdk"], "18.0")
            self.assertEqual(len(manifest["source_files"]), len(SOURCE_PATHS))
            self.assertIn("ClientLoader/scripts/esp_test.js", manifest["source_files"])
            self.assertIn(
                "3105/Patches/Minecraft/Application/com.mojang.minecraftpe/"
                "Documents/ClientLoader/entity_registry.json",
                manifest["source_files"],
            )
            self.assertEqual(
                manifest["loader_sha256"],
                hashlib.sha256(b"test-loader-binary").hexdigest(),
            )

    def test_rejects_source_and_patch_probe_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._make_repository(root)
            (root / PATCH_SCRIPT_PAIRS[1][1]).write_bytes(b"outdated")

            with self.assertRaisesRegex(ValueError, "differs from the 3105 patch payload"):
                build_manifest(root, "abc123", "Xcode 17", "18.0", "macOS")

    def test_reports_missing_manifest_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(FileNotFoundError, "missing input"):
                build_manifest(Path(temporary), "abc123", "Xcode 17", "18.0", "macOS")

    def test_cli_writes_manifest_with_toolchain_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._make_repository(root)
            output = root / "manifest.json"
            arguments = [
                "write_build_manifest.py",
                "--repository-root",
                str(root),
                "--output",
                str(output),
            ]
            with (
                patch.object(sys, "argv", arguments),
                patch.dict(os.environ, {"GITHUB_SHA": "abc123"}),
                patch(
                    "write_build_manifest.subprocess.check_output",
                    side_effect=["Xcode 17\n", "18.0\n"],
                ),
                patch("write_build_manifest.platform.platform", return_value="macOS"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(main(), 0)

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(manifest["source_commit"], "abc123")
            self.assertEqual(manifest["toolchain"]["xcode"], "Xcode 17")
            self.assertEqual(manifest["toolchain"]["iphoneos_sdk"], "18.0")


if __name__ == "__main__":
    unittest.main()
