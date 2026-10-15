"""Provider-free concurrency/HTTP regression tests, never live market evidence.

Events deliberately hold a fake provider while real ASGI requests exercise the
API. These fixtures verify deadlines, isolation and snapshots, not Yahoo access.
"""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import pandas as pd

from backend.api import ApiSettings, CandidatesResponse, RecommendationService, create_app
from backend.engine.data_loader import DataSourceError, _atomic_text
from backend.engine.models import Market, MarketData, Stock
from backend.scan_jobs import BackgroundScanManager, ScanCancelled
from backend.tests.test_api import AsgiClient

NOW = datetime(2026, 10, 15, 2, tzinfo=timezone.utc)


class ControlledService(RecommendationService):
    def __init__(self, settings: ApiSettings) -> None:
        super().__init__(settings, now=lambda: NOW)
        self.calls: Counter[Market] = Counter()
        self.entered = {market: threading.Event() for market in Market}
        self.release = {market: threading.Event() for market in Market}
        self.fail: set[Market] = set()

    def _scan_live(self, market, threshold, force_refresh, progress=None):
        self.calls[market] += 1
        self.entered[market].set()
        if progress:
            progress(stage="loading_prices", total_count=1, universe_count=1)
        if not self.release[market].wait(timeout=4):
            raise DataSourceError("unit fixture was not released")
        if market in self.fail:
            raise DataSourceError("unit provider unavailable")
        if progress:
            progress(stage="calculating_indicators", completed_count=1, evaluated_count=1)
        return CandidatesResponse(
            market=market.value, generated_at=NOW,
            source="injected unit provider / not live evidence", universe_count=1,
            stale=False, candidates=[], scan_pool_size=1, evaluated_count=1,
            adr_match_count=0, scan_completed_at=NOW, universe_is_complete=False,
        )


class BackgroundApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        settings = ApiSettings(cache_dir=Path(self.temp.name), scan_timeout_seconds=2)
        self.service = ControlledService(settings)
        self.app = create_app(self.service)
        self.client = AsgiClient(self.app)

    def tearDown(self) -> None:
        for event in self.service.release.values():
            event.set()
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if not any(slot.worker_live for slot in self.app.state.background_scans._slots.values()):
                break
            time.sleep(0.005)
        self.temp.cleanup()

    def get(self, market="us", **params):
        return self.client.get("/v1/candidates", {"market": market, "background": True, **params})

    def wait_status(self, status, market="us", timeout=1):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.get(market)
            if response.json()["scan"]["status"] == status:
                return response
            time.sleep(0.005)
        self.fail(f"background job did not reach {status}")

    def test_blocked_worker_does_not_block_202_health_or_singleflight_force(self):
        started = time.monotonic()
        response = self.get()
        self.assertEqual(response.status_code, 202)
        self.assertIsNone(response.json()["snapshot"])
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertTrue(self.service.entered[Market.US].wait(0.5))
        self.assertTrue(self.service._locks[Market.US].locked())
        job_id = response.json()["scan"]["job_id"]
        for _ in range(5):
            later = self.get(force_refresh=True)
            self.assertEqual(later.json()["scan"]["job_id"], job_id)
        self.assertEqual(self.service.calls[Market.US], 1)
        started = time.monotonic()
        health = self.client.get("/health")
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertEqual(health.json(), {
            "status": "ok", "version": "1.2.0", "background_scan": True,
            "provider_verified": False,
        })

    def test_markets_are_independent_and_progress_counts_are_visible(self):
        us, tw = self.get(), self.get("tw")
        self.assertNotEqual(us.json()["scan"]["job_id"], tw.json()["scan"]["job_id"])
        for market in Market:
            self.assertTrue(self.service.entered[market].wait(0.5))
        running = self.get().json()["scan"]
        self.assertEqual(running["total_count"], 1)
        self.assertEqual(running["completed_count"], 0)
        self.service.release[Market.TW].set()
        self.assertEqual(self.wait_status("completed", "tw").status_code, 200)
        self.assertEqual(self.get().status_code, 202)

    def test_completed_empty_recommendations_are_a_successful_snapshot(self):
        self.service.release[Market.US].set()
        self.get()
        response = self.wait_status("completed")
        body = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(body["snapshot"]["candidates"], [])
        self.assertFalse(body["snapshot"]["stale"])
        self.assertEqual(body["scan"]["completed_count"], 1)
        self.assertEqual(body["scan"]["evaluated_count"], 1)
        self.assertEqual(self.service.calls[Market.US], 1)
        self.get()
        self.assertEqual(self.service.calls[Market.US], 1)

    def test_failure_without_cache_is_503_and_cooldown_applies_even_to_force(self):
        self.service.fail.add(Market.US)
        self.service.release[Market.US].set()
        self.get()
        response = self.wait_status("failed")
        self.assertEqual(response.status_code, 503)
        self.assertIn("unit provider unavailable", response.json()["scan"]["error"])
        job_id = response.json()["scan"]["job_id"]
        for _ in range(4):
            self.assertEqual(self.get(force_refresh=True).json()["scan"]["job_id"], job_id)
        self.assertEqual(self.service.calls[Market.US], 1)

    def test_old_disk_snapshot_keeps_timestamp_during_refresh_and_failure(self):
        old = NOW - timedelta(days=1)
        snapshot = CandidatesResponse(
            market="us", generated_at=old, source="real provider / old cached scan",
            universe_count=500, stale=False, candidates=[],
        )
        _atomic_text(self.service._response_path(Market.US, 5.0), snapshot.model_dump_json())
        self.get()
        self.assertTrue(self.service.entered[Market.US].wait(0.5))
        body = self.get().json()
        self.assertEqual(body["snapshot"]["generated_at"], snapshot.model_dump(mode="json")["generated_at"])
        self.assertTrue(body["snapshot"]["stale"])
        self.service.fail.add(Market.US)
        self.service.release[Market.US].set()
        failed = self.wait_status("failed")
        self.assertEqual(failed.status_code, 200)
        self.assertEqual(failed.json()["snapshot"]["generated_at"], body["snapshot"]["generated_at"])
        self.assertTrue(failed.json()["snapshot"]["stale"])

    def test_thresholds_do_not_share_an_incompatible_snapshot(self):
        self.service.release[Market.US].set()
        self.get()
        self.wait_status("completed")
        self.service.release[Market.US].clear()
        response = self.get(adr_threshold=6)
        self.assertEqual(response.status_code, 202)
        self.assertIsNone(response.json()["snapshot"])
        self.assertEqual(self.get(adr_threshold=6, force_refresh=True).status_code, 202)
        deadline = time.monotonic() + 0.5
        while self.service.calls[Market.US] < 2 and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(self.service.calls[Market.US], 2)

    def test_slow_disk_hydration_is_also_outside_the_http_fast_path(self):
        gate = threading.Event()
        entered = threading.Event()
        def blocked_cache(*_):
            entered.set()
            gate.wait(1)
            return None
        with patch.object(self.service, "background_cached_response", side_effect=blocked_cache):
            started = time.monotonic()
            try:
                self.assertEqual(self.get().status_code, 202)
                self.assertTrue(entered.wait(0.5))
                self.assertEqual(self.client.get("/health").status_code, 200)
                self.assertLess(time.monotonic() - started, 0.5)
            finally:
                gate.set()

    def test_demo_cannot_be_substituted_for_live_background_data(self):
        self.assertEqual(self.get(demo=True).status_code, 422)


class DeadlineTests(unittest.TestCase):
    def test_legacy_null_counters_are_normalized_and_start_timestamp_is_ordered(self):
        entered, release = threading.Event(), threading.Event()
        tick = [0]
        def now():
            tick[0] += 1
            return NOW + timedelta(microseconds=tick[0])
        def scan(market, threshold, force, progress):
            entered.set()
            release.wait(1)
            return {"market": market, "generated_at": NOW.isoformat(), "stale": False,
                    "source": "unit legacy cache", "universe_count": 500,
                    "scan_pool_size": None, "evaluated_count": None,
                    "adr_match_count": None, "missing_symbols": None, "candidates": []}
        manager = BackgroundScanManager(scan, lambda *_: None, now=now)
        manager.poll("us", 5)
        self.assertTrue(entered.wait(0.5))
        state = manager.poll("us", 5)[1]["scan"]
        self.assertLessEqual(state["started_at"], state["updated_at"])
        self.assertEqual(state["started_at"], state["updated_at"])
        release.set()
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            state = manager.poll("us", 5)[1]["scan"]
            if state["status"] == "completed": break
            time.sleep(0.005)
        self.assertEqual(state["status"], "completed")
        self.assertEqual(state["completed_count"], 500)
        self.assertEqual(state["total_count"], 500)
        self.assertEqual(state["evaluated_count"], 0)
        self.assertEqual(state["adr_match_count"], 0)
        self.assertEqual(state["failed_count"], 0)
        self.assertLessEqual(state["started_at"], state["completed_at"])
        self.assertLessEqual(state["completed_at"], state["updated_at"])

    def test_timeout_closes_state_but_live_worker_retains_slot_and_late_result_is_ignored(self):
        entered, release, exited = threading.Event(), threading.Event(), threading.Event()
        late_progress_rejected = threading.Event()
        clock = [0.0]
        calls = []
        def scan(market, threshold, force, progress):
            calls.append((market, threshold))
            entered.set()
            release.wait(1)
            try:
                progress(stage="late_provider_result")
            except ScanCancelled:
                late_progress_rejected.set()
            exited.set()
            return {"market": market, "generated_at": NOW.isoformat(), "stale": False,
                    "source": "unit / not live", "universe_count": 1, "candidates": []}
        manager = BackgroundScanManager(
            scan, lambda *_: None, timeout_seconds=0.03,
            failure_cooldown_seconds=30, now=lambda: NOW, monotonic=lambda: clock[0],
        )
        _, first = manager.poll("us", 5)
        self.assertTrue(entered.wait(0.5))
        time.sleep(0.07)
        status, failed = manager.poll("us", 5, force=True)
        self.assertEqual(status, 503)
        self.assertEqual(failed["scan"]["stage"], "timed_out")
        self.assertEqual(failed["scan"]["job_id"], first["scan"]["job_id"])
        clock[0] = 100  # Even expired cooldown cannot bypass a live worker.
        for _ in range(5):
            self.assertEqual(manager.poll("us", 5, force=True)[1]["scan"]["job_id"], first["scan"]["job_id"])
        self.assertEqual(len(calls), 1)
        release.set()
        self.assertTrue(exited.wait(0.5))
        self.assertTrue(late_progress_rejected.is_set())
        deadline = time.monotonic() + 0.5
        while manager._slots["us"].worker_live and time.monotonic() < deadline:
            time.sleep(0.005)
        clock[0] = 0
        late = manager.poll("us", 5)[1]
        self.assertEqual(late["scan"]["status"], "failed")
        self.assertIsNone(late["snapshot"])
        clock[0] = 31
        manager.poll("us", 5, force=True)
        deadline = time.monotonic() + 0.5
        while len(calls) < 2 and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(len(calls), 2)


class ChunkingTests(unittest.TestCase):
    def test_core_pool_cap_bounded_parallelism_and_symbol_failure_isolation(self):
        active = 0
        maximum = 0
        lock = threading.Lock()
        loaded = []
        reports = []
        symbols = ["AAPL", "NVDA", "TSLA", "AMD", "PLTR", "MSFT", "META", "OTHER"]
        stocks = [Stock(symbol, symbol, "unit fixture", Market.US) for symbol in symbols]
        daily = pd.DataFrame({"open": [100.0] * 100, "high": [106.0] * 100,
                              "low": [99.0] * 100, "close": [102.0] * 100,
                              "volume": [1000.0] * 100},
                             index=pd.bdate_range(end="2026-10-14", periods=100))
        class Universe:
            warnings = []
            sources = {Market.US: "unit metadata / not live"}
            captured_at = {Market.US: pd.Timestamp(NOW)}
            def __init__(self, *_, **__): pass
            def load(self, *_, **__): return stocks.copy()
        class Loader:
            def __init__(self, *_, **__):
                self.errors, self.warnings = {}, []
            def load_benchmark(self, *_, **__): return daily
            def load(self, batch, as_of, **_):
                nonlocal active, maximum
                self_stock = batch[0]
                with lock:
                    active += 1
                    maximum = max(maximum, active)
                    loaded.append(self_stock.symbol)
                try:
                    time.sleep(0.01)
                    if self_stock.symbol == "AMD":
                        raise ValueError("unit malformed symbol")
                    return {self_stock.symbol: MarketData(self_stock, daily, pd.DataFrame(), as_of)}
                finally:
                    with lock: active -= 1
        class Scanner:
            errors, warnings = {}, []
            def __init__(self, _): pass
            def calculate_adr(self, _): return 6.0
            def evaluate(self, *args): return []
        with tempfile.TemporaryDirectory() as temp:
            service = RecommendationService(ApiSettings(cache_dir=Path(temp), scan_pool_limit=7), now=lambda: NOW)
            service.calendar = SimpleNamespace(context=lambda *_: SimpleNamespace(calendar_source="unit"))
            with patch("backend.api.UniverseProvider", Universe), \
                    patch("backend.api.MarketDataLoader", Loader), \
                    patch("backend.api.MomentumScanner", Scanner), \
                    patch("backend.api.time.sleep", wraps=time.sleep) as sleeper:
                result = service.get_candidates(Market.US, 5, progress=lambda **state: reports.append(state))
        self.assertEqual(len(loaded), 7)
        self.assertNotIn("OTHER", loaded)
        self.assertLessEqual(maximum, 3)
        self.assertGreater(maximum, 1)
        self.assertEqual(result.scan_pool_size, 7)
        self.assertEqual(result.universe_count, 8)
        self.assertEqual(result.evaluated_count, 6)
        self.assertEqual(result.adr_match_count, 6)
        self.assertEqual(result.missing_symbols, ["AMD"])
        self.assertFalse(result.universe_is_complete)
        self.assertEqual(result.candidates, [])
        self.assertEqual([r["completed_count"] for r in reports if "completed_count" in r], list(range(1, 8)))
        self.assertEqual(sum(call.args == (0.15,) for call in sleeper.call_args_list), 2)


if __name__ == "__main__":
    unittest.main()
