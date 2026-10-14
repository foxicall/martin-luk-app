#!/usr/bin/env python3
"""Embed the shared search dictionary/engine into all self-contained previews.

Run after editing stocks_master.json or stock_search.js. --check checks committed
HTML without rewriting it, so CI catches stale/offline dictionary copies.
Uses the Python standard library and never accesses the network.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
PREVIEWS = (
    ROOT / "preview/index.html",
    ROOT / "standalone_preview.html",
    ROOT / "preview/standalone_preview.html",
)


def validate_records(records: object) -> list[dict[str, object]]:
    """Reject duplicate, incomplete or noncanonical records before embedding."""
    if not isinstance(records, list):
        raise ValueError("stocks_master.json must contain an array")
    keys: set[tuple[str, str]] = set()
    for row, item in enumerate(records):
        if not isinstance(item, dict) or item.get("market") not in {"TW", "US"}:
            raise ValueError(f"Invalid market/record at row {row}")
        for field in ("symbol", "code", "name_zh", "name_full_zh", "name_en", "abbr_en"):
            if not isinstance(item.get(field), str):
                raise ValueError(f"Missing string {field} at row {row}")
        for field in ("aliases", "short_codes"):
            values = item.get(field)
            if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                raise ValueError(f"Invalid {field} at row {row}")
        symbol, code = item["symbol"], item["code"]
        if item["market"] == "TW":
            valid = bool(re.fullmatch(r"\d{4}\.TW", symbol)) and code == symbol[:-3]
        else:
            valid = bool(re.fullmatch(r"[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?", symbol)) and code == symbol
        if not valid:
            raise ValueError(f"Invalid canonical symbol/code at row {row}: {symbol}")
        key = (item["market"], symbol)
        if key in keys:
            raise ValueError(f"Duplicate record: {key}")
        keys.add(key)
    counts = Counter(item["market"] for item in records)
    if counts["US"] < 100 or counts["TW"] < 100:
        raise ValueError(f"Offline dictionary requires at least 100 records per market: {dict(counts)}")
    return records


def embedded_block(source: str, identifier: str) -> re.Match[str]:
    pattern = rf'(<script\b[^>]*\bid="{re.escape(identifier)}"[^>]*>)([\s\S]*?)(</script>)'
    matches = list(re.finditer(pattern, source))
    if len(matches) != 1:
        raise ValueError(f"Expected one inline block {identifier}; found {len(matches)}")
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate embedded copies without writing")
    args = parser.parse_args()
    try:
        records = validate_records(json.loads((ROOT / "stocks_master.json").read_text(encoding="utf-8")))
        # Escape HTML delimiters even if a future alias contains markup. Parsed
        # values are unchanged; </script> can never terminate the JSON block.
        dictionary = json.dumps(records, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        engine = (ROOT / "stock_search.js").read_text(encoding="utf-8").rstrip()
        if "</script" in engine.lower():
            raise ValueError("Search engine contains an unsafe inline script delimiter")
        for path in PREVIEWS:
            source = path.read_text(encoding="utf-8")
            for identifier, content in (("stocks-master", dictionary), ("stock-search-core", engine)):
                match = embedded_block(source, identifier)
                if args.check:
                    if match[2].strip() != content:
                        raise ValueError(f"Stale {identifier} in {path.relative_to(ROOT)}; run scripts/sync_stock_search.py")
                else:
                    source = source[:match.start(2)] + "\n" + content + "\n" + source[match.end(2):]
            if not args.check:
                path.write_text(source, encoding="utf-8")
        counts = Counter(item["market"] for item in records)
        print(f"Stock metadata {'verified' if args.check else 'embedded'}: US={counts['US']}, TW={counts['TW']}; all {len(PREVIEWS)} entries share the exact engine and dictionary.")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        parser.exit(1, f"Search metadata verification failed: {error}\n")


if __name__ == "__main__":
    main()
