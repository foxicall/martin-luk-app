import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("pwa_release", Path(__file__).parents[1] / "pwa_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.web = self.root / "web"
        self.web.mkdir()
        for name in release.CRITICAL:
            path = self.web / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        (self.web / "index.html").write_text('<base href="/">')
        (self.web / "flutter_service_worker.js").write_text(release.ASSET)
        self.source = self.root / "industries.json"
        self.source.write_text(json.dumps({str(i): {"sector": "Test"} for i in range(7091)}))
        (self.web / release.ASSET).write_bytes(self.source.read_bytes())
        (self.web / "assets/AssetManifest.json").write_text(json.dumps({"assets/data/stock_industries.json": []}))
        self.config = {"target_url": "https://example.com/", "publisher": None}
        self.out = self.root / "release"

    def package(self):
        return release.package(self.web, self.out, self.config, "a" * 40, self.source)

    def test_archive_is_reproducible_complete_and_contains_root_release_manifest(self):
        first = self.package()
        second = self.package()
        self.assertEqual(first["sha256"], second["sha256"])
        manifest = json.loads((self.out / release.RELEASE).read_text())
        self.assertEqual(manifest["industry_count"], 7091)
        self.assertFalse(first["deployed"])
        with zipfile.ZipFile(first["archive"]) as archive:
            self.assertIn("index.html", archive.namelist())
            self.assertEqual(json.loads(archive.read(release.RELEASE)), manifest)

    def test_subpath_build_or_stale_industry_asset_is_rejected(self):
        (self.web / "index.html").write_text('<base href="/martin-luk-app/">')
        with self.assertRaisesRegex(release.ReleaseError, "base href"):
            self.package()
        (self.web / "index.html").write_text('<base href="/">')
        (self.web / release.ASSET).write_text("{}")
        with self.assertRaisesRegex(release.ReleaseError, "differs from source"):
            self.package()

    def test_tampered_archive_and_missing_publisher_never_publish(self):
        result = self.package()
        manifest = json.loads((self.out / release.RELEASE).read_text())
        with patch.object(release.subprocess, "run") as publisher:
            with self.assertRaisesRegex(release.ReleaseError, "DEPLOY_BLOCKED"):
                release.deploy(self.config, result["archive"], manifest)
            publisher.assert_not_called()
        with zipfile.ZipFile(result["archive"], "a") as archive:
            archive.writestr("unexpected.txt", "unexpected")
        with self.assertRaisesRegex(release.ReleaseError, "inventory"):
            release.validate_archive(result["archive"], manifest)

    def test_live_verification_requires_both_manifest_and_actual_payloads(self):
        self.package()
        manifest = json.loads((self.out / release.RELEASE).read_text())

        def fetch(url):
            path = url.removeprefix(self.config["target_url"]).split("?", 1)[0]
            return ((self.out / release.RELEASE).read_bytes() if path == release.RELEASE
                    else (self.web / path).read_bytes())

        with patch.object(release, "fetch", side_effect=fetch):
            self.assertEqual(release.verify(self.config, manifest)["status"], "verified")
            (self.web / "main.dart.js").write_text("stale deployed code")
            with self.assertRaisesRegex(release.ReleaseError, "Live hash mismatch"):
                release.verify(self.config, manifest)

    def test_successful_adapter_without_updated_site_is_still_failure(self):
        result = self.package()
        manifest = json.loads((self.out / release.RELEASE).read_text())
        config = {**self.config, "publisher": ["confirmed-adapter"]}
        with patch.object(release.subprocess, "run") as command:
            command.return_value.returncode = 0
            with patch.object(release, "fetch", return_value=b'{}'):
                with self.assertRaisesRegex(release.ReleaseError, "does not match"):
                    release.deploy(config, result["archive"], manifest)

    def test_target_rejects_credentials_queries_and_subpaths(self):
        for url in ["http://example.com", "https://user:secret@example.com/",
                    "https://example.com/?token=value", "https://example.com/app/"]:
            with self.assertRaises(release.ReleaseError):
                release.target_url(url)

    def test_pages_target_allows_only_its_explicit_matching_base_path(self):
        config = {**self.config, "target_url": "https://example.com/martin-luk-app/",
                  "base_href": "/martin-luk-app/"}
        (self.web / "index.html").write_text('<base href="/martin-luk-app/">')
        result = release.package(self.web, self.out, config, "a" * 40, self.source)
        self.assertTrue(result["archive"].endswith("martin-luk-pwa-pages.zip"))
        manifest = json.loads((self.out / release.RELEASE).read_text())
        self.assertEqual(manifest["base_href"], "/martin-luk-app/")
        self.assertEqual(release.target_url(config["target_url"], config["base_href"]), config["target_url"])
        with self.assertRaises(release.ReleaseError):
            release.target_url(config["target_url"], "/other/")
        with self.assertRaises(release.ReleaseError):
            release.target_url("https://example.com/../", "/../")


if __name__ == "__main__":
    unittest.main()
