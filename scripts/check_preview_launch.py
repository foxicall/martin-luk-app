#!/usr/bin/env python3
"""Exercise launcher mode selection and arguments without SDKs, network or sockets.

These regression tests use isolated project directories and stub executables.
They verify which process would be launched, not whether a real server responds.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


LAUNCHER = Path(__file__).resolve().with_name("preview_web.sh")
BASH = shutil.which("bash") or "/bin/bash"


class PreviewLauncherTests(unittest.TestCase):
    """Prevent regressions to loopback-only and unconditional SDK requirements."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="preview-launch-")
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "preview").mkdir()
        (self.root / "preview/index.html").write_text("Mock fixture", encoding="utf-8")
        shutil.copyfile(LAUNCHER, self.root / "scripts/preview_web.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ("dirname", "cat", "mkdir"):
            target = shutil.which(command)
            if not target:
                self.skipTest(f"Required test utility is unavailable: {command}")
            (self.bin / command).symlink_to(target)
        self.log = self.root / "calls.txt"
        self.env = {**os.environ, "PATH": str(self.bin), "TEST_LOG": str(self.log)}
        self.stub("python3")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def stub(self, name: str, extra: str = "") -> None:
        path = self.bin / name
        path.write_text(
            f"#!{BASH}\n"
            f"printf '%s\\n' 'BEGIN {name}' \"$@\" 'END' >> \"$TEST_LOG\"\n"
            + extra,
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_launcher(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, str(self.root / "scripts/preview_web.sh"), *args],
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def calls(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def built_fixture(self) -> None:
        directory = self.root / "build/web"
        directory.mkdir(parents=True)
        (directory / "index.html").write_text("Compiled fixture", encoding="utf-8")

    def test_default_without_flutter_serves_mock_on_all_interfaces(self) -> None:
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("standalone HTML mock", result.stdout)
        self.assertIn("--host\n0.0.0.0\n--port\n8080\n--mode\nmock", self.calls())
        self.assertIn(str(self.root / "preview"), self.calls())
        self.assertNotIn("check_web.py", self.calls())
        self.assertNotIn("BEGIN flutter", self.calls())

    def test_mock_allows_explicit_loopback_and_port(self) -> None:
        result = self.run_launcher("--mock", "--host", "127.0.0.1", "--port", "8090")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--host\n127.0.0.1\n--port\n8090", self.calls())

    def test_explicit_build_without_flutter_fails_without_mock_fallback(self) -> None:
        result = self.run_launcher("--build")
        self.assertEqual(result.returncode, 127)
        self.assertIn("requires an existing Flutter SDK", result.stderr)
        self.assertEqual(self.calls(), "")

    def test_existing_build_is_preferred_without_flutter(self) -> None:
        self.built_fixture()
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--mode\nflutter\n--directory", self.calls())
        self.assertIn(str(self.root / "build/web"), self.calls())
        self.assertNotIn("check_web.py", self.calls())

    def test_serve_built_does_not_execute_installed_flutter(self) -> None:
        self.built_fixture()
        self.stub("flutter")
        result = self.run_launcher("--serve-built")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("BEGIN flutter", self.calls())

    def test_missing_compiled_index_fails_with_clear_message(self) -> None:
        result = self.run_launcher("--serve-built")
        self.assertEqual(result.returncode, 1)
        self.assertIn("build/web/index.html", result.stderr)
        self.assertIn("use --mock", result.stderr)

    def test_dev_passes_remote_bind_and_mock_flag_to_flutter(self) -> None:
        self.stub("flutter")
        result = self.run_launcher("--dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run\n-d\nweb-server\n--web-hostname\n0.0.0.0\n--web-port\n8080", self.calls())
        self.assertIn("--dart-define=USE_MOCK_DATA=true", self.calls())
        self.assertNotIn("--web-renderer", self.calls())
        self.assertIn("forwarded port URL", result.stdout)

    def test_chrome_passes_viewport_flag(self) -> None:
        self.stub("flutter")
        result = self.run_launcher("--chrome")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run\n-d\nchrome", self.calls())
        self.assertIn("--web-browser-flag=--window-size=430,940", self.calls())

    def test_build_runs_flutter_then_serves_compiled_assets(self) -> None:
        self.stub(
            "flutter",
            'if [[ "$1" == "build" ]]; then\n'
            '  mkdir -p build/web\n'
            '  printf "fixture" > build/web/index.html\n'
            '  printf "fixture" > build/web/phone_preview.html\n'
            "fi\n",
        )
        result = self.run_launcher("--build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pub\nget", self.calls())
        self.assertIn("build\nweb\n--release\n--no-web-resources-cdn", self.calls())
        self.assertIn("--mode\nflutter", self.calls())

    def test_invalid_ports_fail_before_launch(self) -> None:
        for port in ("0", "65536", "8080;false", "-1", "abc"):
            with self.subTest(port=port):
                result = self.run_launcher("--port", port)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Port must", result.stderr)
                self.assertEqual(self.calls(), "")

    def test_invalid_host_and_conflicting_modes_fail_before_launch(self) -> None:
        for args in (("--host", "0.0.0.0;false"), ("--host", ""), ("--mock", "--dev")):
            with self.subTest(args=args):
                result = self.run_launcher(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), "")

    def test_help_needs_no_sdk(self) -> None:
        result = self.run_launcher("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--mock", result.stdout)
        self.assertIn("--serve-built", result.stdout)
        self.assertIn("0.0.0.0:8080", result.stdout)
        self.assertEqual(self.calls(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
