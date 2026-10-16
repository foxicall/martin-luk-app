#!/usr/bin/env python3
"""Refresh the offline stock index from existing public universe providers.

This is a maintenance command, never called while the user types. It uses the
same NasdaqTrader NYSE/Nasdaq/NYSE American conservative ordinary-share
classification and TWSE/TPEx ISIN CFI filtering as the backend. Curated
translations, abbreviations and aliases are preserved by
canonical symbol. Unknown names remain empty instead of receiving invented
translations. Regenerate embedded preview assets after this command succeeds.

Examples::

    python scripts/refresh_stock_metadata.py --market all
    python scripts/refresh_stock_metadata.py --market all --allow-partial
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
            market == "TW" and re.fullmatch(r"\d{4}\.TW(?:O)?", symbol)
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
                "code": symbol.split(".", 1)[0] if market == "TW" else symbol,
                "name_zh": stock.name if market == "TW" else stock.name,
                "name_full_zh": "",
                "name_en": stock.name if market == "US" else "",
                "abbr_en": "", "aliases": [], "short_codes": [],
            }
        row.update(market=market, symbol=symbol,
                   code=symbol.split(".", 1)[0] if market == "TW" else symbol)
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
    # Never retain historical manual additions outside the current source.
    # In particular, TSM is a US ADR and is outside the ordinary-share scope.
    return result, []


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
    parser.add_argument("--allow-partial", action="store_true",
                        help="明確允許部分來源／保守名稱分類／過期快取；來源與警告仍會完整記錄。")
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
            if sources_path.exists() else {"schema_version": 2, "sources": {}}
        )
        if not isinstance(provenance, dict) or not isinstance(provenance.get("sources", {}), dict):
            raise ValueError("來源紀錄格式無效，保留原股票字典。")
        source_updates: dict[str, Any] = {}
        for label in selected:
            enum = Market(label.lower())
            stocks = provider.load(enum, force_refresh=not args.offline, offline=args.offline)
            complete = provider.coverage_complete.get(enum, False)
            if not complete and not args.allow_partial:
                raise ValueError(
                    f"{label} 名錄來源／分類覆蓋不完整，未覆蓋原字典。"
                    "請先檢查來源警告；如接受保守排除／部分來源，可明確加 --allow-partial。"
                    + "；".join(provider.warnings)
                )
            merged, _ = merge_market(old, stocks, label)
            rows.extend(merged)
            captured = provider.captured_at.get(enum)
            if captured is None or captured.tzinfo is None:
                raise ValueError(f"{label} 股票池缺少來源擷取時間，不能以執行日期冒充。")
            source_updates[label.lower()] = {
                "provider_source": provider.sources.get(enum, ""),
                "captured_at": captured.isoformat(),
                "scope": provider.statistics.get(enum, {}).get("scope"),
                "coverage_complete": complete,
                "statistics": provider.statistics.get(enum, {}),
                "warnings": list(provider.coverage_warnings.get(enum, [])),
                "description": "Public metadata snapshot; retained captured_at belongs to upstream fetch, not this assembly run.",
            }
        rows.sort(key=lambda row: (row["market"], row["symbol"]))
        # Validate against the exact offline/Dart canonical schema before
        # replacing files. A changed upstream symbol must not break the App.
        validate_records(rows)
        counts = Counter(row["market"] for row in rows)
        coverage = {
            "total": len(rows), "us": counts["US"], "tw": counts["TW"],
            "us_scope": "NYSE/Nasdaq/NYSE American ordinary shares; conservative name classification",
            "tw_scope": "TWSE listed + TPEx OTC ordinary shares; ISIN CFI ES",
        }
        provenance.setdefault("sources", {}).update(source_updates)
        for legacy in ("additional_us_symbols", "refreshed_at"):
            provenance.pop(legacy, None)
        # A metadata assembly timestamp is not a market/source refresh timestamp.
        # Only report a shared snapshot_date when both market origins are known.
        source_dates: list[str] = []
        for market_key in ("us", "tw"):
            stamp = provenance["sources"].get(market_key, {}).get("captured_at")
            if isinstance(stamp, str):
                captured_at = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                if captured_at.tzinfo is None:
                    raise ValueError(f"{market_key} captured_at 必須含時區。")
                source_dates.append(captured_at.astimezone(timezone.utc).date().isoformat())
        provenance.update(
            schema_version=2,
            assembled_at=datetime.now(timezone.utc).isoformat(),
            snapshot_date=min(source_dates) if len(source_dates) == 2 else None,
            coverage=coverage,
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
