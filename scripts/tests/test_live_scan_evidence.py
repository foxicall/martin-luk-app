"""Offline tests for the evidence contract, never fixtures for the live scan."""

from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VALIDATOR_PATH = Path(__file__).resolve().parents[1] / "validate_live_scan_evidence.py"
SPEC = importlib.util.spec_from_file_location("live_scan_evidence", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


def healthy_report() -> dict:
    """A schema fixture for validator tests, not evidence of a live API call."""
    observations = []
    for kind, symbol in (
        ("benchmark", "^GSPC"), ("benchmark", "^TWII"),
        *(("stock", symbol) for symbol in validator.REQUIRED_SYMBOLS),
    ):
        market = "tw" if symbol.endswith(".TW") or symbol == "^TWII" else "us"
        observation = {
            "kind": kind, "symbol": symbol, "market": market,
            "currency": "TWD" if market == "tw" else "USD",
            "provider_price": 100.0, "completed_daily_bars": 100,
            "adr_20_percent": 2.0, "ema_9": 99.0,
            "ema_21": 98.0, "ema_50": 97.0,
            "source": "Yahoo Finance HTTPS chart",
            "is_cached": False, "is_stale": False,
        }
        if kind == "stock":
            observation["rs_raw_excess_percent"] = -1.25
        observations.append(observation)
    return {
        "schema_version": 2, "verification_mode": "real_market_health",
        "use_mock_data": False, "status": "passed",
        "benchmarks_verified": True, "required_symbols_verified": True,
        "indicators_verified": True,
        "required_symbols": list(validator.REQUIRED_SYMBOLS),
        "whole_run_deadline_seconds": 15, "elapsed_ms": 14999,
        "observations": observations, "errors": {},
        "candidates": [], "candidate_count": 0,
        "recommendation_status": "no_qualified_entry",
    }


class EvidenceTests(unittest.TestCase):
    def test_healthy_data_with_no_entry_is_allowed(self) -> None:
        # ADR may fall below entry thresholds and RS may be negative. Those are
        # legitimate market observations, not a data-health failure.
        self.assertEqual(validator.validate_evidence(healthy_report()), 0)

    def test_actual_candidate_count_is_returned(self) -> None:
        report = healthy_report()
        # Candidate internals are checked by Dart, not redefined by Python.
        report.update(candidates=[{"symbol": "NVDA"}], candidate_count=1,
                      recommendation_status="qualified_entries")
        self.assertEqual(validator.validate_evidence(report), 1)

    def test_optional_symbol_failure_does_not_hide_required_success(self) -> None:
        report = healthy_report()
        report["errors"] = {"OPTIONAL": "HTTP 429"}
        self.assertEqual(validator.validate_evidence(report), 0)

    def test_optional_rs_failure_can_leave_partial_daily_evidence(self) -> None:
        report = healthy_report()
        optional = deepcopy(report["observations"][2])
        optional["symbol"] = "OPTIONAL"
        del optional["rs_raw_excess_percent"]
        report["observations"].append(optional)
        report["errors"] = {"OPTIONAL": "insufficient common RS dates"}
        self.assertEqual(validator.validate_evidence(report), 0)
        # A missing RS without an explicit optional-probe error is incomplete
        # evidence rather than an acknowledged, isolated provider failure.
        report["errors"].clear()
        with self.assertRaises(validator.ValidationError):
            validator.validate_evidence(report)

    def test_old_failed_mock_or_unverified_reports_are_rejected(self) -> None:
        for field, value in (
            ("schema_version", 1), ("schema_version", True),
            ("verification_mode", "strict_entry"), ("status", "failed"),
            ("status", "running"), ("use_mock_data", True),
            ("use_mock_data", 0), ("benchmarks_verified", False),
            ("required_symbols_verified", False), ("indicators_verified", 1),
            ("failure", "provider refused connection"),
        ):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report[field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_missing_required_stock_or_benchmark_is_rejected(self) -> None:
        for symbol in (*validator.REQUIRED_SYMBOLS, *validator.REQUIRED_BENCHMARKS):
            with self.subTest(symbol=symbol):
                report = healthy_report()
                report["observations"] = [observation for observation in
                                          report["observations"]
                                          if observation["symbol"] != symbol]
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_required_failure_is_rejected_even_with_matching_observation(self) -> None:
        for symbol in (*validator.REQUIRED_SYMBOLS, *validator.REQUIRED_BENCHMARKS):
            with self.subTest(symbol=symbol):
                report = healthy_report()
                report["errors"][symbol] = "timed out"
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_required_symbol_list_cannot_be_reduced_or_duplicated(self) -> None:
        for symbols in (["NVDA"], ["NVDA"] * 5, "NVDA", [None] * 5):
            with self.subTest(symbols=symbols):
                report = healthy_report()
                report["required_symbols"] = symbols
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_wrong_market_or_currency_is_rejected(self) -> None:
        for field, value in (("currency", "TWD"), ("market", "tw"),
                             ("market", "unknown")):
            with self.subTest(field=field):
                report = healthy_report()
                report["observations"][0][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_cache_stale_or_fake_source_is_rejected(self) -> None:
        for field, value in (("is_cached", True), ("is_stale", True),
                             ("is_cached", 0), ("is_stale", None),
                             ("source", "local fixture"),
                             ("source", "Yahoo Finance mock")):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report["observations"][0][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_missing_nonfinite_or_invalid_indicator_is_rejected(self) -> None:
        for field in ("provider_price", "adr_20_percent", "ema_9", "ema_21",
                      "ema_50", "rs_raw_excess_percent"):
            for value in (None, float("nan"), float("inf"), -float("inf"), True):
                with self.subTest(field=field, value=value):
                    report = healthy_report()
                    report["observations"][2][field] = value
                    with self.assertRaises(validator.ValidationError):
                        validator.validate_evidence(report)
        for field, value in (("provider_price", 0), ("ema_9", 0),
                             ("adr_20_percent", -1),
                             ("completed_daily_bars", 60),
                             ("completed_daily_bars", 61.0)):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report["observations"][2][field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_deadline_and_elapsed_time_are_enforced(self) -> None:
        for field, value in (("elapsed_ms", 15001), ("elapsed_ms", -1),
                             ("elapsed_ms", float("nan")),
                             ("elapsed_ms", True), ("elapsed_ms", "100"),
                             ("whole_run_deadline_seconds", 90)):
            with self.subTest(field=field, value=value):
                report = healthy_report()
                report[field] = value
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)
        report = healthy_report()
        report["elapsed_ms"] = 15000
        self.assertEqual(validator.validate_evidence(report), 0)

    def test_count_and_recommendation_status_must_agree(self) -> None:
        for changes in (
            {"candidate_count": 1}, {"candidate_count": False},
            {"candidates": None}, {"candidates": ["NVDA"], "candidate_count": 1},
            {"recommendation_status": "qualified_entries"},
            {"candidates": [{}], "candidate_count": 1},
        ):
            with self.subTest(changes=changes):
                report = healthy_report()
                report.update(changes)
                with self.assertRaises(validator.ValidationError):
                    validator.validate_evidence(report)

    def test_duplicate_observation_is_rejected(self) -> None:
        report = healthy_report()
        report["observations"].append(deepcopy(report["observations"][0]))
        with self.assertRaises(validator.ValidationError):
            validator.validate_evidence(report)

    def test_cli_exit_code_allows_no_entry_but_blocks_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            report = healthy_report()
            output.write_text(json.dumps(report), encoding="utf-8")
            result = subprocess.run([sys.executable, str(VALIDATOR_PATH), str(output)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[GATE PASSED]", result.stdout)
            self.assertIn("[NO QUALIFIED ENTRY]", result.stdout)
            report["status"] = "failed"
            output.write_text(json.dumps(report), encoding="utf-8")
            result = subprocess.run([sys.executable, str(VALIDATOR_PATH), str(output)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("[GATE FAILED]", result.stderr)

    def test_cli_missing_or_invalid_file_fails_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            for content in (None, "{bad json", "null"):
                with self.subTest(content=content):
                    if content is not None:
                        output.write_text(content, encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, str(VALIDATOR_PATH), str(output)],
                        capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("[GATE FAILED]", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
