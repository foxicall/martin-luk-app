"""Provider-free page/coverage regressions; fixtures are never live evidence."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import pandas as pd

from backend.api import ApiSettings, RecommendationService
from backend.engine.data_loader import DataSourceError
from backend.engine.models import Market, MarketData, Stock
from backend.scan_jobs import BackgroundScanManager, RollingScanCheckpoint, ScanCancelled

NOW = datetime(2026, 10, 15, 2, tzinfo=timezone.utc)


class RollingCheckpointTests(unittest.TestCase):
    def test_restart_failure_and_force_do_not_reset_the_first_page(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            symbols = [f"UNIT{index:04}" for index in range(1000)]
            first = RollingScanCheckpoint(directory, "us", 5, symbols, 5)
            self.assertEqual(first.page_symbols, symbols[:5])
            for symbol in first.page_symbols:
                first.mark_attempt(symbol)
            first.mark_evaluated(set(symbols[:4]))  # fifth attempt failed
            second = RollingScanCheckpoint(directory, "us", 5, symbols, 5)
            self.assertEqual(second.page_symbols, symbols[5:10])
            self.assertEqual(second.fields()["coverage_scanned_count"], 5)
            self.assertEqual(second.fields()["coverage_evaluated_count"], 4)
            self.assertEqual(second.fields()["coverage_remaining_count"], 995)
            self.assertEqual(second.page_start, 5)

    def test_threshold_market_and_membership_are_isolated(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first = RollingScanCheckpoint(directory, "us", 5, ["A", "B"], 1)
            first.mark_attempt("A")
            self.assertEqual(RollingScanCheckpoint(directory, "us", 6, ["A", "B"], 1).page_symbols, ["A"])
            self.assertEqual(RollingScanCheckpoint(directory, "tw", 5, ["A", "B"], 1).page_symbols, ["A"])
            changed = RollingScanCheckpoint(directory, "us", 5, ["A", "C"], 1)
            self.assertNotEqual(changed.fingerprint, first.fingerprint)
            self.assertEqual(changed.page_symbols, ["A"])
            self.assertEqual(changed.fields()["coverage_scanned_count"], 0)

    def test_next_round_starts_only_after_every_symbol_was_attempted(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            symbols = ["A", "B", "C"]
            first = RollingScanCheckpoint(directory, "us", 5, symbols, 2)
            first.mark_attempt("B")  # futures can finish out of order
            resumed = RollingScanCheckpoint(directory, "us", 5, symbols, 2)
            self.assertEqual(resumed.page_symbols, ["A", "C"])
            for symbol in resumed.page_symbols:
                resumed.mark_attempt(symbol)
            self.assertEqual(resumed.fields()["coverage_remaining_count"], 0)
            self.assertEqual(resumed.round, 1)
            next_round = RollingScanCheckpoint(directory, "us", 5, symbols, 2)
            self.assertEqual(next_round.round, 2)
            self.assertEqual(next_round.page_symbols, ["A", "B"])
            self.assertEqual(next_round.fields()["coverage_evaluated_count"], 0)

    def test_corrupt_or_old_checkpoint_is_not_trusted(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first = RollingScanCheckpoint(directory, "us", 5, ["A", "B"], 2)
            payload = json.loads(first.path.read_text())
            payload["attempted_symbols"] = ["INJECTED"]
            first.path.write_text(json.dumps(payload))
            recovered = RollingScanCheckpoint(directory, "us", 5, ["A", "B"], 2)
            self.assertEqual(recovered.fields()["coverage_scanned_count"], 0)

    def test_nonobject_checkpoint_roots_are_cache_misses(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first = RollingScanCheckpoint(directory, "us", 5, ["A", "B"], 2)
            for payload in ([], None, "broken", 1, True):
                with self.subTest(payload=payload):
                    first.path.write_text(json.dumps(payload))
                    recovered = RollingScanCheckpoint(directory, "us", 5, ["A", "B"], 2)
                    self.assertEqual(recovered.page_symbols, ["A", "B"])
                    self.assertEqual(recovered.fields()["coverage_scanned_count"], 0)

    def test_partial_coverage_snapshot_expires_after_one_minute(self):
        manager = BackgroundScanManager(lambda *_: {}, lambda *_: None,
                                        now=lambda: NOW, cache_ttl_seconds=300,
                                        page_interval_seconds=60)
        recent = {"generated_at": (NOW - timedelta(seconds=59)).isoformat(),
                  "coverage_remaining_count": 100}
        self.assertTrue(manager._fresh(recent))
        recent["generated_at"] = (NOW - timedelta(seconds=61)).isoformat()
        self.assertFalse(manager._fresh(recent))
        recent["coverage_remaining_count"] = 0
        self.assertTrue(manager._fresh(recent))


class RollingServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.stocks = [Stock(f"UNIT{index:04}", f"Unit {index}", "fixture", Market.US)
                       for index in range(1001)]
        self.loaded: list[str] = []
        self.failing: set[str] = set()
        self.daily = pd.DataFrame({
            "open": [100.] * 100, "high": [106.] * 100, "low": [99.] * 100,
            "close": [102.] * 100, "volume": [1000.] * 100,
        }, index=pd.bdate_range(end="2026-10-14", periods=100))
        owner = self
        class Universe:
            warnings = ["unit classification warning"]
            sources = {Market.US: "unit expanded directory / not live"}
            captured_at = {Market.US: pd.Timestamp(NOW)}
            coverage_complete = {Market.US: False}
            def __init__(self, *_, **__): pass
            def load(self, *_, **__): return owner.stocks.copy()
        class Loader:
            def __init__(self, *_, **__): self.errors, self.warnings = {}, []
            def load_benchmark(self, *_, **__): return owner.daily
            def load(self, batch, as_of, **_):
                stock = batch[0]
                owner.loaded.append(stock.symbol)
                if stock.symbol in owner.failing:
                    raise DataSourceError("unit symbol unavailable")
                return {stock.symbol: MarketData(stock, owner.daily, pd.DataFrame(), as_of)}
        class Scanner:
            errors, warnings = {}, []
            def __init__(self, _): pass
            def calculate_adr(self, _): return 6.
            def evaluate(self, *_): return []
        self.patches = [patch("backend.api.UniverseProvider", Universe),
                        patch("backend.api.MarketDataLoader", Loader),
                        patch("backend.api.MomentumScanner", Scanner),
                        patch("backend.api.time.sleep")]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temporary.cleanup()

    def service(self):
        result = RecommendationService(ApiSettings(cache_dir=self.directory, scan_page_size=5), now=lambda: NOW)
        result.calendar = SimpleNamespace(context=lambda *_: SimpleNamespace(calendar_source="unit"))
        return result

    def test_thousand_stock_scope_is_five_per_page_and_restart_resumes(self):
        first = self.service().get_candidates(Market.US, 5, True)
        self.assertEqual(first.universe_count, 1001)
        self.assertEqual(first.scan_pool_size, 5)
        self.assertEqual(first.coverage_scanned_count, 5)
        self.assertEqual(first.coverage_evaluated_count, 5)
        self.assertEqual(first.coverage_remaining_count, 996)
        self.assertFalse(first.universe_is_complete)
        second = self.service().get_candidates(Market.US, 5, True)
        self.assertEqual(second.scan_page_start, 5)
        self.assertEqual(second.coverage_scanned_count, 10)
        self.assertEqual(len(set(self.loaded)), 10)
        self.assertTrue(any("僅代表本頁" in note for note in second.warnings))
        self.assertIn("unit classification warning", second.warnings)

    def test_symbol_failure_is_an_attempt_but_never_verified_success(self):
        self.failing.add("UNIT0001")
        result = self.service().get_candidates(Market.US, 5, True)
        self.assertEqual(result.scan_pool_size, 5)
        self.assertEqual(result.evaluated_count, 4)
        self.assertEqual(result.coverage_scanned_count, 5)
        self.assertEqual(result.coverage_evaluated_count, 4)
        self.assertEqual(result.missing_symbols, ["UNIT0001"])
        self.assertTrue(result.stale)

    def test_deadline_keeps_attempts_and_does_not_claim_late_results(self):
        def progress(**updates):
            if updates.get("completed_count") == 2:
                raise ScanCancelled("unit deadline")
        with self.assertRaises(ScanCancelled):
            self.service().get_candidates(Market.US, 5, True, progress=progress)
        checkpoint = RollingScanCheckpoint(self.directory / "scan_coverage", "us", 5,
                                           [stock.symbol for stock in self.stocks], 5)
        attempted = checkpoint.attempted.copy()
        self.assertEqual(len(attempted), 2)
        self.assertEqual(checkpoint.fields()["coverage_evaluated_count"], 0)
        self.loaded.clear()
        result = self.service().get_candidates(Market.US, 5, True)
        self.assertTrue(attempted.isdisjoint(self.loaded))
        self.assertEqual(result.coverage_scanned_count, 7)
        self.assertEqual(result.coverage_evaluated_count, 5)

    def test_failed_page_advances_coverage_without_inventing_a_snapshot(self):
        self.failing = {stock.symbol for stock in self.stocks[:5]}
        with self.assertRaisesRegex(DataSourceError, "無可用"):
            self.service().get_candidates(Market.US, 5, True)
        result = self.service().get_candidates(Market.US, 5, True)
        self.assertEqual(result.scan_page_start, 5)
        self.assertEqual(result.coverage_scanned_count, 10)
        self.assertEqual(result.coverage_evaluated_count, 5)

    def test_snapshot_cache_from_old_sp500_scope_is_not_reused(self):
        old = self.directory / "responses" / f"us_{float(5).hex()}.json"
        old.parent.mkdir(parents=True)
        old.write_text("{\"old_sp500_snapshot\":true}")
        result = self.service().get_candidates(Market.US, 5)
        self.assertEqual(result.universe_count, 1001)
        self.assertEqual(len(self.loaded), 5)

    def test_non_force_auto_refresh_advances_after_page_interval(self):
        first = self.service().get_candidates(Market.US, 5)
        cached_service = self.service()
        cached = cached_service.get_candidates(Market.US, 5)
        self.assertEqual(cached.scan_page_start, first.scan_page_start)
        self.assertEqual(len(self.loaded), 5)
        after_interval = self.service()
        after_interval.now = lambda: NOW + timedelta(seconds=61)
        advanced = after_interval.get_candidates(Market.US, 5)
        self.assertEqual(advanced.scan_page_start, 5)
        self.assertEqual(advanced.coverage_scanned_count, 10)
        self.assertEqual(len(set(self.loaded)), 10)


if __name__ == "__main__":
    unittest.main()
