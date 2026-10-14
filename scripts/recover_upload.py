#!/usr/bin/env python3
"""Recover a copy/pasted Base64 ZIP using only Python's standard library.

Decode strictly, optionally verify SHA256, and check ZIP paths/CRC before writing.
This never extracts archive contents or starts a server.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import zipfile
import zlib


class RecoveryError(ValueError):
    """An incomplete, corrupted or unsafe copied export."""


def decode_export(source: Path, expected_sha256: str | None) -> tuple[bytes, str]:
    """Allow ASCII whitespace only; pasted headers or missing data are errors."""
    encoded = re.sub(rb"[ \t\r\n\f\v]", b"", source.read_bytes())
    if not encoded:
        raise RecoveryError("Base64 輸入為空")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise RecoveryError("Base64 無效或遭截斷；只貼編碼內容，不包含 BEGIN/END 標籤") from error
    digest = hashlib.sha256(payload).hexdigest()
    if expected_sha256 is not None:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
            raise RecoveryError("--sha256 必須是完整的 64 位十六進位驗證碼")
        if digest != expected_sha256.lower():
            raise RecoveryError(f"SHA256 不一致：收到 {digest}；請重新複製完整內容")
    return payload, digest


def validate_zip(payload: bytes) -> int:
    """Reject duplicate, absolute, traversal and symlink entries before CRC reads."""
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        seen: set[str] = set()
        file_count = 0
        for info in archive.infolist():
            name = info.filename
            while name.startswith("./"):
                name = name[2:]
            if not name and info.is_dir():
                continue
            path = PurePosixPath(name)
            if (not path.parts or name.startswith("/") or ".." in path.parts
                    or "\\" in name or "\x00" in name or re.match(r"^[A-Za-z]:", name)):
                raise RecoveryError(f"ZIP 含不安全路徑：{info.filename}")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise RecoveryError(f"ZIP 含符號連結：{name}")
            canonical = path.as_posix()
            if canonical in seen:
                raise RecoveryError(f"ZIP 內有重複路徑：{canonical}")
            seen.add(canonical)
            if not info.is_dir():
                file_count += 1
        if file_count == 0:
            raise RecoveryError("ZIP 沒有任何檔案")
        failed = archive.testzip()
        if failed is not None:
            raise RecoveryError(f"ZIP CRC 檢查失敗：{failed}")
    return file_count


def save_atomic(payload: bytes, output: Path, *, overwrite: bool) -> None:
    """Avoid partial output and preserve existing files unless --force is explicit."""
    if output.exists() and not overwrite:
        raise RecoveryError(f"輸出已存在：{output}；確認後可加 --force 覆寫")
    if not output.parent.is_dir():
        raise RecoveryError(f"輸出目錄不存在：{output.parent}")
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".martin-luk-", delete=False) as handle:
            temporary = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if overwrite:
            os.replace(temporary, output)
        else:
            # Both names are in the same directory/filesystem. An exclusive hard
            # link publishes the completed file atomically and fails if a race
            # created the destination after the precheck; it never overwrites it.
            os.link(temporary, output)
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="只含 Base64 與換行的 .b64 檔")
    parser.add_argument("--output", type=Path, default=Path("martin_luk_app_upload.zip"))
    parser.add_argument("--sha256", help="匯出時列出的完整 SHA256；建議一定提供")
    parser.add_argument("--force", action="store_true", help="允許覆寫已存在的輸出 ZIP")
    arguments = parser.parse_args()
    try:
        if arguments.input.resolve() == arguments.output.resolve():
            raise RecoveryError("輸入與輸出不能是同一檔案")
        payload, digest = decode_export(arguments.input, arguments.sha256)
        count = validate_zip(payload)
        save_atomic(payload, arguments.output, overwrite=arguments.force)
        print(f"PASS ZIP CRC／安全路徑：{count} files")
        print(f"SHA256: {digest}")
        print(f"已還原：{arguments.output.resolve()} ({len(payload):,} bytes)")
        return 0
    except (OSError, RecoveryError, zipfile.BadZipFile, RuntimeError,
            NotImplementedError, EOFError, zlib.error) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
