"""雙市場共用資料模型。比例欄位以名稱標明小數或百分比單位。"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import pandas as pd


class StrategyError(ValueError):
    """可辨識的策略／資料／風險錯誤。"""


class DataValidationError(StrategyError):
    pass


class InsufficientDataError(DataValidationError):
    pass


class RiskError(StrategyError):
    pass


class Market(str, Enum):
    US = "us"
    TW = "tw"


@dataclass(frozen=True)
class MarketSettings:
    market: Market
    timezone: str
    currency: str
    calendar: str
    benchmark: str
    adr_threshold: float


def market_settings(market: Market) -> MarketSettings:
    market = Market(market)
    if market is Market.US:
        return MarketSettings(market, "America/New_York", "USD", "XNYS", "^GSPC", 5.0)
    return MarketSettings(market, "Asia/Taipei", "TWD", "XTAI", "^TWII", 3.5)


@dataclass(frozen=True)
class Stock:
    symbol: str
    name: str
    sector: str
    market: Market
    large_liquid: bool = False


@dataclass(frozen=True)
class MarketData:
    stock: Stock
    daily: pd.DataFrame
    intraday: pd.DataFrame
    fetched_at: pd.Timestamp
    is_stale: bool = False
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True)
class EvaluationContext:
    as_of: pd.Timestamp
    market: Market
    session_date: pd.Timestamp
    previous_session: pd.Timestamp
    phase: str
    session_open: pd.Timestamp
    session_close: pd.Timestamp
    latest_completed_session: pd.Timestamp
    calendar_source: str


@dataclass(frozen=True)
class Candidate:
    stock: Stock
    adr_pct: float
    rs20: float
    rs60: float
    momentum_score: float
    rs_rank: int
    rs_percentile: float
    scanners: tuple[str, ...]
    patterns: tuple[str, ...]
    status: str
    entry_price: float
    day_low: float | None
    entry_bar_low: float | None
    signal_time: pd.Timestamp | None
    data_time: pd.Timestamp
    notes: tuple[str, ...] = ()
    # Exact observed PDH / ORH boundary, separate from confirmation-bar close.
    trigger_price: float | None = None
    trigger_type: str | None = None
    confirmation_price: float | None = None


@dataclass(frozen=True)
class RiskPlan:
    entry_price: float
    stop_price: float
    shares: int
    amount: float
    position_pct: float
    risk_amount: float
    risk_budget: float
    sl_pct: float
    risk_per_share: float
    stop_source: str
    lot_size: int


@dataclass(frozen=True)
class Recommendation:
    candidate: Candidate
    risk: RiskPlan | None
    risk_note: str = ""


@dataclass(frozen=True)
class ReportMetadata:
    context: EvaluationContext
    capital: float
    currency: str
    universe_count: int
    loaded_count: int
    evaluated_count: int
    warnings: tuple[str, ...] = ()
    errors: tuple[str, ...] = ()
    universe_source: str = ""
    demo: bool = False
