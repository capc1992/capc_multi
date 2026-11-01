import json
import tempfile
import unittest
from pathlib import Path

from .latest_manifest import generate, validate_manifest
from .prepare_release import prepare, version_key


class ReleaseToolsTest(unittest.TestCase):
    def test_version_order_uses_name_and_build(self):
        self.assertGreater(version_key("0.4.1", 1), version_key("0.4.0", 99))
        self.assertGreater(version_key("0.4.0", 8), version_key("0.4.0", 7))

    def test_prepare_rejects_equal_or_lower_and_updates_copy(self):
        with tempfile.TemporaryDirectory() as root:
            pubspec = Path(root) / "pubspec.yaml"
            pubspec.write_text("name: capc\nversion: 0.4.0+7\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                prepare(pubspec, "0.4.0", 7, False)
            prepare(pubspec, "0.4.1", 8, True)
            self.assertIn("version: 0.4.1+8", pubspec.read_text(encoding="utf-8"))

    def test_manifest_has_hash_size_and_no_local_path(self):
        with tempfile.TemporaryDirectory() as root:
            installer = Path(root) / "CAPC-MULTISERVICIO-Setup-0.4.1.exe"
            installer.write_bytes(b"installer-test")
            output = Path(root) / "latest.json"
            data = generate(installer, output, "0.4.1", 8, "stable", False, 7, "Mejora\nCorrección")
            self.assertEqual(data["artifact"]["sizeBytes"], 14)
            self.assertNotIn(str(Path(root)), output.read_text(encoding="utf-8"))
            validate_manifest(json.loads(output.read_text(encoding="utf-8")))

    def test_manifest_rejects_non_https_or_foreign_host(self):
        data = {
            "schemaVersion": 1, "platform": "windows-x64", "channel": "stable",
            "versionName": "0.4.1", "buildNumber": 8,
            "publishedAt": "2026-09-27T15:00:00Z", "mandatory": False,
            "minimumSupportedBuild": 7, "releaseNotes": ["Mejora"],
            "artifact": {"url": "http://evil.example/setup.exe", "sha256": "A" * 64, "sizeBytes": 1},
        }
        with self.assertRaises(ValueError):
            validate_manifest(data)


if __name__ == "__main__":
    unittest.main()
