"""Provider-free API, stop-policy, cache, and stale-benchmark regression tests."""
from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import httpx
import pandas as pd

from backend.api import ApiSettings, RecommendationService, create_app, serialize_candidate
from backend.engine.data_loader import DataSourceError, MarketDataLoader
from backend.engine.market_calendar import NonTradingDayError
from backend.engine.models import Candidate, Market, MarketData, Stock


NOW = datetime(2026, 10, 13, 12, 45, tzinfo=timezone.utc)


class AsgiClient:
    """Use the real ASGI app without sockets or an anyio blocking portal."""

    def __init__(self, app) -> None:
        self.app = app

    def get(self, path: str, params: dict | None = None) -> httpx.Response:
        async def inline_worker(function, *args, **kwargs):
            # The HTTP contract does not depend on the event loop's worker
            # implementation. Avoid restricted cross-thread wakeup sockets in
            # sandboxed tests; direct service/cache/risk tests cover the work.
            return function(*args, **kwargs)

        async def request() -> httpx.Response:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=self.app), base_url="http://test"
            ) as client:
                return await asyncio.wait_for(client.get(path, params=params), timeout=10)
        with patch("backend.api.to_thread", side_effect=inline_worker):
            return asyncio.run(request())

    def close(self) -> None:
        pass


def candidate(**changes: object) -> Candidate:
    base = Candidate(
        stock=Stock("TEST", "Test", "Technology", Market.US, True),
        adr_pct=5.5, rs20=0.1, rs60=0.3, momentum_score=0.2,
        rs_rank=1, rs_percentile=100, scanners=("Leader",), patterns=("PDH突破",),
        status="confirmed", entry_price=100, day_low=98, entry_bar_low=98.5,
        signal_time=pd.Timestamp(NOW), data_time=pd.Timestamp(NOW),
    )
    return replace(base, **changes)


class FakeLiveService(RecommendationService):
    """Exercise live response caching without contacting a market-data host."""

    def __init__(self, settings: ApiSettings) -> None:
        super().__init__(settings, now=lambda: NOW)
        self.calls = 0

    def _scan_live(self, market: Market, threshold: float, force_refresh: bool):
        self.calls += 1
        return self._demo(market, threshold).model_copy(update={"source": "yfinance / injected provider"})


class ApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.settings = ApiSettings(cache_dir=Path(self.temp.name))
        self.service = RecommendationService(self.settings, now=lambda: NOW)
        self.client = AsgiClient(create_app(self.service))

    def tearDown(self) -> None:
        self.client.close()
        self.temp.cleanup()

    def test_health_does_not_fetch_provider(self) -> None:
        with patch.object(self.service, "_scan_live", side_effect=AssertionError("no network")):
            self.assertEqual(self.client.get("/health").json()["status"], "ok")

    def test_demo_tw_native_symbols_and_aware_timestamps(self) -> None:
        response = self.client.get("/v1/candidates", params={"market": "tw", "demo": "true"})
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["source"].startswith("mock"))
        self.assertEqual(body["universe_count"], 4)
        self.assertTrue(all(row["symbol"].endswith(".TW") for row in body["candidates"]))
        self.assertIsNotNone(datetime.fromisoformat(body["generated_at"].replace("Z", "+00:00")).tzinfo)

    def test_adr_filter_is_inclusive(self) -> None:
        body = self.client.get("/v1/candidates", params={"market": "us", "demo": True, "adr_threshold": 5.4}).json()
        self.assertIn("AMD", [row["symbol"] for row in body["candidates"]])
        self.assertTrue(all(row["adr_percent"] >= 5.4 for row in body["candidates"]))

    def test_high_threshold_produces_empty_success(self) -> None:
        response = self.client.get("/v1/candidates", params={"market": "tw", "demo": True, "adr_threshold": 20})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["candidates"], [])

    def test_watchlist_has_no_stop(self) -> None:
        body = self.client.get("/v1/candidates", params={"market": "us", "demo": True}).json()
        row = next(row for row in body["candidates"] if row["status"] == "watchlist")
        self.assertIsNone(row["stop_price"])
        self.assertIsNone(row["signal_timestamp"])

    def test_invalid_market_and_threshold_rejected(self) -> None:
        for params in ({"market": "all"}, {"market": "us", "adr_threshold": -1},
                       {"market": "us", "adr_threshold": 31}, {"market": "us", "adr_threshold": "NaN"}):
            with self.subTest(params=params):
                self.assertEqual(self.client.get("/v1/candidates", params=params).status_code, 422)

    def test_provider_failure_has_503_and_no_mock(self) -> None:
        with patch.object(self.service, "_scan_live", side_effect=DataSourceError("source offline")):
            response = self.client.get("/v1/candidates", params={"market": "us"})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], "source offline")
        self.assertEqual(response.headers["Retry-After"], "300")

    def test_nontrading_day_is_explained(self) -> None:
        with patch.object(self.service, "_scan_live", side_effect=NonTradingDayError("台股休市")):
            response = self.client.get("/v1/candidates", params={"market": "tw"})
        self.assertEqual(response.status_code, 503)
        self.assertIn("休市", response.json()["detail"])

    def test_return_values_do_not_mutate_cached_response(self) -> None:
        first = self.service.get_candidates(Market.US, 5.0, demo=True)
        first.candidates.clear()
        second = self.service.get_candidates(Market.US, 5.0, demo=True)
        self.assertGreater(len(second.candidates), 0)

    def test_live_response_cache_and_force_refresh(self) -> None:
        service = FakeLiveService(self.settings)
        first = service.get_candidates(Market.US, 5.0)
        service.get_candidates(Market.US, 5.0)
        self.assertEqual(service.calls, 1)
        self.assertEqual(first.generated_at, NOW)
        service.get_candidates(Market.US, 5.0, force_refresh=True)
        self.assertEqual(service.calls, 2)

    def test_disk_response_cache_reused_by_another_process(self) -> None:
        FakeLiveService(self.settings).get_candidates(Market.TW, 3.5)
        other = FakeLiveService(self.settings)
        result = other.get_candidates(Market.TW, 3.5)
        self.assertEqual(other.calls, 0)
        self.assertEqual(result.generated_at, NOW)

    def test_cache_keys_include_threshold_and_mode(self) -> None:
        service = FakeLiveService(self.settings)
        service.get_candidates(Market.US, 5.0, demo=True)
        service.get_candidates(Market.US, 5.0)
        service.get_candidates(Market.US, 6.0)
        self.assertEqual(service.calls, 2)

    def test_expired_disk_response_cannot_hide_provider_failure(self) -> None:
        service = FakeLiveService(self.settings)
        service.get_candidates(Market.US, 5.0)
        other = RecommendationService(self.settings, now=lambda: datetime(2026, 10, 14, tzinfo=timezone.utc))
        with patch.object(other, "_scan_live", side_effect=DataSourceError("offline")):
            with self.assertRaises(DataSourceError):
                other.get_candidates(Market.US, 5.0)


class StopPolicyTests(unittest.TestCase):
    def test_actual_day_low_is_preserved(self) -> None:
        row = serialize_candidate(candidate())
        self.assertEqual(row.status, "confirmed")
        self.assertEqual(row.stop_price, 98)

    def test_boundary_stops_are_inclusive(self) -> None:
        for low in (97, 98.5):
            row = serialize_candidate(candidate(day_low=low, entry_bar_low=low))
            self.assertEqual(row.status, "confirmed")

    def test_four_percent_day_low_allowed(self) -> None:
        row = serialize_candidate(candidate(day_low=96, entry_bar_low=98))
        self.assertEqual(row.status, "confirmed")
        self.assertEqual(row.stop_price, 96)
        self.assertEqual(row.stop_source, "day_low")
        self.assertEqual(row.risk_per_share, 4)

    def test_one_percent_observed_day_low_allowed(self) -> None:
        row = serialize_candidate(candidate(day_low=99, entry_bar_low=99.5))
        self.assertEqual(row.status, "confirmed")
        self.assertEqual(row.stop_price, 99)

    def test_wide_day_uses_real_entry_bar_low(self) -> None:
        row = serialize_candidate(candidate(day_low=90, entry_bar_low=98))
        self.assertEqual(row.status, "confirmed")
        self.assertEqual(row.stop_price, 98)

    def test_wide_day_missing_entry_bar_low_downgraded(self) -> None:
        row = serialize_candidate(candidate(day_low=90, entry_bar_low=None))
        self.assertEqual(row.status, "watchlist")
        self.assertIsNone(row.stop_price)

    def test_naive_daily_label_localized_to_market_timezone(self) -> None:
        row = serialize_candidate(candidate(data_time=pd.Timestamp("2026-10-12")))
        self.assertEqual(row.data_timestamp.hour, 4)  # NY midnight in October = UTC 04:00.
        self.assertIsNotNone(row.data_timestamp.tzinfo)

    def test_stale_benchmark_raises_instead_of_computing_rs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            loader = MarketDataLoader(temp)
            stock = Stock("^GSPC", "benchmark", "Benchmark", Market.US)
            stale = MarketData(stock, pd.DataFrame(), pd.DataFrame(), pd.Timestamp(NOW), is_stale=True)
            with patch.object(loader, "load", return_value={"^GSPC": stale}):
                with self.assertRaisesRegex(DataSourceError, "過期快取"):
                    loader.load_benchmark(Market.US, pd.Timestamp(NOW))


if __name__ == "__main__":
    unittest.main()
