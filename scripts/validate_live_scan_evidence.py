#!/usr/bin/env python3
"""Validate real-market health evidence before building an APK.

The live Dart test verifies the individual signal and sizing calculations.
This separate, dependency-free gate checks that CI received a successful,
complete, current-version report from that test. A market with no qualifying
entry is healthy and is allowed to build; failed or missing live data is not.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from typing import Any


REQUIRED_SYMBOLS = ("NVDA", "AAPL", "TSLA", "2330.TW", "2603.TW")
REQUIRED_BENCHMARKS = {"^GSPC": ("us", "USD"), "^TWII": ("tw", "TWD")}
_NON_REAL_SOURCE = re.compile(r"mock|fictitious|demo|示範|假", re.IGNORECASE)


class ValidationError(ValueError):
    """The evidence cannot authorize an APK build."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def _number(value: Any, field: str, *, minimum: float | None = None,
            positive: bool = False) -> float:
    # bool is a subclass of int in Python, but is never valid numeric evidence.
    _require(isinstance(value, (int, float)) and not isinstance(value, bool),
             f"{field} 必須是數字。")
    try:
        number = float(value)
    except (OverflowError, ValueError) as error:
        raise ValidationError(f"{field} 必須是有限數字。") from error
    _require(math.isfinite(number), f"{field} 必須是有限數字。")
    if minimum is not None:
        _require(number >= minimum, f"{field} 不可小於 {minimum}。")
    if positive:
        _require(number > 0, f"{field} 必須大於零。")
    return number


def validate_evidence(report: Any) -> int:
    """Return the qualified candidate count, including zero, or raise.

    This function performs no network calls and never substitutes fixture data.
    It accepts only evidence emitted by the schema-v2 real-market health test.
    """
    _require(isinstance(report, dict), "實測報告必須是 JSON object。")
    _require(type(report.get("schema_version")) is int and
             report["schema_version"] == 2,
             "需要 schema_version=2，請同步更新真實行情測試。")
    _require(report.get("verification_mode") == "real_market_health",
             "verification_mode 必須是 real_market_health。")
    _require(report.get("use_mock_data") is False,
             "正式版門禁要求 use_mock_data=false。")
    _require(report.get("status") == "passed", "真實行情測試未通過。")
    _require(not report.get("failure"), "實測報告仍包含 failure。")
    for field in ("benchmarks_verified", "required_symbols_verified",
                  "indicators_verified"):
        _require(report.get(field) is True, f"{field} 尚未驗證成功。")

    required = report.get("required_symbols")
    _require(isinstance(required, list) and
             all(isinstance(symbol, str) for symbol in required) and
             len(required) == len(REQUIRED_SYMBOLS) and
             set(required) == set(REQUIRED_SYMBOLS),
             "required_symbols 必須完整包含 NVDA/AAPL/TSLA/2330.TW/2603.TW。")
    deadline = _number(report.get("whole_run_deadline_seconds"),
                       "whole_run_deadline_seconds", positive=True)
    _require(deadline == 15, "整個實測流程期限必須是 15 秒。")
    elapsed = _number(report.get("elapsed_ms"), "elapsed_ms", minimum=0)
    _require(elapsed <= 15000, "真實行情驗證超過 15 秒期限。")

    errors = report.get("errors")
    _require(isinstance(errors, dict) and
             all(isinstance(key, str) and isinstance(value, str)
                 for key, value in errors.items()),
             "errors 必須是 symbol 到錯誤文字的 map。")
    for symbol in (*REQUIRED_SYMBOLS, *REQUIRED_BENCHMARKS):
        _require(symbol not in errors, f"必需行情 {symbol} 仍有錯誤。")

    observations = report.get("observations")
    _require(isinstance(observations, list), "observations 必須是 list。")
    verified: dict[tuple[str, str], dict[str, Any]] = {}
    for index, observation in enumerate(observations):
        label = f"observations[{index}]"
        _require(isinstance(observation, dict), f"{label} 必須是 object。")
        kind, symbol = observation.get("kind"), observation.get("symbol")
        _require(kind in ("benchmark", "stock"), f"{label}.kind 無效。")
        _require(isinstance(symbol, str) and bool(symbol),
                 f"{label}.symbol 缺漏。")
        label = f"{kind}/{symbol}"
        key = (kind, symbol)
        _require(key not in verified, f"{label} 的實測紀錄重複。")

        market = observation.get("market")
        _require(market in ("us", "tw"), f"{label}.market 無效。")
        _require(observation.get("currency") ==
                 ("USD" if market == "us" else "TWD"),
                 f"{label} 市場與幣別不一致。")
        _require(observation.get("is_cached") is False,
                 f"{label} 不可使用快取冒充實測。")
        _require(observation.get("is_stale") is False,
                 f"{label} 不可使用過期資料。")
        source = observation.get("source")
        _require(isinstance(source, str) and "yahoo" in source.lower() and
                 _NON_REAL_SOURCE.search(source) is None,
                 f"{label} 必須是實際 Yahoo 行情來源。")
        _number(observation.get("provider_price"),
                f"{label}.provider_price", positive=True)
        count = observation.get("completed_daily_bars")
        _require(type(count) is int and count >= 61,
                 f"{label} 需要至少 61 筆完整日 K。")
        _number(observation.get("adr_20_percent"),
                f"{label}.adr_20_percent", minimum=0)
        for field in ("ema_9", "ema_21", "ema_50"):
            _number(observation.get(field), f"{label}.{field}", positive=True)
        # An optional probe can publish valid daily evidence before its RS
        # evaluation fails. Its recorded error must not invalidate the required
        # five successful probes. Never allow this exception for required data.
        optional_rs_failure = (kind == "stock" and
                               symbol not in REQUIRED_SYMBOLS and
                               symbol in errors and
                               "rs_raw_excess_percent" not in observation)
        if kind == "stock" and not optional_rs_failure:
            _number(observation.get("rs_raw_excess_percent"),
                    f"{label}.rs_raw_excess_percent")
        verified[key] = observation

    for symbol in REQUIRED_SYMBOLS:
        observation = verified.get(("stock", symbol))
        _require(observation is not None, f"缺少必需股票 {symbol} 的實測資料。")
        expected_market = "tw" if symbol.endswith(".TW") else "us"
        _require(observation["market"] == expected_market,
                 f"必需股票 {symbol} 的市場錯誤。")
    for symbol, (market, currency) in REQUIRED_BENCHMARKS.items():
        observation = verified.get(("benchmark", symbol))
        _require(observation is not None, f"缺少必需大盤 {symbol} 的實測資料。")
        _require(observation["market"] == market and
                 observation["currency"] == currency,
                 f"必需大盤 {symbol} 的市場或幣別錯誤。")

    candidates = report.get("candidates")
    _require(isinstance(candidates, list), "candidates 必須是 list，可為空。")
    candidate_count = report.get("candidate_count")
    _require(type(candidate_count) is int and candidate_count == len(candidates),
             "candidate_count 與實際 candidates 數量不一致。")
    # Individual entry/stop/sizing assertions belong to the real Dart scan.
    _require(all(isinstance(candidate, dict) for candidate in candidates),
             "每筆推薦必須是 object。")
    expected_status = ("qualified_entries" if candidate_count
                       else "no_qualified_entry")
    _require(report.get("recommendation_status") == expected_status,
             "recommendation_status 與候選數量不一致。")
    return candidate_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path,
                        help="build/live-scan-evidence.json")
    args = parser.parse_args(argv)
    try:
        with args.evidence.open(encoding="utf-8") as stream:
            report = json.load(stream)
        count = validate_evidence(report)
    except (OSError, UnicodeError, json.JSONDecodeError, ValidationError) as error:
        print(f"[GATE FAILED] {error}", file=sys.stderr)
        return 1
    print(f"[GATE PASSED] 真實行情與指標驗證通過；合格推薦 {count}（可為 0）。")
    if count == 0:
        print("[NO QUALIFIED ENTRY] 目前沒有合格買點，建置仍可繼續；選股門檻維持不變。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
