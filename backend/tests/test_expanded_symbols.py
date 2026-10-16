"""Offline contract tests for TWSE/TPEx security identifiers and holdings.

These are explicitly injected fixtures, never live scan evidence or suggestions.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from backend.engine.exit_engine import PortfolioError, Position, QuoteSnapshot, validate_symbol
from backend.engine.models import Market
from backend.engine.portfolio_tracker import PortfolioAnalyzer, PortfolioTracker


class ExpandedSymbolTests(unittest.TestCase):
    def test_taiwan_exchange_suffixes_remain_distinct(self) -> None:
        for symbol in ("2330.TW", "6488.TWO", "3529.TWO"):
            with self.subTest(symbol=symbol):
                self.assertEqual(validate_symbol(symbol, Market.TW), symbol)
        self.assertEqual(validate_symbol("BRK-B", Market.US), "BRK-B")
        self.assertEqual(validate_symbol("NVDA", Market.US), "NVDA")

    def test_unknown_suffixes_and_injection_are_rejected(self) -> None:
        for symbol in ("6488", "6488.OTC", "6488.TWO.TW", "12345.TWO",
                       "6488.TWO?x=1", "../6488.TWO", "6488.TWO/secret",
                       "6488.two", "NVDA", "^TWII"):
            with self.subTest(symbol=symbol), self.assertRaises(PortfolioError):
                validate_symbol(symbol, Market.TW)
        for symbol in ("6488.TWO", "2330.TW", "NVDA.TWO", "NVDA?x=1"):
            with self.subTest(symbol=symbol), self.assertRaises(PortfolioError):
                validate_symbol(symbol, Market.US)

    def test_tpex_holding_persists_and_analyzes_in_twd(self) -> None:
        position = Position("tpex", "6488.TWO", Market.TW, 100, 100, 98,
                            name="測試公司")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "holdings.json"
            tracker = PortfolioTracker(path)
            tracker.add(position)
            saved = PortfolioTracker(path).list_positions(Market.TW)
        self.assertEqual(saved[0].symbol, "6488.TWO")
        now = datetime(2026, 10, 15, 5, 31, tzinfo=timezone.utc)
        close = datetime(2026, 10, 15, 5, 30, tzinfo=timezone.utc)
        quote = QuoteSnapshot(
            "6488.TWO", "測試公司", Market.TW, 106, 103, 101, 99,
            105, True, now, close, "injected unit test quote", False,
        )
        diagnoses, updated, errors = PortfolioAnalyzer().analyze(
            saved, {quote.symbol: quote}, 1_000_000, Market.TW)
        self.assertEqual(errors, {})
        self.assertEqual(diagnoses[0].current_r, 3)
        self.assertEqual(diagnoses[0].action, "trim")
        self.assertEqual(updated[0].trailing_stop, 100)
        self.assertEqual(diagnoses[0].targets["5"], 110)


if __name__ == "__main__":
    unittest.main()
