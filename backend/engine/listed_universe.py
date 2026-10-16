"""公開掛牌名錄的純解析器（不發出網路請求）。

NasdaqTrader 沒有可靠的逐檔 CFI／證券種類欄位，因此美股採保守的
名稱分類，並回報未知分類；它不能當成經交易所核證的完整普通股清單。
台灣 ISIN 名錄則使用 CFI 的 ES 前綴確認普通股。
"""
from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from html.parser import HTMLParser
from io import StringIO
from typing import Any

from .models import Market, Stock

US_SCOPE = "us_nyse_nasdaq_nyse_american_common"
TW_SCOPE = "tw_twse_tpex_common"
SCOPES = {Market.US: US_SCOPE, Market.TW: TW_SCOPE}
US_CLASSIFICATION_WARNING = (
    "美股 NasdaqTrader 名錄無逐檔 CFI，採名稱正向辨識普通股；"
    "排除 ETF、ADR、特別股、權證、權利、單位及無法確認類型的證券。"
    "此為保守名稱分類，並非交易所核證的 100% 完整普通股名單。"
)


@dataclass(frozen=True)
class ParsedUniverse:
    stocks: list[Stock]
    statistics: dict[str, Any]


_EXCLUDED_US = re.compile(
    r"\b(?:depositary|depository|adr|ads|preferred|preference|pfd|warrants?|rights?|units?)\b"
    r"|\bexchange[- ]traded\b|\b(?:etf|etn|funds?)\b|\bnotes?\b|\bbonds?\b"
    r"|\bshares?\s+of\s+beneficial\s+interest\b"
    # Closed-end investment trusts are outside the requested corporate share
    # scope. A corporate REIT called 'Real Estate Investment Trust' remains
    # eligible if its security explicitly says Common Stock / Ordinary Shares.
    r"|(?<!estate )\binvestment\s+trust\b",
    re.IGNORECASE,
)
_COMMON_US = re.compile(
    r"\bcommon\s+(?:stock|shares?)\b|\bordinary\s+(?:stock|shares?)\b"
    r"|\bcapital\s+stock\b",
    re.IGNORECASE,
)


def parse_nasdaq_directory(text: str, *, source: str) -> ParsedUniverse:
    """Parse nasdaqlisted.txt or otherlisted.txt; skip footer and duplicates.

    source='nasdaq': implicit Nasdaq market. source='other': keep only Exchange
    N (NYSE) and A (NYSE American); P (Arca), Z/V (Cboe) are outside scope.
    Yahoo's class-share spelling is normalized, e.g. BRK.B -> BRK-B.
    """
    if source not in {"nasdaq", "other"}:
        raise ValueError("source must be 'nasdaq' or 'other'")
    reader = csv.DictReader(StringIO(text.lstrip("\ufeff")), delimiter="|")
    fields = set(reader.fieldnames or [])
    symbol_field = "Symbol" if source == "nasdaq" else "ACT Symbol"
    required = {symbol_field, "Security Name", "ETF", "Test Issue"}
    if source == "other":
        required.add("Exchange")
    if not required.issubset(fields):
        raise ValueError(f"NasdaqTrader {source} 名錄缺少必要欄位：{sorted(required - fields)}")
    stats: dict[str, Any] = {
        "source": source, "rows": 0, "included": 0, "excluded_exchange": 0,
        "excluded_test_or_etf": 0, "excluded_security_type": 0,
        "unknown_security_type": 0, "invalid_symbol": 0, "duplicates": 0,
        "classification_method": "conservative_security_name_patterns",
        "classification_verified": False,
    }
    stocks: list[Stock] = []
    seen: set[str] = set()
    footer_seen = False
    for row in reader:
        raw = (row.get(symbol_field) or "").strip()
        if raw.lower().startswith("file creation time:"):
            if footer_seen:
                raise ValueError(f"NasdaqTrader {source} 名錄包含重複結尾標記。")
            footer_seen = True
            stats["file_creation_time"] = raw
            # Nasdaq's footer may omit a trailing column, unlike stock rows.
            continue
        if not any(value for value in row.values()):
            continue
        if footer_seen:
            raise ValueError(f"NasdaqTrader {source} 結尾標記後仍包含證券資料。")
        if None in row or any(value is None for value in row.values()) or not raw:
            raise ValueError(f"NasdaqTrader {source} 名錄資料列欄位數不完整。")
        stats["rows"] += 1
        if source == "other" and (row.get("Exchange") or "").strip() not in {"N", "A"}:
            stats["excluded_exchange"] += 1
            continue
        if (row.get("ETF") or "").strip() != "N" or (row.get("Test Issue") or "").strip() != "N":
            stats["excluded_test_or_etf"] += 1
            continue
        name = " ".join((row.get("Security Name") or "").split())
        if _EXCLUDED_US.search(name):
            stats["excluded_security_type"] += 1
            continue
        if not _COMMON_US.search(name):
            stats["unknown_security_type"] += 1
            continue
        symbol = raw.replace(".", "-").upper()
        if not re.fullmatch(r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)?", symbol):
            stats["invalid_symbol"] += 1
            continue
        if symbol in seen:
            stats["duplicates"] += 1
            continue
        seen.add(symbol)
        stocks.append(Stock(symbol, name, "", Market.US, False))
    if not footer_seen:
        raise ValueError(f"NasdaqTrader {source} 名錄缺少 File Creation Time 結尾；可能已截斷。")
    if not stocks:
        raise ValueError(f"NasdaqTrader {source} 沒有可確認的普通股；請檢查來源格式。")
    stats["included"] = len(stocks)
    return ParsedUniverse(stocks, stats)


class _TableRows(HTMLParser):
    """Extract ISIN table cells without lxml/BeautifulSoup dependencies."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[list[str]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "tr":
            self._row = []
        elif tag in {"td", "th"} and self._row is not None:
            self._cell = []
        elif tag == "br" and self._cell is not None:
            self._cell.append(" ")

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag in {"td", "th"} and self._row is not None and self._cell is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            self.rows.append(self._row)
            self._row = None
            self._cell = None


def parse_tw_isin(text: str, *, listing: str) -> ParsedUniverse:
    """Parse TWSE ISIN strMode=2 (listed) or strMode=4 (OTC) ordinary shares."""
    if listing not in {"listed", "otc"}:
        raise ValueError("listing must be 'listed' or 'otc'")
    expected = "上市" if listing == "listed" else "上櫃"
    allowed_boards = {"上市", "上市臺灣創新板"} if listing == "listed" else {"上櫃"}
    suffix = ".TW" if listing == "listed" else ".TWO"
    parser = _TableRows()
    parser.feed(text)
    parser.close()
    stocks: list[Stock] = []
    seen: set[str] = set()
    stats: dict[str, Any] = {
        "source": "TWSE" if listing == "listed" else "TPEx", "rows": 0,
        "included": 0, "excluded_security_type": 0, "duplicates": 0,
        "classification_method": "ISIN_CFI_ES_and_four_digit_code",
        "classification_verified": True,
    }
    for row in parser.rows:
        if len(row) < 6:
            continue
        # ISIN layout: code/name, ISIN, listing date, market, sector, CFI, note.
        match = re.fullmatch(r"(\d{4})\s+(.+)", row[0])
        if match is None:
            continue
        stats["rows"] += 1
        if row[3] not in allowed_boards or not row[5].upper().startswith("ES"):
            stats["excluded_security_type"] += 1
            continue
        symbol = f"{match.group(1)}{suffix}"
        if symbol in seen:
            stats["duplicates"] += 1
            continue
        seen.add(symbol)
        stocks.append(Stock(symbol, match.group(2), row[4], Market.TW, False))
    if not stocks:
        raise ValueError(f"{expected} ISIN 名錄沒有可確認普通股；請檢查來源格式。")
    stats["included"] = len(stocks)
    return ParsedUniverse(stocks, stats)
