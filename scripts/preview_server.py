#!/usr/bin/env python3
"""Serve preview files on a fixed port, with health diagnostics and safe paths.

Only preview/ or a selected compiled Web directory is served. The repository,
backend source, keystores and directory listings are not exposed by default.
"""
from __future__ import annotations

import argparse
import errno
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from http.client import HTTPConnection
import json
from pathlib import Path
import sys
import threading
from urllib.parse import unquote, urlsplit


def safe_file(directory: Path, request_path: str) -> Path | None:
    """Reject traversal and symlinks escaping the selected public directory."""
    path = unquote(urlsplit(request_path).path)
    if "\\" in path or "\x00" in path or ".." in path.split("/"):
        return None
    target = (directory / path.lstrip("/")).resolve()
    if not target.is_relative_to(directory.resolve()):
        return None
    return target


class PreviewHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args: object, directory: str, mode: str, **kwargs: object) -> None:
        self.preview_mode = mode
        self.public_directory = Path(directory).resolve()
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def list_directory(self, path: str) -> None:
        self.send_error(404, "Directory listings are disabled")
        return None

    def _special_route(self, *, head: bool = False) -> bool:
        path = urlsplit(self.path).path
        if path == "/__health":
            body = json.dumps({"ok": True, "mode": self.preview_mode,
                               "port": self.server.server_port}, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return True
        if path == "/":
            # Relative redirects preserve paths added by remote port proxies.
            destination = ("index.html?preview=mock" if self.preview_mode == "mock"
                           else "phone_preview.html")
            self.send_response(302)
            self.send_header("Location", destination)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        target = safe_file(self.public_directory, self.path)
        if target is None or (target.is_dir() and not (target / "index.html").is_file()):
            self.send_error(404, "Preview resource not found")
            return True
        return False

    def do_GET(self) -> None:
        if not self._special_route():
            super().do_GET()

    def do_HEAD(self) -> None:
        if not self._special_route(head=True):
            super().do_HEAD()


def verify_local_http(host: str, port: int, mode: str) -> None:
    """Probe this server in its own network namespace after serve_forever starts."""
    target = "127.0.0.1" if host in ("0.0.0.0", "localhost") else host
    for path in ("/__health", "/index.html?preview=mock" if mode == "mock" else "/phone_preview.html"):
        connection = HTTPConnection(target, port, timeout=5)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            body = response.read()
            if response.status != 200 or not body:
                raise OSError(f"HTTP {response.status}, {len(body)} bytes")
            print(f"LOCAL HTTP OK 200 {path} ({len(body)} bytes)", flush=True)
        except OSError as error:
            print(f"LOCAL HTTP CHECK FAILED {path}: {error}", file=sys.stderr, flush=True)
        finally:
            connection.close()


def main() -> int:
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--mode", choices=("mock", "flutter"), default="mock")
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port 必須介於 1 與 65535。")
    directory = (args.directory or project / ("preview" if args.mode == "mock" else "build/web")).resolve()
    if directory in (Path("/"), project) or not (directory / "index.html").is_file():
        parser.error("請指定具有 index.html 的 preview/ 或 Web 建置目錄，勿使用專案根目錄。")
    if args.mode == "flutter" and not (directory / "phone_preview.html").is_file():
        parser.error("Flutter Web 缺少 phone_preview.html；請先完整建置或下載 CI Web 產物。")
    handler = partial(PreviewHandler, directory=str(directory), mode=args.mode)
    try:
        server = ThreadingHTTPServer((args.host, args.port), handler)
    except PermissionError as error:
        print(f"無法監聽 {args.host}:{args.port}：執行沙箱拒絕 socket ({error})。\n"
              "需要此執行環境允許本機服務監聽；改成 0.0.0.0 不會解除沙箱限制。\n"
              "也可下載 preview/index.html，在您的電腦以瀏覽器直接開啟。", file=sys.stderr)
        return 3
    except OSError as error:
        if error.errno == errno.EADDRINUSE:
            print(f"Port {args.port} 已被占用；請先查明服務或以 --port 換埠。", file=sys.stderr)
        else:
            print(f"無法啟動預覽服務：{error}", file=sys.stderr)
        return 4
    print(f"LISTEN {args.host}:{args.port} | mode={args.mode}", flush=True)
    print(f"同一台機器檢查：http://127.0.0.1:{args.port}/__health", flush=True)
    print(f"遠端瀏覽器：請開啟平台提供的 {args.port} 埠轉送 URL，或使用 SSH tunnel。", flush=True)
    print("0.0.0.0 是監聽位址；遠端瀏覽器的 127.0.0.1 指向瀏覽器所在機器。", flush=True)
    threading.Thread(target=verify_local_http, args=(args.host, args.port, args.mode), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n預覽服務已停止。", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
