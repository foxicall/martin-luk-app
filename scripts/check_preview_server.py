#!/usr/bin/env python3
"""Exercise HTTP handlers without sockets (compatible with restricted sandboxes)."""
from __future__ import annotations

from contextlib import redirect_stderr
from io import BytesIO, StringIO
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from preview_server import PreviewHandler, safe_file


class FakeSocket:
    def __init__(self, request: bytes) -> None:
        self.request = request
        self.output = bytearray()

    def makefile(self, mode: str, buffering: int = -1) -> BytesIO:
        return BytesIO(self.request)

    def sendall(self, data: bytes) -> None:
        self.output.extend(data)


class HandlerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "index.html").write_text("<!doctype html><title>手機預覽</title>", encoding="utf-8")
        (self.directory / "phone_preview.html").write_text("<iframe></iframe>", encoding="utf-8")
        (self.directory / "folder").mkdir()

    def request(self, path: str, *, method: str = "GET", mode: str = "mock") -> tuple[str, bytes]:
        socket = FakeSocket(f"{method} {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
        server = SimpleNamespace(server_port=8080, server_name="localhost")
        with redirect_stderr(StringIO()):
            PreviewHandler(socket, ("127.0.0.1", 10001), server,
                           directory=str(self.directory), mode=mode)
        headers, _, body = bytes(socket.output).partition(b"\r\n\r\n")
        return headers.decode(), body

    def test_health_is_json_and_head_has_no_body(self) -> None:
        headers, body = self.request("/__health")
        self.assertIn("200 OK", headers)
        self.assertIn("application/json; charset=utf-8", headers)
        self.assertIn(b'"ok": true', body)
        self.assertIn(b'"port": 8080', body)
        self.assertEqual(self.request("/__health", method="HEAD")[1], b"")

    def test_entry_redirects_to_correct_preview(self) -> None:
        headers, _ = self.request("/")
        self.assertIn("Location: index.html?preview=mock", headers)
        headers, _ = self.request("/", mode="flutter")
        self.assertIn("Location: phone_preview.html", headers)

    def test_html_has_correct_mime_and_utf8_body(self) -> None:
        headers, body = self.request("/index.html?preview=mock")
        self.assertIn("200 OK", headers)
        self.assertIn("text/html", headers)
        self.assertIn("手機預覽".encode(), body)
        self.assertIn("Cache-Control: no-cache", headers)

    def test_missing_file_and_directory_listing_fail(self) -> None:
        for path in ("/missing", "/folder/"):
            with self.subTest(path=path):
                self.assertIn("404", self.request(path)[0])

    def test_traversal_and_null_paths_are_not_served(self) -> None:
        for path in ("/../backend/api.py", "/%2e%2e/backend/api.py", "/%00", "/..%5csecret"):
            with self.subTest(path=path):
                self.assertIsNone(safe_file(self.directory, path))
                self.assertIn("404", self.request(path)[0])

    def test_symlink_cannot_escape_public_directory(self) -> None:
        with tempfile.TemporaryDirectory() as other:
            secret = Path(other) / "secret.txt"
            secret.write_text("private")
            (self.directory / "outside").symlink_to(secret)
            self.assertIsNone(safe_file(self.directory, "/outside"))
            self.assertIn("404", self.request("/outside")[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
