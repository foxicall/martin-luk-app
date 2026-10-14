#!/usr/bin/env python3
"""Validate checked-in Flutter Web files without Flutter SDK or network access."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from typing import Any


class HtmlTags(HTMLParser):
    """Collect start tags; no third-party HTML parser is needed."""

    def __init__(self) -> None:
        super().__init__()
        self.tags: list[tuple[str, dict[str, str | None]]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.tags.append((tag, dict(attrs)))


def check_web(project_root: Path) -> dict[str, Any]:
    """Return explicit check results; a static check never claims Flutter compiled."""
    web = project_root / "web"
    errors: list[str] = []
    checks: list[str] = []
    required = ("index.html", "flutter_bootstrap.js", "manifest.json", "phone_preview.html")
    for name in required:
        if not (web / name).is_file():
            errors.append(f"缺少 web/{name}")
    if errors:
        return {"ok": False, "checks": checks, "errors": errors}

    try:
        parser = HtmlTags()
        parser.feed((web / "index.html").read_text(encoding="utf-8"))
        tags = parser.tags
        expectations = {
            "Flutter base href": any(tag == "base" and attrs.get("href") == "$FLUTTER_BASE_HREF" for tag, attrs in tags),
            "mobile viewport": any(tag == "meta" and attrs.get("name") == "viewport" and "width=device-width" in (attrs.get("content") or "") for tag, attrs in tags),
            "modern Flutter bootstrap": any(tag == "script" and attrs.get("src") == "flutter_bootstrap.js" for tag, attrs in tags),
            "manifest link": any(tag == "link" and attrs.get("rel") == "manifest" and attrs.get("href") == "manifest.json" for tag, attrs in tags),
        }
        for name, valid in expectations.items():
            (checks if valid else errors).append(name)
        bootstrap = (web / "flutter_bootstrap.js").read_text(encoding="utf-8")
        if "{{flutter_js}}" not in bootstrap or "{{flutter_build_config}}" not in bootstrap:
            errors.append("Flutter bootstrap 必須保留 flutter_js/flutter_build_config 替換標記")
        else:
            checks.append("bootstrap template tokens")

        manifest = json.loads((web / "manifest.json").read_text(encoding="utf-8"))
        for key in ("name", "short_name", "start_url", "display", "icons"):
            if not manifest.get(key):
                errors.append(f"manifest 缺少 {key}")
        for icon in manifest.get("icons", []):
            source = icon.get("src", "")
            path = (web / source).resolve()
            if not source or not path.is_relative_to(web.resolve()) or not path.is_file():
                errors.append(f"manifest icon 不存在或不是本機資產: {source}")
        if not errors:
            checks.append("manifest and local icons")

        phone = HtmlTags()
        phone.feed((web / "phone_preview.html").read_text(encoding="utf-8"))
        if any(tag == "iframe" and attrs.get("src") == "index.html?preview=mock" for tag, attrs in phone.tags):
            checks.append("phone iframe starts mock preview")
        else:
            errors.append("手機包裝頁需以 index.html?preview=mock 開啟 Flutter App")
    except (OSError, UnicodeError, ValueError, TypeError, AttributeError) as exc:
        errors.append(f"Web 配置讀取失敗: {exc}")
    return {"ok": not errors, "checks": checks, "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--json", action="store_true", help="輸出可供 CI 使用的 JSON 結果")
    args = parser.parse_args()
    result = check_web(args.project.resolve())
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for name in result["checks"]:
            print(f"PASS {name}")
        for error in result["errors"]:
            print(f"FAIL {error}", file=sys.stderr)
        print("Web 靜態配置檢查通過；此檢查不會編譯 Flutter。" if result["ok"] else "Web 配置檢查失敗。")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
