"""不需金融網路／伺服器的出場、保存、報價與 JSON 合約測試。"""
from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import httpx
import pandas as pd

from backend.api import ApiSettings, QuoteService, RecommendationService, create_app
from backend.engine.data_loader import DataSourceError
from backend.engine.exit_engine import (ExitAdvisoryEngine, ExitConfig, PortfolioError,
                                       Position, QuoteSnapshot)
from backend.engine.models import EvaluationContext, Market, MarketData, Stock
from backend.engine.portfolio_tracker import (PortfolioAnalyzer, PortfolioStorageError,
                                             PortfolioTracker, demo_quote)


NOW = datetime(2026, 10, 13, 12, 45, tzinfo=timezone.utc)
CLOSED = datetime(2026, 10, 12, 20, tzinfo=timezone.utc)


def holding(**changes: object) -> Position:
    return replace(Position("one", "NVDA", Market.US, 100, 100, 98), **changes)


def quote(**changes: object) -> QuoteSnapshot:
    return replace(QuoteSnapshot("NVDA", "NVIDIA test", Market.US, 103, 102, 100, 95,
                                 103, True, NOW, CLOSED, "injected test source", True), **changes)


class ExitEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = ExitAdvisoryEngine()

    def analyze(self, position: Position | None = None, snapshot: QuoteSnapshot | None = None,
                equity: float = 100_000):
        return self.engine.analyze(position or holding(), snapshot or quote(), equity)

    def test_fixed_r_and_target_prices(self) -> None:
        diagnosis, observed = self.analyze(snapshot=quote(current_price=106, last_close=105))
        self.assertEqual(diagnosis.current_r, 3)
        self.assertEqual(diagnosis.risk_per_share, 2)
        self.assertEqual(diagnosis.targets, {"1": 102, "2": 104, "3": 106, "5": 110, "10": 120})
        self.assertEqual(diagnosis.action, "trim")
        self.assertEqual(diagnosis.trim_shares, 15)
        later, _ = self.analyze(observed, quote(current_price=101, last_close=103))
        self.assertEqual(later.current_r, 0.5)
        self.assertEqual(later.initial_stop, 98)
        self.assertEqual(later.trailing_stop, 100)
        self.assertEqual(later.peak_r, 3)

    def test_two_r_arms_breakeven_and_next_reload_preserves_it(self) -> None:
        below, below_state = self.analyze(snapshot=quote(current_price=103.999999))
        self.assertEqual(below_state.trailing_stop, 98)
        exact, state = self.analyze(snapshot=quote(current_price=104))
        self.assertEqual(exact.action, "hold")
        self.assertEqual(state.trailing_stop, 100)
        self.assertEqual(state.peak_r, 2)
        back, _ = self.analyze(state, quote(current_price=100, last_close=103))
        self.assertEqual(back.action, "exit")
        self.assertIn("breakeven_stop", back.reason_codes)
        self.assertEqual(below.peak_r, below.current_r)

    def test_initial_stop_equality_exits(self) -> None:
        result, _ = self.analyze(snapshot=quote(current_price=98, close_confirmed=False))
        self.assertEqual(result.action, "exit")
        self.assertIn("hard_stop", result.reason_codes)

    def test_stop_priority_beats_strength_and_ema_reason(self) -> None:
        result, _ = self.analyze(holding(peak_r=5, trailing_stop=111),
                                 quote(current_price=110, last_close=90))
        self.assertEqual(result.action, "exit")
        self.assertIn("hard_stop", result.reason_codes)
        self.assertNotIn("target_5r", result.reason_codes)
        self.assertIsNone(result.trim_shares)

    def test_intraday_ema_break_does_not_replace_finalized_close(self) -> None:
        result, _ = self.analyze(snapshot=quote(current_price=101, ema9=102, last_close=99,
                                               close_confirmed=False, close_timestamp=None))
        self.assertEqual(result.action, "hold")
        self.assertEqual(result.health, "consolidating")
        finalized, _ = self.analyze(snapshot=quote(current_price=103, last_close=101))
        self.assertEqual(finalized.action, "exit")
        self.assertIn("close_below_ema9", finalized.reason_codes)
        equality, _ = self.analyze(snapshot=quote(last_close=102))
        self.assertEqual(equality.action, "hold")

    def test_main_uptrend_ema_switch_needs_observed_three_r(self) -> None:
        result, _ = self.analyze(holding(trailing_ema=21, main_uptrend=True, peak_r=2),
                                 quote(current_price=103, last_close=101))
        self.assertEqual(result.effective_trailing_ema, 9)
        self.assertEqual(result.action, "exit")
        permitted, _ = self.analyze(holding(trailing_ema=21, main_uptrend=True, peak_r=3),
                                    quote(current_price=103, last_close=101))
        self.assertEqual(permitted.effective_trailing_ema, 21)
        self.assertEqual(permitted.action, "hold")
        no_flag, _ = self.analyze(holding(trailing_ema=50, main_uptrend=False, peak_r=10),
                                  quote(current_price=103, last_close=101))
        self.assertEqual(no_flag.effective_trailing_ema, 9)

    def test_small_cap_25_percent_warning_is_not_35_percent_strength(self) -> None:
        result, _ = self.analyze(snapshot=quote(is_large_liquid=False), equity=35_000)
        self.assertGreater(result.exposure_pct, 25)
        self.assertLess(result.exposure_pct, 35)
        self.assertTrue(result.over_exposure)
        self.assertEqual(result.action, "hold")
        self.assertIn("exposure_cap_exceeded", result.reason_codes)

    def test_35_percent_equality_does_not_trim(self) -> None:
        result, _ = self.analyze(snapshot=quote(current_price=100, ema9=100, last_close=100), equity=100_000 / 3.5)
        # Use exact decimal equality for a second case to isolate thresholds.
        equal, _ = self.analyze(holding(shares=35), quote(current_price=100, ema9=100, last_close=100), 10_000)
        self.assertEqual(equal.exposure_pct, 35)
        self.assertEqual(equal.action, "hold")
        over, _ = self.analyze(holding(shares=36), quote(current_price=100, ema9=100, last_close=100), 10_000)
        self.assertEqual(over.action, "trim")
        self.assertIn("position_above_35pct", over.reason_codes)
        self.assertGreater(result.exposure_pct, 34)

    def test_euphoria_strict_threshold_and_config_range(self) -> None:
        position = holding(entry_price=110, initial_stop=100)
        exact, _ = self.analyze(position, quote(current_price=120, ema9=100, last_close=120))
        self.assertEqual(exact.action, "hold")
        higher, _ = self.analyze(position, quote(current_price=120.01, ema9=100, last_close=120))
        self.assertEqual(higher.action, "trim")
        self.assertIn("euphoria", higher.reason_codes)
        lower_limit = ExitAdvisoryEngine(ExitConfig(15))
        result, _ = lower_limit.analyze(position, quote(current_price=116, ema9=100, last_close=116), 100_000)
        self.assertEqual(result.action, "trim")
        for value in (14.9, 20.1, float("nan"), True):
            with self.assertRaises(PortfolioError):
                ExitConfig(value)

    def test_trim_rounding_stays_10_to_15_percent_or_none(self) -> None:
        for shares in range(1, 45):
            with self.subTest(shares=shares):
                result, _ = self.analyze(holding(shares=shares), quote(current_price=106))
                self.assertEqual(result.action, "trim")
                if result.trim_shares is not None:
                    self.assertGreaterEqual(result.trim_shares / shares, 0.1)
                    self.assertLessEqual(result.trim_shares / shares, 0.15)
                else:
                    self.assertTrue(all(not 0.1 <= n / shares <= 0.15 for n in range(1, shares + 1)))

    def test_r_milestones_highest_current_target(self) -> None:
        for price, code in ((106, "target_3r"), (110, "target_5r"), (120, "target_10r")):
            result, _ = self.analyze(snapshot=quote(current_price=price))
            self.assertIn(code, result.reason_codes)
        result, _ = self.analyze(holding(peak_r=10), quote(current_price=105))
        self.assertFalse(any(reason.startswith("target_") for reason in result.reason_codes))

    def test_invalid_inputs_and_timestamp_contract(self) -> None:
        for changes in ({"shares": True}, {"shares": 1.5}, {"shares": 0},
                        {"initial_stop": 100}, {"entry_price": float("inf")},
                        {"peak_r": -1}, {"trailing_stop": 97}, {"market": "xx"},
                        {"trailing_ema": 9.0}, {"symbol": "../secret"}):
            with self.subTest(changes=changes), self.assertRaises(PortfolioError):
                holding(**changes)
        for changes in ({"current_price": float("nan")}, {"ema9": 0},
                        {"last_close": -1}, {"close_confirmed": True, "close_timestamp": None},
                        {"quote_timestamp": datetime(2026, 10, 13)},
                        {"close_timestamp": datetime(2026, 10, 14, tzinfo=timezone.utc)}):
            with self.subTest(changes=changes), self.assertRaises(PortfolioError):
                quote(**changes)
        with self.assertRaises(PortfolioError):
            self.analyze(equity=0)
        with self.assertRaises(PortfolioError):
            self.analyze(snapshot=quote(symbol="AMD"))

    def test_below_ema50_is_severe_even_when_above_ema9(self) -> None:
        result, _ = self.analyze(snapshot=quote(current_price=103, ema9=100, ema21=102, ema50=105,
                                               close_confirmed=False))
        self.assertEqual(result.health, "severely_weak")


class TrackerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "positions.json"
        self.tracker = PortfolioTracker(self.path)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_crud_and_reload_observed_breakeven(self) -> None:
        self.tracker.add(holding())
        diagnoses, errors = self.tracker.diagnose({"NVDA": quote(current_price=104)}, 100_000, "us")
        self.assertEqual(errors, {})
        self.assertEqual(diagnoses[0].current_r, 2)
        reloaded = PortfolioTracker(self.path)
        position = reloaded.list_positions()[0]
        self.assertEqual(position.peak_r, 2)
        self.assertEqual(position.trailing_stop, 100)
        self.assertEqual(position.initial_stop, 98)
        edited = reloaded.update(replace(position, name="Edited", shares=90, peak_r=0, trailing_stop=98))
        self.assertEqual(edited.peak_r, 2)
        self.assertEqual(edited.trailing_stop, 100)
        reloaded.delete("one")
        self.assertEqual(PortfolioTracker(self.path).list_positions(), [])

    def test_intentional_trade_basis_edit_resets_observations(self) -> None:
        self.tracker.add(holding(peak_r=5, trailing_stop=100))
        edited = self.tracker.update(holding(entry_price=120, initial_stop=118, peak_r=5, trailing_stop=118))
        self.assertEqual(edited.peak_r, 0)
        self.assertEqual(edited.trailing_stop, 118)
        self.assertEqual(edited.initial_stop, 118)

    def test_corrupt_storage_fails_without_overwriting(self) -> None:
        self.path.write_text('{"schema_version":1,"positions":[{"bad":true}]}', encoding="utf-8")
        before = self.path.read_bytes()
        with self.assertRaises(PortfolioStorageError):
            PortfolioTracker(self.path)
        self.assertEqual(self.path.read_bytes(), before)

    def test_failed_atomic_write_keeps_previous_state(self) -> None:
        self.tracker.add(holding())
        with patch("backend.engine.portfolio_tracker._atomic_text", side_effect=OSError("read-only")):
            with self.assertRaises(PortfolioStorageError):
                self.tracker.delete("one")
        self.assertEqual(len(self.tracker.list_positions()), 1)

    def test_missing_quote_retains_position_with_explicit_error(self) -> None:
        self.tracker.add(holding())
        diagnoses, errors = self.tracker.diagnose({}, 100_000, "us")
        self.assertEqual(diagnoses, [])
        self.assertIn("one", errors)
        self.assertEqual(self.tracker.list_positions()[0].peak_r, 0)

    def test_duplicate_id_and_cross_currency_rejected(self) -> None:
        self.tracker.add(holding())
        with self.assertRaises(PortfolioError):
            self.tracker.add(holding())
        with self.assertRaises(PortfolioError):
            PortfolioAnalyzer().analyze([holding()], {"NVDA": quote()}, 1_000_000, "tw")
        with self.assertRaises(PortfolioError):
            self.tracker.add(holding(id="second"))
        with self.assertRaises(PortfolioError):
            PortfolioAnalyzer().analyze([holding(), holding(id="second")], {"NVDA": quote()}, 100_000, "us")


class InlineClient:
    def __init__(self, app) -> None:
        self.app = app

    def request(self, method: str, path: str, **kwargs) -> httpx.Response:
        async def worker(function, *args, **kw):
            return function(*args, **kw)

        async def call():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),
                                         base_url="http://test") as client:
                return await client.request(method, path, **kwargs)
        with patch("backend.api.to_thread", side_effect=worker):
            return asyncio.run(call())


class PortfolioApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        settings = ApiSettings(cache_dir=Path(self.temp.name))
        self.quotes = QuoteService(settings, now=lambda: NOW)
        self.client = InlineClient(create_app(RecommendationService(settings, now=lambda: NOW), self.quotes))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_quote_demo_contract_and_unsupported_symbol_error(self) -> None:
        response = self.client.request("GET", "/v1/quotes", params={"market": "us", "symbols": "NVDA,ZZZZ", "demo": True})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertEqual(result["quotes"][0]["symbol"], "NVDA")
        self.assertTrue(result["source"].startswith("mock"))
        self.assertTrue(result["quotes"][0]["close_confirmed"])
        self.assertIsNotNone(datetime.fromisoformat(result["quotes"][0]["quote_timestamp"].replace("Z", "+00:00")).tzinfo)
        self.assertIn("ZZZZ", result["errors"])

    def test_quote_validation_market_duplicates_and_path_injection(self) -> None:
        for symbols, market in (("../secret", "us"), ("NVDA,NVDA", "us"), ("2330", "tw"),
                                ("NVDA", "tw"), ("", "us"), (",".join(f"X{i}" for i in range(51)), "us")):
            response = self.client.request("GET", "/v1/quotes", params={"market": market, "symbols": symbols, "demo": True})
            self.assertEqual(response.status_code, 422)

    def test_live_provider_failure_never_turns_into_demo(self) -> None:
        with patch.object(self.quotes, "_fetch_live", side_effect=DataSourceError("quote provider offline")):
            response = self.client.request("GET", "/v1/quotes", params={"market": "us", "symbols": "NVDA"})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], "quote provider offline")

    def test_analyze_returns_state_and_stable_initial_stop(self) -> None:
        position = holding(entry_price=150, initial_stop=147).to_dict()
        response = self.client.request("POST", "/v1/portfolio/analyze",
                                       json={"market": "us", "account_equity": 50_000,
                                             "positions": [position], "demo": True})
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(result["diagnostics"][0]["current_r"], 3)
        self.assertEqual(result["updated_positions"][0]["trailing_stop"], 150)
        self.assertEqual(result["updated_positions"][0]["initial_stop"], 147)
        self.assertEqual(result["diagnostics"][0]["action"], "trim")

    def test_post_strict_shares_and_cross_market(self) -> None:
        for value in (True, 2.2, "100"):
            position = holding().to_dict()
            position["shares"] = value
            response = self.client.request("POST", "/v1/portfolio/analyze", json={
                "market": "us", "account_equity": 50_000, "positions": [position], "demo": True})
            self.assertEqual(response.status_code, 422)
        response = self.client.request("POST", "/v1/portfolio/analyze", json={
            "market": "tw", "account_equity": 1_000_000, "positions": [holding().to_dict()], "demo": True})
        self.assertEqual(response.status_code, 422)

    def test_cache_preserves_quote_time_and_returns_copy(self) -> None:
        first = self.quotes.get_quotes(Market.US, ["NVDA"], demo=True)
        timestamp = first.quotes[0].quote_timestamp
        first.quotes.clear()
        second = self.quotes.get_quotes(Market.US, ["NVDA"], demo=True)
        self.assertEqual(second.quotes[0].quote_timestamp, timestamp)
        self.assertEqual(second.generated_at, NOW)

    def test_empty_portfolio_no_provider(self) -> None:
        with patch.object(self.quotes, "get_quotes", side_effect=AssertionError("not called")):
            response = self.client.request("POST", "/v1/portfolio/analyze", json={
                "market": "us", "account_equity": 50_000, "positions": [], "demo": False})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["diagnostics"], [])


class FakeCalendar:
    def __init__(self, phase: str = "premarket") -> None:
        self.phase = phase

    def context(self, market, now):
        return EvaluationContext(pd.Timestamp(now), market, pd.Timestamp("2026-10-13"),
                                 pd.Timestamp("2026-10-12"), self.phase,
                                 pd.Timestamp("2026-10-13T12:00:00Z"),
                                 pd.Timestamp("2026-10-13T20:00:00Z"),
                                 pd.Timestamp("2026-10-12"), "injected")

    def _calendar(self, market, year):
        return self

    def session_close(self, date):
        return pd.Timestamp(date).tz_localize("UTC") + pd.Timedelta(hours=20)


class QuoteLoader:
    def __init__(self, item):
        self.item = item
        self.errors = {}

    def load(self, stocks, as_of, **kwargs):
        return {"NVDA": self.item}


class QuoteProviderTests(unittest.TestCase):
    def data(self, *, partial: bool = False, minute: bool = True, stale: bool = False):
        index = pd.bdate_range(end="2026-10-12", periods=100)
        closes = [100 + i * 0.1 for i in range(100)]
        daily = pd.DataFrame({"open": closes, "high": [value + 1 for value in closes],
                              "low": [value - 1 for value in closes], "close": closes,
                              "volume": [1_000_000] * len(closes)}, index=index)
        if partial:
            daily.loc[pd.Timestamp("2026-10-13")] = [500, 501, 499, 500, 100]
        intraday = pd.DataFrame({"open": [111], "high": [112], "low": [110],
                                 "close": [111], "volume": [1000]},
                                index=pd.DatetimeIndex(["2026-10-13T12:40:00Z"]))
        if not minute:
            intraday = intraday.iloc[:0]
        return MarketData(Stock("NVDA", "NVIDIA test", "Tech", Market.US), daily,
                          intraday, pd.Timestamp(NOW), stale)

    def service(self, item, phase="premarket"):
        loader = QuoteLoader(item)
        return QuoteService(ApiSettings(), now=lambda: NOW,
                            loader_factory=lambda *args, **kwargs: loader,
                            calendar=FakeCalendar(phase))

    def test_partial_today_daily_is_excluded_from_ema_and_close(self) -> None:
        source = self.data(partial=True)
        response = self.service(source).get_quotes(Market.US, ["NVDA"])
        self.assertEqual(response.errors, {})
        snapshot = response.quotes[0]
        self.assertEqual(snapshot.last_close, 109.9)
        self.assertEqual(snapshot.current_price, 111)
        self.assertLess(snapshot.ema9, 110)
        self.assertTrue(snapshot.close_confirmed)
        self.assertEqual(snapshot.close_timestamp, CLOSED)
        self.assertEqual(snapshot.quote_timestamp, datetime(2026, 10, 13, 12, 40, tzinfo=timezone.utc))

    def test_intraday_without_fresh_minute_is_explicit_error(self) -> None:
        response = self.service(self.data(minute=False), "intraday").get_quotes(Market.US, ["NVDA"])
        self.assertEqual(response.quotes, [])
        self.assertIn("15 分鐘", response.errors["NVDA"])

    def test_completed_daily_fallback_after_hours_discloses_source(self) -> None:
        response = self.service(self.data(minute=False)).get_quotes(Market.US, ["NVDA"])
        snapshot = response.quotes[0]
        self.assertEqual(snapshot.current_price, 109.9)
        self.assertEqual(snapshot.quote_timestamp, CLOSED)
        self.assertIn("completed daily close only", snapshot.source)

    def test_stale_data_is_not_diagnosed(self) -> None:
        response = self.service(self.data(stale=True)).get_quotes(Market.US, ["NVDA"])
        self.assertEqual(response.quotes, [])
        self.assertIn("過期", response.errors["NVDA"])


if __name__ == "__main__":
    unittest.main()
