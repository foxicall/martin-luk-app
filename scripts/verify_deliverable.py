#!/usr/bin/env python3
"""Validate the offline preview/source bundle using Python's standard library.

This checks packaging integrity; Flutter analyze/test/build still run in Actions.
No SDK, backend imports, network connection or Node installation is required.
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from html.parser import HTMLParser
from typing import Any
import xml.etree.ElementTree as ET
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_NAME = "FILE_MANIFEST.json"
# Keep these patterns in sync with package_deliverable.sh. .github is included.
EXCLUDED_DIRECTORIES = {
    ".git", "build", ".dart_tool", ".gradle", ".cache", "cache", "data_cache",
    "__pycache__", ".venv", "venv", "node_modules", ".pytest_cache",
    ".mypy_cache", ".ruff_cache", ".idea", ".vscode", ".toolchains", "toolchains",
    ".aws", ".codex", ".agents", "logs",
}
EXCLUDED_FILE_PATTERNS = (
    "*.pyc", "*.pyo", "*.log", "*.zip", "*.b64", "*.sha256", "*.jks", "*.keystore",
    "*.pem", "*.key", ".DS_Store", "Thumbs.db", "local.properties",
    "key.properties", ".env", ".env.local", ".env.production", ".env.*.local",
    "apply_market_scan_fix.py", "apply_market_scan_timeout_fix.py",
)
REQUIRED_FILES = (
    "R_TARGET_DISPLAY_FIX.md", "lib/widgets/manual_trade_levels.dart",
    "test/trade_levels_test.dart", "test/manual_trade_levels_test.dart",
    "TW_OFFICIAL_CSV_FALLBACK.md", "lib/services/tw_issuer_csv.dart",
    "test/tw_issuer_csv_test.dart", "test/tw_official_fallback_test.dart",
    "TW_SCAN_STABILITY_FIX.md", "test/tw_universe_stability_test.dart",
    "test/tw_universe_resume_integration_test.dart",
    "RECOMMENDATION_LEVELS.md", "test/recommendation_trade_levels_test.dart",
    "MOBILE_TW_SCAN.md", "lib/services/mobile_scan_checkpoint.dart",
    "test/mobile_tw_rolling_repository_test.dart", "test/mobile_tw_polling_test.dart",
    "FULL_MARKET_SETUP.md", "lib/services/backend_connection_service.dart",
    "test/backend_connection_service_test.dart", "test/backend_setup_settings_test.dart",
    "test/dashboard_scope_test.dart", "backend/tests/test_capabilities.py",
    "US_UNIVERSE_FIX.md", "lib/services/us_stock_directory.dart",
    "test/us_stock_directory_test.dart", "test/us_universe_fallback_test.dart",
    "test/us_universe_http_smoke_test.dart",
    "ALL_STOCKS_UPDATE.md", "scripts/import_bundled_metadata.py",
    "backend/engine/listed_universe.py", "backend/tests/test_listed_universe.py",
    "backend/tests/test_expanded_symbols.py", "backend/tests/test_rolling_scan.py",
    "scripts/tests/test_refresh_stock_metadata.py",
    "test/expanded_symbol_test.dart", "test/rolling_scan_snapshot_test.dart",
    "metadata_snapshots/SOURCES.json", "metadata_snapshots/nasdaqlisted.txt",
    "metadata_snapshots/otherlisted.txt", "metadata_snapshots/tw_stock_list_20261006.csv",
    "metadata_snapshots/twse_equities_common_20260326.csv",
    "metadata_snapshots/tpex_equities_common_20260326.csv",
    "metadata_snapshots/tw_names_20261014.json",
    "README_HOW_TO_BUILD.md", "README.md", "BUILD_ANDROID.md", "BUILD_STATUS.md",
    "pubspec.yaml", "analysis_options.yaml", ".github/workflows/build_apk.yml",
    "preview/index.html", "preview/README.md",
    "lib/main.dart", "lib/app_config.dart", "lib/app_controller.dart",
    "lib/models/stock_candidate.dart", "lib/models/app_settings.dart",
    "lib/services/strategy_engine.dart", "lib/services/candidate_repository.dart",
    "lib/services/reminder_service.dart", "lib/screens/dashboard_screen.dart",
    "lib/screens/calculator_screen.dart", "lib/screens/settings_screen.dart",
    "test/strategy_engine_test.dart", "test/app_widget_test.dart",
    "lib/models/portfolio_position.dart", "lib/services/exit_advisory_engine.dart",
    "lib/services/portfolio_repository.dart", "lib/screens/portfolio_screen.dart",
    "backend/engine/exit_engine.py", "backend/engine/portfolio_tracker.py",
    "backend/tests/test_portfolio.py", "backend/tests/test_entry_points.py", "PORTFOLIO_GUIDE.md",
    "test/exit_advisory_engine_test.dart", "test/portfolio_controller_test.dart",
    "test/portfolio_widget_test.dart", "scripts/check_portfolio_parity.py",
    "test/portfolio_repository_test.dart",
    "scripts/check_portfolio_preview.cjs",
    "standalone_preview.html", "scripts/check_standalone_preview.cjs",
    "scripts/export_upload.sh", "scripts/recover_upload.py", "TERMINAL_EXPORT_GUIDE.md",
    "scripts/package_trading_app.sh",
    "test/capital_market_test.dart",
    "stocks_master.json", "stocks_master_sources.json", "stock_search.js", "SEARCH_GUIDE.md",
    "lib/models/stock_item.dart", "lib/services/stock_search_service.dart",
    "lib/widgets/stock_search_field.dart",
    "scripts/sync_stock_search.py", "scripts/check_stock_search.cjs",
    "scripts/refresh_stock_metadata.py",
    "test/stock_search_service_test.dart", "test/stock_search_widget_test.dart",
    "test/stock_search_integration_test.dart",
    "preview/standalone_preview.html", "run_preview.bat", "WINDOWS_UPDATE_GUIDE.md",
    "PRODUCTION_GUIDE.md", "lib/models/market_data.dart",
    "lib/services/market_data_api.dart", "lib/services/live_strategy_engine.dart",
    "lib/services/live_candidate_repository.dart", "lib/services/live_portfolio_repository.dart",
    "lib/services/stock_universe_service.dart",
    "test/market_data_api_test.dart", "test/live_strategy_engine_test.dart",
    "test/rs_alignment_test.dart",
    "test/live_repositories_test.dart", "test/stock_universe_service_test.dart",
    "test/production_controller_test.dart", "test/production_lifecycle_test.dart",
    "test/production_ui_test.dart", "test/live_http_smoke_test.dart",
    "test/live_risk_helpers_test.dart", "test/support/mock_preferences.dart",
    "lib/services/network_request.dart", "lib/services/live_batch_deadline.dart",
    "test/network_request_test.dart", "test/backend_transport_timeout_test.dart",
    "test/refresh_recovery_test.dart", "test/support/controllable_http_client.dart",
    "test/integration_scan_test.dart", "REFRESH_RECOVERY.md",
    "scripts/validate_live_scan_evidence.py", "scripts/tests/test_live_scan_evidence.py",
    "lib/models/backend_scan_status.dart", "test/backend_snapshot_repository_test.dart",
    "test/backend_scan_controller_test.dart", "backend/scan_jobs.py",
    "backend/tests/test_background_scan.py", "backend/requirements-dev.txt",
    "Dockerfile", ".dockerignore", "render.yaml", "CLOUD_API_GUIDE.md",
    "test/market_transport_regression_test.dart", "test/candidate_repository_test.dart",
    "MARKET_DEBUG_LOGGING.md", "GITHUB_MANUAL_UPDATE.md",
    "lib/services/market_scan_progress.dart", "test/market_scan_progress_test.dart",
    "test/core_market_pool_test.dart", "test/market_scan_timeout_test.dart",
    "assets/fonts/MartinPreviewSans.otf", "assets/fonts/OFL.txt",
    "android/settings.gradle", "android/build.gradle", "android/gradle.properties",
    "android/app/build.gradle", "android/gradlew", "android/gradlew.bat",
    "android/gradle/wrapper/gradle-wrapper.properties",
    "android/app/src/main/AndroidManifest.xml",
    "android/app/src/main/kotlin/com/martinluk/martin_luk_app/MainActivity.kt",
    "web/index.html", "web/flutter_bootstrap.js", "web/manifest.json",
    "web/phone_preview.html", "backend/api.py", "backend/scheduler.py",
    "backend/requirements.txt", "backend/README.md", "backend/engine/data_loader.py",
    "backend/engine/scanners.py", "backend/engine/risk_engine.py",
    "backend/engine/models.py", "backend/engine/market_calendar.py",
    "backend/tests/test_api.py", "scripts/prepare_android.py",
    "scripts/check_web.py", "scripts/check_preview.py", "scripts/check_preview_ui.cjs",
    "scripts/verify_deliverable.py", "scripts/package_deliverable.sh",
)


class ValidationError(Exception):
    """A missing, inconsistent or unsafe delivery file."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def is_excluded(relative: str) -> bool:
    path = PurePosixPath(relative)
    return any(part in EXCLUDED_DIRECTORIES for part in path.parts[:-1]) or any(
        fnmatch.fnmatchcase(path.name, pattern) for pattern in EXCLUDED_FILE_PATTERNS
    )


def source_files() -> dict[str, bytes]:
    """Walk only source files; reject symlinks to avoid copying external content."""
    files: dict[str, bytes] = {}
    for directory, directories, filenames in os.walk(PROJECT_ROOT, followlinks=False):
        # Ignore bulky caches before traversing them; inspect hidden .github normally.
        directories[:] = sorted(d for d in directories if d not in EXCLUDED_DIRECTORIES)
        for name in directories:
            require(not (Path(directory) / name).is_symlink(), f"不收錄符號連結目錄：{name}")
        for name in sorted(filenames):
            path = Path(directory) / name
            relative = path.relative_to(PROJECT_ROOT).as_posix()
            if relative == MANIFEST_NAME or is_excluded(relative):
                continue
            require(not path.is_symlink(), f"不收錄符號連結檔案：{relative}")
            require(path.is_file(), f"不是一般檔案：{relative}")
            files[relative] = path.read_bytes()
    return dict(sorted(files.items()))


class PreviewParser(HTMLParser):
    """Ensure the HTML preview has no required external resource references."""

    def __init__(self) -> None:
        super().__init__()
        self.external_resources: list[str] = []
        self.script_ids: set[str] = set()
        self.inline_style = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "script":
            self.script_ids.add(attributes.get("id") or "")
        if tag == "style":
            self.inline_style = True
        # Explicit API fetch calls are allowed; automatic HTML resources must be embedded.
        for attribute in ("src", "srcset", "poster", "data"):
            value = attributes.get(attribute)
            if value and not value.startswith(("data:", "#")):
                self.external_resources.append(f"{tag}.{attribute}={value}")
        if tag == "link" and attributes.get("href"):
            self.external_resources.append(f"link.href={attributes['href']}")


def validate_contents(files: dict[str, bytes]) -> None:
    missing = [name for name in REQUIRED_FILES if name not in files]
    require(not missing, "缺少必要交付檔案：" + ", ".join(missing))
    for name in REQUIRED_FILES:
        require(bool(files[name]), f"必要檔案為空：{name}")
    for name in files:
        require(not is_excluded(name), f"不應收錄快取／本機私密檔案：{name}")

    preview = files["preview/index.html"].decode("utf-8")
    parser = PreviewParser()
    parser.feed(preview)
    require(parser.inline_style, "離線預覽缺少內嵌樣式")
    require({"strategy-core", "portfolio-core", "preview-ui"} <= parser.script_ids, "離線預覽缺少策略、持股或 UI 腳本")
    require(not parser.external_resources, "離線預覽引用外部資源：" + ", ".join(parser.external_resources))
    css = "\n".join(re.findall(r"<style\b[^>]*>(.*?)</style>", preview, re.I | re.S))
    require(not re.search(r"@import\b|url\s*\(\s*['\"]?(?!data:|#)", css, re.I),
            "離線預覽樣式存在外部資源引用")
    require(bool(re.search(r"useMockData\s*:\s*true", preview)), "離線预覽預設未開啟 Mock")
    for marker in ("twAdr:3.5", "usAdr:5", "balance.mul(R(.005))", "force-mock"):
        require(marker in preview, f"離線預覽缺少預設值或風控功能：{marker}")

    standalone = files["standalone_preview.html"].decode("utf-8")
    offline_parser = PreviewParser()
    offline_parser.feed(standalone)
    require(offline_parser.inline_style and bool(offline_parser.script_ids), "單檔預覽缺少內嵌 CSS／JavaScript")
    require(not offline_parser.external_resources, "單檔預覽含外部檔案依賴")
    offline_css = "\n".join(re.findall(r"<style\b[^>]*>(.*?)</style>", standalone, re.I | re.S))
    require(not re.search(r"@import\b|url\s*\(\s*['\"]?(?!data:|#)", offline_css, re.I), "單檔預覽 CSS 有外部資源")
    require(not re.search(r"\b(?:fetch|XMLHttpRequest|WebSocket|EventSource)\s*\(|sendBeacon\s*\(|localhost|127\.0\.0\.1", standalone),
            "單檔預覽不得含任何 API 呼叫或本機伺服器網址")
    require(files["preview/standalone_preview.html"] == files["standalone_preview.html"],
            "Windows 指定預覽與原單檔預覽內容不一致")
    batch = files["run_preview.bat"].decode("utf-8")
    require('start "" "%~dp0preview\\standalone_preview.html"' in batch,
            "Windows 批次檔未指向指定相對預覽路徑")
    config = files["lib/app_config.dart"].decode("utf-8")
    require("bool.fromEnvironment('USE_MOCK_DATA', defaultValue: false)" in config,
            "App 正式連網預設尚未關閉 Mock")
    live_engine = files["lib/services/live_strategy_engine.dart"].decode("utf-8")
    for method in ("calculatePositionSize", "calculateExitTargets"):
        require(method in live_engine, f"缺少指定風控函式：{method}")

    # Search is an identity index, not a quote source. Ensure both offline
    # documents contain the same complete dictionary/algorithm as Flutter.
    metadata = json.loads(files["stocks_master.json"].decode("utf-8"))
    require(isinstance(metadata, list), "股票字典必須為 JSON 陣列")
    require(all(isinstance(row, dict) and row.get("market") in {"TW", "US"} for row in metadata),
            "股票字典存在非法資料列")
    for market in ("TW", "US"):
        require(sum(row["market"] == market for row in metadata) >= 100,
                f"{market} 離線股票字典不足 100 筆")
    require(len({(row["market"], row.get("symbol")) for row in metadata}) == len(metadata),
            "股票字典含重複代碼")
    coverage = json.loads(files["stocks_master_sources.json"].decode("utf-8")).get("coverage", {})
    for market in ("US", "TW"):
        require(coverage.get(market.lower()) == sum(row["market"] == market for row in metadata),
                f"{market} 股票字典來源記錄與筆數不一致")
    require(coverage.get("total") == len(metadata), "股票字典來源總筆數不一致")
    require(coverage.get("us", 0) >= 4000 and coverage.get("tw", 0) >= 1800,
            "擴充股票字典仍停留在舊核心／S&P 500 範圍")
    require(coverage.get("tpex") == sum(row["symbol"].endswith(".TWO") for row in metadata),
            "上櫃股票字典筆數不一致")
    identities = {(row["market"], row["symbol"]) for row in metadata}
    require(("TW", "6488.TWO") in identities and ("TW", "2330.TW") in identities,
            "缺少上市／上櫃身份")
    require(all(("TW", symbol) not in identities for symbol in ("9103.TW", "9105.TW", "9110.TW", "9136.TW")),
            "公司名錄中的四碼存託憑證不得混入普通股字典")
    snapshot_sources = json.loads(files["metadata_snapshots/SOURCES.json"].decode("utf-8"))
    for filename, expected in snapshot_sources["bundled_files"].items():
        require(hashlib.sha256(files["metadata_snapshots/" + filename]).hexdigest() == expected,
                f"原始身份快照 hash 不符：{filename}")
    search_engine = files["stock_search.js"].decode("utf-8").strip()
    for title, document in (("preview/index.html", preview), ("standalone_preview.html", standalone),
                            ("preview/standalone_preview.html", files["preview/standalone_preview.html"].decode("utf-8"))):
        blocks: dict[str, str] = {}
        for identifier in ("stocks-master", "stock-search-core"):
            match = re.search(rf'<script\b[^>]*\bid="{identifier}"[^>]*>([\s\S]*?)</script>', document)
            require(match is not None, f"{title} 缺少股票搜尋區塊 {identifier}")
            blocks[identifier] = match[1].strip()
        require(json.loads(blocks["stocks-master"]) == metadata, f"{title} 搜尋字典與主檔不一致")
        require(blocks["stock-search-core"] == search_engine, f"{title} 搜尋引擎與主檔不一致")

    workflow = files[".github/workflows/build_apk.yml"].decode("utf-8")
    for marker in (
        "workflow_dispatch:", "branches: [main, master, fix/refresh-live-gate-20261014]", "runs-on: ubuntu-latest", "actions/checkout@v4",
        "actions/setup-java@v4", "distribution: temurin", "java-version: '17'",
        "subosito/flutter-action@v2", "channel: stable",
        "flutter pub get", "flutter test", "flutter build apk --release",
        "USE_MOCK_DATA=false", "--android-skip-build-dependency-validation",
        "martin-luk-app-release", "actions/upload-artifact@v4",
        "**/build/app/outputs/flutter-apk/*.apk", "retention-days: 7",
        "martin-luk-live-scan-evidence", "**/test_logs/verification.log", "if: always()",
        "flutter test test/integration_scan_test.dart --dart-define=RUN_LIVE_SCAN_TEST=true --timeout=90s",
        "set -euo pipefail", "build/live-scan-evidence.json",
        "python3 scripts/validate_live_scan_evidence.py build/live-scan-evidence.json",
        "test/live_risk_helpers_test.dart", "-p 'test_*.py'",
        "test/expanded_symbol_test.dart", "test/rolling_scan_snapshot_test.dart",
        "python3 -m unittest discover -s backend/tests -v",
        "test/backend_snapshot_repository_test.dart test/backend_scan_controller_test.dart",
        "test/tw_issuer_csv_test.dart test/tw_official_fallback_test.dart",
        "test/trade_levels_test.dart test/manual_trade_levels_test.dart",
    ):
        require(marker in workflow, f"Actions 工作流缺少：{marker}")
    android_app = files["android/app/build.gradle"].decode("utf-8")
    require(bool(re.search(r"\bcompileSdk\s*=\s*36\b", android_app)),
            "Android compileSdk 必須符合 shared_preferences_android 的 API 36 要求")
    require("android-actions/setup-android" not in workflow and "sdkmanager" not in workflow,
            "Actions 不應再次依賴額外 Android SDK 安裝步驟")
    require("apply_market_scan" not in workflow and "market-scan-updated-source.zip" not in workflow,
            "Actions 不應再次依賴已停用的補丁或來源 ZIP")

    pubspec = files["pubspec.yaml"].decode("utf-8")
    require(bool(re.search(r"^\s*-\s*stocks_master\.json\s*$", pubspec, re.M)),
            "Flutter 未宣告離線股票字典 asset")
    for asset in re.findall(r"^\s*-\s*asset:\s*(\S+)\s*$", pubspec, re.M):
        require(asset in files, f"pubspec 引用的字型資產不存在：{asset}")
    require(files["assets/fonts/MartinPreviewSans.otf"][:4] == b"OTTO", "字型不是有效 OpenType CFF 資產")
    require(b"SIL OPEN FONT LICENSE" in files["assets/fonts/OFL.txt"], "字型授權檔不完整")
    for name, data in files.items():
        if name.endswith(".py"):
            ast.parse(data.decode("utf-8"), filename=name)
        elif name.endswith(".xml"):
            ET.fromstring(data)
    json.loads(files["web/manifest.json"])
    android = files["android/app/src/main/AndroidManifest.xml"].decode("utf-8")
    require("android.permission.INTERNET" in android, "Android 缺少網路權限")


def make_manifest(files: dict[str, bytes]) -> dict[str, Any]:
    # Stable content makes repeated packaging auditable; no recursive self-hash.
    return {
        "schema_version": 1,
        "hash_algorithm": "SHA256",
        "archive_layout": "project files at archive root",
        "manifest_excludes_itself": True,
        "file_count": len(files),
        "files": [
            {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in sorted(files.items())
        ],
    }


def verify_manifest(manifest: Any, files: dict[str, bytes]) -> None:
    require(isinstance(manifest, dict), "FILE_MANIFEST.json 必須是物件")
    require(manifest == make_manifest(files), "逐檔大小／SHA256／檔案清單與 FILE_MANIFEST.json 不一致")


def archive_files(archive: Path) -> tuple[dict[str, bytes], bytes]:
    require(archive.is_file(), f"找不到 ZIP：{archive}")
    with zipfile.ZipFile(archive, "r") as bundle:
        require(bundle.testzip() is None, "ZIP CRC 檢查失敗")
        files: dict[str, bytes] = {}
        seen: set[str] = set()
        for info in bundle.infolist():
            # Info-ZIP includes ./ directory entries; normalize this one prefix only.
            raw = info.filename
            while raw.startswith("./"):
                raw = raw[2:]
            if not raw and info.is_dir():
                continue
            parts = PurePosixPath(raw).parts
            require(bool(parts) and not raw.startswith("/") and ".." not in parts
                    and "\\" not in raw and not re.match(r"^[A-Za-z]:", raw),
                    f"ZIP 有不安全路徑：{info.filename}")
            require(not stat.S_ISLNK(info.external_attr >> 16), f"ZIP 含符號連結：{raw}")
            if info.is_dir():
                require(not any(p in EXCLUDED_DIRECTORIES for p in parts), f"ZIP 含快取目錄：{raw}")
                continue
            require(raw not in seen, f"ZIP 內有重複檔案：{raw}")
            seen.add(raw)
            files[raw] = bundle.read(info)
        require(MANIFEST_NAME in files, "ZIP 缺少 FILE_MANIFEST.json")
        manifest_bytes = files.pop(MANIFEST_NAME)
        return dict(sorted(files.items())), manifest_bytes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-manifest", action="store_true", help="驗證來源並更新逐檔 SHA256 清單")
    parser.add_argument("--archive", type=Path, help="驗證 ZIP CRC、完整清單及來源一致性")
    arguments = parser.parse_args()
    try:
        files = source_files()
        validate_contents(files)
        if arguments.write_manifest:
            content = json.dumps(make_manifest(files), ensure_ascii=False, indent=2) + "\n"
            (PROJECT_ROOT / MANIFEST_NAME).write_text(content, encoding="utf-8")
            print(f"PASS 逐檔 SHA256 清單：{MANIFEST_NAME} ({len(files)} files)")
        elif (PROJECT_ROOT / MANIFEST_NAME).exists():
            verify_manifest(json.loads((PROJECT_ROOT / MANIFEST_NAME).read_text(encoding="utf-8")), files)
        print(f"PASS 來源完整性：{len(files)} files；離線 HTML／Flutter／後端／Android／Actions")

        if arguments.archive:
            archived, manifest_bytes = archive_files(arguments.archive)
            validate_contents(archived)
            verify_manifest(json.loads(manifest_bytes), archived)
            require(archived == files, "ZIP 與目前來源檔案內容不一致；請重新打包")
            source_manifest = PROJECT_ROOT / MANIFEST_NAME
            require(source_manifest.exists() and source_manifest.read_bytes() == manifest_bytes,
                    "ZIP 內的逐檔清單與來源清單不一致")
            print(f"PASS ZIP：CRC／{len(archived) + 1} files／逐檔 SHA256／來源一致性")
        return 0
    except (ValidationError, OSError, UnicodeError, SyntaxError, ValueError,
            ET.ParseError, zipfile.BadZipFile, RuntimeError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
