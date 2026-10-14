"""Observed breakout boundaries remain separate from their confirmation closes."""
from __future__ import annotations

from dataclasses import replace
import unittest
from unittest.mock import patch

import pandas as pd

from backend.engine.models import EvaluationContext, Market, MarketData, Stock
from backend.engine.scanners import MomentumScanner, ScannerConfig, _Screened


class EntryPointTests(unittest.TestCase):
    def setUp(self) -> None:
        opening = pd.Timestamp("2026-10-13T13:30:00Z")
        self.context = EvaluationContext(
            as_of=opening + pd.Timedelta(minutes=3), market=Market.US,
            session_date=pd.Timestamp("2026-10-13"), previous_session=pd.Timestamp("2026-10-12"),
            phase="intraday", session_open=opening, session_close=opening + pd.Timedelta(hours=6, minutes=30),
            latest_completed_session=pd.Timestamp("2026-10-12"), calendar_source="test",
        )
        self.daily = pd.DataFrame(
            {"open": [99.0], "high": [100.0], "low": [98.0], "close": [99.5], "volume": [1000]},
            index=pd.DatetimeIndex(["2026-10-12"]),
        )
        self.bars = pd.DataFrame(
            {"open": [99.5, 99.8, 101.0], "high": [100.3, 101.3, 102.0],
             "low": [99.1, 99.5, 100.8], "close": [99.8, 101.0, 101.5], "volume": [100, 400, 300]},
            index=pd.date_range(opening + pd.Timedelta(minutes=1), periods=3, freq="min"),
        )
        self.bars.attrs["interval_minutes"] = 1
        stock = Stock("TEST", "Test", "Technology", Market.US)
        data = MarketData(stock, self.daily, self.bars, self.context.as_of)
        self.screened = _Screened(data, self.daily, 6)

    def test_pdh_threshold_is_prior_high_not_confirmation_close(self) -> None:
        scanner = MomentumScanner()
        with patch.object(scanner, "_base_patterns", return_value=("均線收斂", "內包日")), \
                patch.object(scanner, "_intraday", return_value=self.bars):
            entry, _, _ = scanner._entry(self.screened, self.context, gap_candidate=False)
        self.assertIsNotNone(entry)
        self.assertEqual(entry.entry_price, 100)
        self.assertEqual(entry.confirmation_price, 101)
        self.assertEqual(entry.trigger_type, "PDH")
        self.assertEqual(entry.day_low, 99.1)
        self.assertEqual(entry.entry_bar_low, 99.5)

    def test_orh_threshold_is_first_completed_opening_high(self) -> None:
        scanner = MomentumScanner(ScannerConfig(or_minutes=1))
        with patch.object(scanner, "_base_patterns", return_value=()), \
                patch.object(scanner, "_intraday", return_value=self.bars):
            entry, _, _ = scanner._entry(self.screened, self.context, gap_candidate=True)
        self.assertIsNotNone(entry)
        self.assertEqual(entry.entry_price, 100.3)
        self.assertEqual(entry.confirmation_price, 101)
        self.assertEqual(entry.trigger_type, "ORH")

    def test_equality_does_not_confirm_an_upward_breakout(self) -> None:
        bars = self.bars.copy()
        bars["close"] = [99.8, 100.0, 100.0]
        scanner = MomentumScanner()
        with patch.object(scanner, "_base_patterns", return_value=("均線收斂", "內包日")), \
                patch.object(scanner, "_intraday", return_value=bars):
            entry, _, _ = scanner._entry(self.screened, self.context, gap_candidate=False)
        self.assertIsNone(entry)

    def test_daily_confirmation_never_invents_a_minute_bar_stop(self) -> None:
        today = pd.DataFrame(
            {"open": [99.5], "high": [102.0], "low": [94.0], "close": [101.0], "volume": [5000]},
            index=pd.DatetimeIndex(["2026-10-13"]),
        )
        daily = pd.concat([self.daily, today])
        screened = replace(self.screened, daily=daily)
        context = replace(self.context, phase="postmarket", as_of=self.context.session_close,
                          latest_completed_session=pd.Timestamp("2026-10-13"))
        scanner = MomentumScanner()
        with patch.object(scanner, "_base_patterns", return_value=("均線收斂", "內包日")), \
                patch.object(scanner, "_intraday", return_value=pd.DataFrame()):
            entry, _, _ = scanner._entry(screened, context, gap_candidate=False)
        self.assertEqual(entry.entry_price, 100)
        self.assertEqual(entry.confirmation_price, 101)
        self.assertIsNone(entry.entry_bar_low)


if __name__ == "__main__":
    unittest.main()
