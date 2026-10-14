#!/usr/bin/env python3
"""Refresh the offline stock index from existing public universe providers.

This is a maintenance command, never called while the user types. It uses the
same Wikipedia S&P 500 / TWSE ISIN ordinary-share filtering and local cache as
the backend. Curated translations, abbreviations and aliases are preserved by
canonical symbol. Unknown names remain empty instead of receiving invented
translations. Regenerate embedded preview assets after this command succeeds.

Examples::

    python scripts/refresh_stock_metadata.py --market all
    python scripts/refresh_stock_metadata.py --market tw --offline

Install ``backend/requirements.txt`` before a refresh. ``--help`` needs only
the Python standard library and does not make a network request.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.sync_stock_search import validate_records

REQUIRED_STRINGS = (
    "market", "symbol", "code", "name_zh", "name_full_zh", "name_en", "abbr_en"
)
# Identified major US additions are retained separately from S&P membership.
MAJOR_US_ADDITIONS = frozenset({"TSM", "SHOP", "NET", "RBLX", "ZM", "OKTA"})
# Preserve old familiar tickers as aliases if the public list uses a new ticker.
TICKER_RENAMES = {"FISV": "FI", "MRSH": "MMC"}


def read_records(path: Path) -> list[dict[str, Any]]:
    """Reject malformed or duplicate metadata before refreshing either market."""
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not rows:
        raise ValueError("股票字典必須是非空 JSON array。")
    seen: set[tuple[str, str]] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("股票紀錄必須是 JSON object。")
        if any(not isinstance(row.get(key), str) for key in REQUIRED_STRINGS):
            raise ValueError("股票文字欄位缺失或不是字串。")
        market, symbol = row["market"], row["symbol"]
        valid_symbol = (
            market == "TW" and re.fullmatch(r"\d{4}\.TW", symbol)
        ) or (
            market == "US" and re.fullmatch(r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)?", symbol)
        )
        if not valid_symbol:
            raise ValueError(f"無效市場或標準代碼：{market}/{symbol}")
        for key in ("aliases", "short_codes"):
            if not isinstance(row.get(key), list) or any(
                not isinstance(value, str) for value in row[key]
            ):
                raise ValueError(f"{symbol}: {key} 必須是字串 array。")
        key = (market, symbol)
        if key in seen:
            raise ValueError(f"股票字典包含重複紀錄：{market}/{symbol}")
        seen.add(key)
    return rows


def merge_market(
    old: list[dict[str, Any]], stocks: Iterable[Any], market: str
) -> tuple[list[dict[str, Any]], list[str]]:
    """Merge only real provider records; keep translations and known aliases."""
    originals = {row["symbol"]: row for row in old if row["market"] == market}
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for stock in stocks:
        symbol = stock.symbol.replace(".", "-") if market == "US" else stock.symbol
        old_symbol = TICKER_RENAMES.get(symbol, symbol)
        prior = originals.get(symbol) or originals.get(old_symbol)
        if prior is not None:
            # Copy nested arrays too, leaving the input snapshot unchanged.
            row = dict(prior)
            row["aliases"] = list(prior["aliases"])
            row["short_codes"] = list(prior["short_codes"])
        else:
            row = {
                "market": market, "symbol": symbol,
                "code": symbol.removesuffix(".TW"),
                "name_zh": stock.name if market == "TW" else stock.name,
                "name_full_zh": "",
                "name_en": stock.name if market == "US" else "",
                "abbr_en": "", "aliases": [], "short_codes": [],
            }
        row.update(market=market, symbol=symbol, code=symbol.removesuffix(".TW"))
        if market == "TW":
            if row["name_zh"] and row["name_zh"] != stock.name:
                row["aliases"].append(row["name_zh"])
            row["name_zh"] = stock.name
        else:
            previous_english = row["name_en"]
            if previous_english and previous_english != stock.name:
                row["aliases"].append(previous_english)
            row["name_en"] = stock.name
            # English fallback labels follow the current public Security name.
            if not re.search(r"[\u3400-\u9fff]", row["name_zh"]):
                row["name_zh"] = stock.name
            if old_symbol != symbol:
                row["aliases"].append(old_symbol)
        row["aliases"] = list(dict.fromkeys(value for value in row["aliases"] if value))
        row["short_codes"] = list(dict.fromkeys(row["short_codes"]))
        if symbol in seen:
            raise ValueError(f"資料來源包含重複標準代碼：{symbol}")
        seen.add(symbol)
        result.append(row)
    if not result:
        raise ValueError(f"{market} 公開名單為空，保留原股票字典。")
    additions: list[str] = []
    if market == "US":
        for symbol in sorted(MAJOR_US_ADDITIONS - seen):
            if symbol in originals:
                result.append(dict(originals[symbol]))
                additions.append(symbol)
    return result, additions


def atomic_json(path: Path, payload: Any) -> None:
    """Atomic replacement prevents an interrupted job leaving partial JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as handle:
            temporary = Path(handle.name)
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--market", choices=("us", "tw", "all"), default="all")
    parser.add_argument("--offline", action="store_true", help="只讀現有公開股票池快取，不連線。")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "backend/cache/metadata")
    parser.add_argument("--output", type=Path, default=ROOT / "stocks_master.json")
    parser.add_argument("--sources-output", type=Path, help="預設為字典旁的 stocks_master_sources.json。")
    args = parser.parse_args(argv)
    try:
        # Delayed import means --help does not need backend dependencies.
        from backend.engine.data_loader import UniverseProvider
        from backend.engine.models import Market

        old = read_records(args.output)
        provider = UniverseProvider(args.cache_dir)
        selected = ("US", "TW") if args.market == "all" else (args.market.upper(),)
        rows = [row for row in old if row["market"] not in selected]
        sources_path = args.sources_output or args.output.with_name("stocks_master_sources.json")
        provenance = (
            json.loads(sources_path.read_text(encoding="utf-8"))
            if sources_path.exists() else {"schema_version": 1, "sources": {}}
        )
        if not isinstance(provenance, dict) or not isinstance(provenance.get("sources", {}), dict):
            raise ValueError("來源紀錄格式無效，保留原股票字典。")
        source_updates: dict[str, Any] = {}
        memberships: dict[str, int] = {}
        extra_symbols = provenance.get("additional_us_symbols", [])
        for label in selected:
            enum = Market(label.lower())
            stocks = provider.load(enum, force_refresh=not args.offline, offline=args.offline)
            merged, additions = merge_market(old, stocks, label)
            rows.extend(merged)
            memberships[label] = len(stocks)
            source_updates[label.lower()] = {
                "url": UniverseProvider.US_URL if label == "US" else UniverseProvider.TW_URL,
                "provider_source": provider.sources.get(enum, ""),
                "description": "Public universe snapshot; offline/stale cache is identified in provider_source.",
            }
            if label == "US":
                extra_symbols = additions
        rows.sort(key=lambda row: (row["market"], row["symbol"]))
        # Validate against the exact offline/Dart canonical schema before
        # replacing files. A changed upstream symbol must not break the App.
        validate_records(rows)
        counts = Counter(row["market"] for row in rows)
        coverage = dict(provenance.get("coverage", {}))
        coverage.update(total=len(rows), us=counts["US"], tw=counts["TW"])
        if "US" in selected:
            coverage.update(us_sp500_snapshot=memberships["US"], us_additional_major=len(extra_symbols))
        if "TW" in selected:
            coverage.update(tw_public_snapshot=memberships["TW"])
        provenance.setdefault("sources", {}).update(source_updates)
        provenance.update(
            snapshot_date=datetime.now(timezone.utc).date().isoformat(),
            refreshed_at=datetime.now(timezone.utc).isoformat(),
            coverage=coverage, additional_us_symbols=extra_symbols,
            warnings=provider.warnings,
        )
        # Both markets must finish successfully before replacing the dictionary.
        atomic_json(args.output, rows)
        atomic_json(sources_path, provenance)
        print(f"已更新 {args.output}: US {counts['US']} / TW {counts['TW']} / 合計 {len(rows)}")
        for warning in provider.warnings:
            print(f"來源提醒：{warning}", file=sys.stderr)
        print("請重新嵌入 HTML 搜尋資產、重建 Flutter App，再重新打包交付成品。")
        return 0
    except (ImportError, OSError, ValueError, TypeError, RuntimeError) as exc:
        print(f"股票元資料更新失敗：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
