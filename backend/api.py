"""FastAPI adapter for Taiwan listed/OTC and US exchange stock universes.

Run from the project root: ``python -m uvicorn backend.api:app --host 0.0.0.0``.
Financial-provider calls run in a worker thread; failures never switch to mock
data. An explicit ``demo=true`` query is the only server-side demo mode.
"""
from __future__ import annotations

from asyncio import to_thread
from concurrent.futures import ThreadPoolExecutor, as_completed
import inspect
import logging
from math import isfinite
import os
import threading
import time
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Literal

import pandas as pd
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, model_validator

from .engine.data_loader import DataSourceError, MarketDataLoader, UniverseProvider, _atomic_text
from .engine.market_calendar import CalendarError, ExchangeSessionCalendar, NonTradingDayError
from .engine.models import Candidate, Market, MarketData, RiskError, Stock, market_settings
from .engine.risk_engine import RiskEngine
from .engine.scanners import MomentumScanner, ScannerConfig, ScannerError
from .engine.exit_engine import (ExitConfig, PortfolioError, Position, QuoteSnapshot, validate_symbol)
from .engine.portfolio_tracker import PortfolioAnalyzer, demo_quote
from .scan_jobs import BackgroundScanManager, Progress, RollingScanCheckpoint

LOGGER = logging.getLogger(__name__)
MarketCode = Literal["tw", "us"]


class ScanCapabilities(BaseModel):
    """Configured scan scope, not evidence that any market data was fetched."""

    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)
    pool_limit: int = Field(ge=0)
    scope: Literal["full_universe", "limited"]
    page_size: int = Field(ge=1, le=100)
    page_interval_seconds: float = Field(gt=0)
    background_jobs: Literal[True] = True
    continuation: Literal["client_driven"] = "client_driven"
    recommendations: Literal["latest_page_only"] = "latest_page_only"

    @model_validator(mode="after")
    def validate_scope(self) -> ScanCapabilities:
        expected = "full_universe" if self.pool_limit == 0 else "limited"
        if self.scope != expected:
            raise ValueError("掃描範圍必須符合實際股票池上限。")
        return self


class CapabilitiesResponse(BaseModel):
    """Cheap deployment handshake; a separate live request verifies providers.

    ``data_mode`` identifies the default production protocol. An explicit
    ``demo=true`` remains available on the existing demonstration endpoints.
    No provider availability or complete universe coverage is claimed here.
    """

    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)
    service: Literal["martin-luk-market-api"] = "martin-luk-market-api"
    api_version: Literal[1] = 1
    data_mode: Literal["live"] = "live"
    markets: list[MarketCode]
    scan: ScanCapabilities
    requires_market_data_verification: Literal[True] = True


class CandidateResponse(BaseModel):
    """JSON-safe prices are in the market's native currency (TWD or USD)."""

    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    symbol: str
    name: str
    sector: str
    market: MarketCode
    adr_percent: float = Field(ge=0)
    rs_score: float = Field(ge=0, le=100)
    rs_rank: int = Field(ge=1)
    patterns: list[str]
    entry_price: float = Field(gt=0)
    trigger_price: float | None = Field(default=None, gt=0)
    trigger_type: Literal["PDH", "ORH"] | None = None
    confirmation_price: float | None = Field(default=None, gt=0)
    day_low: float | None = Field(default=None, gt=0)
    entry_bar_low: float | None = Field(default=None, gt=0)
    stop_price: float | None = Field(default=None, gt=0)
    stop_source: Literal["day_low", "entry_bar_low"] | None = None
    risk_per_share: float | None = Field(default=None, gt=0)
    is_large_liquid: bool
    status: Literal["confirmed", "watchlist"]
    data_timestamp: datetime
    signal_timestamp: datetime | None = None
    notes: list[str] = Field(default_factory=list)
    daily_closes: list[float] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_execution_fields(self) -> CandidateResponse:
        """Reject malformed provider/cache records before the phone sees them."""
        if self.data_timestamp.tzinfo is None or (
            self.signal_timestamp is not None and self.signal_timestamp.tzinfo is None
        ):
            raise ValueError("K 棒與訊號時間必須含時區。")
        if self.status == "confirmed":
            if self.stop_price is None or self.signal_timestamp is None:
                raise ValueError("Confirmed 訊號必須具有停損與訊號時間。")
            distance = (self.entry_price - self.stop_price) / self.entry_price * 100
            if not 0 < distance <= 5.0 + 1e-10:
                raise ValueError("Confirmed 停損距離必須大於零且不超過 5%。")
            if self.stop_source == "entry_bar_low" and not 1.5 - 1e-10 <= distance <= 3.0 + 1e-10:
                raise ValueError("進場 K 棒緊密停損必須在 1.5%～3%。")
            if self.stop_source == "day_low" and (self.day_low is None or self.day_low != self.stop_price):
                raise ValueError("當日低點停損必須保留實際 day_low。")
            if self.stop_source == "entry_bar_low":
                if (self.day_low is None or self.entry_bar_low != self.stop_price or
                        self.entry_bar_low < self.day_low or
                        (self.entry_price - self.day_low) / self.entry_price * 100 <= 5):
                    raise ValueError("緊密停損須來自超過 5% 當日風險時的實際進場 K 棒低點。")
            if self.trigger_price is not None and self.trigger_price != self.entry_price:
                raise ValueError("entry_price 必須等於明確 PDH/ORH trigger_price。")
            if self.risk_per_share is not None and abs(self.risk_per_share - (self.entry_price - self.stop_price)) > 1e-8:
                raise ValueError("1R 必須等於進場價減初始停損。")
        elif self.stop_price is not None:
            raise ValueError("觀察名單不得提供可執行停損。")
        if any(value <= 0 or not isfinite(value) for value in self.daily_closes):
            raise ValueError("歷史收盤價必須為有限正數。")
        return self


class CandidatesResponse(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    market: MarketCode
    generated_at: datetime
    source: str
    universe_count: int = Field(ge=0)
    stale: bool
    warnings: list[str] = Field(default_factory=list)
    candidates: list[CandidateResponse]
    evaluated_count: int | None = Field(default=None, ge=0)
    scan_pool_size: int | None = Field(default=None, ge=0)
    adr_match_count: int | None = Field(default=None, ge=0)
    universe_is_complete: bool | None = None
    universe_as_of: datetime | None = None
    scan_completed_at: datetime | None = None
    missing_symbols: list[str] = Field(default_factory=list)
    # Coverage is cumulative *attempts*, including failed symbols, for one
    # universe/threshold round. Evaluated count remains a separate lower bound.
    coverage_total_count: int | None = Field(default=None, ge=0)
    coverage_scanned_count: int | None = Field(default=None, ge=0)
    coverage_evaluated_count: int | None = Field(default=None, ge=0)
    coverage_remaining_count: int | None = Field(default=None, ge=0)
    coverage_round: int | None = Field(default=None, ge=1)
    scan_page_start: int | None = Field(default=None, ge=0)
    scan_page_size: int | None = Field(default=None, ge=0)
    universe_fingerprint: str | None = None

    @model_validator(mode="after")
    def validate_response_time(self) -> CandidatesResponse:
        if self.generated_at.tzinfo is None:
            raise ValueError("評估時間必須含時區。")
        if any(value is not None and value.tzinfo is None
               for value in (self.universe_as_of, self.scan_completed_at)):
            raise ValueError("股票池與掃描完成時間必須含時區。")
        if any(candidate.market != self.market for candidate in self.candidates):
            raise ValueError("推薦與回應市場識別不一致。")
        coverage_values = (
            self.coverage_total_count, self.coverage_scanned_count, self.coverage_evaluated_count,
            self.coverage_remaining_count, self.coverage_round, self.scan_page_start,
            self.scan_page_size, self.universe_fingerprint,
        )
        if any(value is not None for value in coverage_values):
            if any(value is None for value in coverage_values) or not self.universe_fingerprint:
                raise ValueError("輪掃中繼資料必須完整提供。")
            scanned, remaining = self.coverage_scanned_count, self.coverage_remaining_count
            if (scanned is None or remaining is None or
                    scanned + remaining != self.coverage_total_count or
                    self.coverage_total_count > self.universe_count or
                    (self.coverage_evaluated_count or 0) > scanned):
                raise ValueError("輪掃累積計數不一致。")
            if (self.scan_page_size is None or self.scan_pool_size != self.scan_page_size or
                    self.scan_page_start + self.scan_page_size > self.coverage_total_count or
                    self.scan_page_start > scanned or
                    (self.evaluated_count or 0) > self.scan_page_size or
                    (self.adr_match_count or 0) > (self.evaluated_count or 0)):
                raise ValueError("當頁掃描計數不一致。")
        return self


class QuoteResponse(BaseModel):
    """共用 Flutter/HTML 報價格式；時間戳保留真正的 K 棒時間。"""

    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)
    symbol: str
    name: str
    market: MarketCode
    current_price: float = Field(gt=0)
    ema9: float = Field(gt=0)
    ema21: float = Field(gt=0)
    ema50: float = Field(gt=0)
    last_close: float | None
    close_confirmed: bool
    quote_timestamp: datetime
    close_timestamp: datetime | None
    source: str
    is_large_liquid: bool

    @model_validator(mode="after")
    def validate_quote(self) -> QuoteResponse:
        QuoteSnapshot(**self.model_dump())
        return self

    def snapshot(self) -> QuoteSnapshot:
        return QuoteSnapshot(**self.model_dump())


class QuotesResponse(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    market: MarketCode
    generated_at: datetime
    source: str
    quotes: list[QuoteResponse]
    errors: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_market(self) -> QuotesResponse:
        if self.generated_at.tzinfo is None:
            raise ValueError("報價回應時間必須含時區。")
        if any(quote.market != self.market for quote in self.quotes):
            raise ValueError("報價市場不一致。")
        if len({quote.symbol for quote in self.quotes}) != len(self.quotes):
            raise ValueError("報價代碼不可重複。")
        return self


class PositionRequest(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)
    id: str
    symbol: str
    market: MarketCode
    entry_price: float = Field(gt=0)
    shares: StrictInt = Field(gt=0, le=2**53 - 1)
    initial_stop: float = Field(gt=0)
    peak_r: float = Field(default=0.0, ge=0)
    trailing_stop: float | None = Field(default=None, gt=0)
    trailing_ema: Literal[9, 21, 50] = 9
    main_uptrend: StrictBool = False
    name: str = ""

    @model_validator(mode="after")
    def validate_position(self) -> PositionRequest:
        Position(**self.model_dump())
        return self


class AnalyzePortfolioRequest(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)
    market: MarketCode
    account_equity: float = Field(gt=0)
    positions: list[PositionRequest] = Field(max_length=50)
    euphoria_percent: float = Field(default=20.0, ge=15, le=20)
    demo: StrictBool = False
    force_refresh: StrictBool = False

    @model_validator(mode="after")
    def validate_positions(self) -> AnalyzePortfolioRequest:
        if any(position.market != self.market for position in self.positions):
            raise ValueError("市場帳戶不可混合 USD/TWD 持股。")
        if len({position.id for position in self.positions}) != len(self.positions):
            raise ValueError("持股 id 不可重複。")
        if len({(position.market, position.symbol) for position in self.positions}) != len(self.positions):
            raise ValueError("同市場股票只可建立一筆合併持股。")
        return self


@dataclass(frozen=True)
class ApiSettings:
    """Runtime limits keep a failed provider from spawning unlimited fetches."""

    cache_dir: Path = Path(".cache/martin_luk")
    response_ttl_seconds: float = 300
    provider_timeout_seconds: float = 8
    provider_retries: int = 1
    fetch_workers: int = 4
    result_limit: int = 50
    large_liquid_symbols: frozenset[str] = frozenset()
    scan_pool_limit: int = 0
    scan_page_size: int = 60
    scan_page_interval_seconds: float = 60
    scan_batch_size: int = 3
    scan_batch_delay_seconds: float = 0.15
    scan_timeout_seconds: float = 180
    scan_failure_cooldown_seconds: float = 30

    def __post_init__(self) -> None:
        if (not isfinite(self.response_ttl_seconds) or not isfinite(self.provider_timeout_seconds)
                or self.response_ttl_seconds <= 0 or self.provider_timeout_seconds <= 0):
            raise ValueError("Cache TTL 與 provider timeout 必須為正數。")
        if min(self.provider_retries, self.fetch_workers, self.result_limit) < 1:
            raise ValueError("Retries、workers 與 result limit 必須為正整數。")
        if self.scan_pool_limit < 0 or not 3 <= self.scan_batch_size <= 5:
            raise ValueError("掃描池上限不得小於零，批次必須為 3～5 檔。")
        if not 1 <= self.scan_page_size <= 100:
            raise ValueError("輪掃每頁必須為 1～100 檔。")
        if not isfinite(self.scan_page_interval_seconds) or self.scan_page_interval_seconds <= 0:
            raise ValueError("輪掃頁面間隔須為正數。")
        if (not isfinite(self.scan_batch_delay_seconds) or self.scan_batch_delay_seconds < 0.15
                or not isfinite(self.scan_timeout_seconds) or self.scan_timeout_seconds <= 0
                or not isfinite(self.scan_failure_cooldown_seconds) or self.scan_failure_cooldown_seconds < 0):
            raise ValueError("批次間隔至少 150ms、掃描逾時須為正數，失敗冷卻不得小於零。")

    @classmethod
    def from_environment(cls) -> ApiSettings:
        return cls(
            cache_dir=Path(os.getenv("MARTIN_CACHE_DIR", ".cache/martin_luk")),
            response_ttl_seconds=float(os.getenv("MARTIN_RESPONSE_TTL", "300")),
            provider_timeout_seconds=float(os.getenv("MARTIN_PROVIDER_TIMEOUT", "8")),
            provider_retries=int(os.getenv("MARTIN_PROVIDER_RETRIES", "1")),
            fetch_workers=int(os.getenv("MARTIN_FETCH_WORKERS", "4")),
            result_limit=int(os.getenv("MARTIN_RESULT_LIMIT", "50")),
            scan_pool_limit=int(os.getenv("MARTIN_SCAN_POOL_LIMIT", "0")),
            scan_page_size=int(os.getenv("MARTIN_SCAN_PAGE_SIZE", "60")),
            scan_page_interval_seconds=float(os.getenv("MARTIN_SCAN_PAGE_INTERVAL", "60")),
            scan_batch_size=int(os.getenv("MARTIN_SCAN_BATCH_SIZE", "3")),
            scan_batch_delay_seconds=float(os.getenv("MARTIN_SCAN_BATCH_DELAY", "0.15")),
            scan_timeout_seconds=float(os.getenv("MARTIN_SCAN_TIMEOUT", "180")),
            scan_failure_cooldown_seconds=float(os.getenv("MARTIN_SCAN_FAILURE_COOLDOWN", "30")),
            large_liquid_symbols=frozenset(
                symbol.strip() for symbol in os.getenv("LARGE_LIQUID_SYMBOLS", "").split(",")
                if symbol.strip()
            ),
        )


def _utc_datetime(timestamp: pd.Timestamp, market: Market) -> datetime:
    """Daily session labels become local midnight, never ambiguous UTC dates."""
    value = pd.Timestamp(timestamp)
    if value.tzinfo is None:
        value = value.tz_localize(market_settings(market).timezone)
    return value.tz_convert("UTC").to_pydatetime()


def serialize_candidate(candidate: Candidate, data: MarketData | None = None) -> CandidateResponse:
    """Expose actual trigger/confirmation prices and observed stop provenance.

    Day-low distance up to 5% is allowed. Only a wider day-low requires an
    observed 1/5-minute entry-bar stop in the 1.5%–3% interval.
    """
    status = candidate.status
    stop: float | None = None
    stop_source: str | None = None
    risk_per_share: float | None = None
    notes = list(candidate.notes)
    if pd.Timestamp(candidate.data_time).tzinfo is None:
        notes.append("data_timestamp 為日K交易日期的市場當地午夜，並非盤中報價或抓取時間。")
    if status == "confirmed":
        capital = 50_000.0 if candidate.stock.market is Market.US else 1_000_000.0
        try:
            plan = RiskEngine(capital).plan(candidate)
            stop = plan.stop_price
            stop_source = plan.stop_source
            risk_per_share = plan.risk_per_share
            notes.append(f"實際停損來源：{plan.stop_source}；名目單筆風險上限 0.5%。")
        except RiskError as exc:
            status = "watchlist"
            notes.append(str(exc))
    closes = [] if data is None else [float(value) for value in data.daily["close"].tail(60)]
    return CandidateResponse(
        symbol=candidate.stock.symbol, name=candidate.stock.name,
        sector=candidate.stock.sector, market=candidate.stock.market.value,
        adr_percent=round(candidate.adr_pct, 5), rs_score=round(candidate.rs_percentile, 5),
        rs_rank=candidate.rs_rank, patterns=list(candidate.patterns),
        entry_price=candidate.entry_price,
        trigger_price=candidate.trigger_price or candidate.entry_price,
        trigger_type=candidate.trigger_type,
        confirmation_price=candidate.confirmation_price,
        day_low=candidate.day_low, entry_bar_low=candidate.entry_bar_low,
        stop_price=stop, stop_source=stop_source, risk_per_share=risk_per_share,
        is_large_liquid=candidate.stock.large_liquid, status=status,
        data_timestamp=_utc_datetime(candidate.data_time, candidate.stock.market),
        signal_timestamp=(None if candidate.signal_time is None else
                          _utc_datetime(candidate.signal_time, candidate.stock.market)),
        notes=notes, daily_closes=closes,
    )


class QuoteService:
    """少量持股報價，不必重掃整個股票池；5 分鐘記憶體及 provider 快取。

    每個市場同時只抓取一次；不把失敗替換成 mock、不把抓取時間當
    成報價時間。標準 loader 先排除未完成日 K，再驗證其交易所日期。
    """

    def __init__(self, settings: ApiSettings | None = None,
                 now: Callable[[], datetime] | None = None,
                 loader_factory: Callable[..., MarketDataLoader] = MarketDataLoader,
                 calendar: ExchangeSessionCalendar | None = None) -> None:
        self.settings = settings or ApiSettings.from_environment()
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.loader_factory = loader_factory
        self.calendar = calendar or ExchangeSessionCalendar()
        self._locks = {market: threading.Lock() for market in Market}
        self._cache: dict[tuple[Market, tuple[str, ...], bool], tuple[float, QuotesResponse]] = {}

    @staticmethod
    def _response(snapshot: QuoteSnapshot) -> QuoteResponse:
        fields = dict(snapshot.__dict__)
        fields["market"] = snapshot.market.value
        return QuoteResponse(**fields)

    def get_quotes(self, market: Market, symbols: list[str], force_refresh: bool = False,
                   demo: bool = False) -> QuotesResponse:
        market = Market(market)
        if not 1 <= len(symbols) <= 50:
            raise PortfolioError("每次報價需要 1～50 個代碼。")
        for symbol in symbols:
            validate_symbol(symbol, market)
        if len(set(symbols)) != len(symbols):
            raise PortfolioError("報價股票代碼不可重複。")
        key = (market, tuple(sorted(symbols)), demo)
        with self._locks[market]:
            cached = self._cache.get(key)
            if (not force_refresh and cached is not None and
                    0 <= time.monotonic() - cached[0] < self.settings.response_ttl_seconds):
                return cached[1].model_copy(deep=True)
            if demo:
                quotes: list[QuoteResponse] = []
                errors: dict[str, str] = {}
                for symbol in symbols:
                    try:
                        quotes.append(self._response(demo_quote(symbol, market)))
                    except PortfolioError as exc:
                        errors[symbol] = str(exc)
                result = QuotesResponse(market=market.value, generated_at=self.now(),
                                        source="mock / fictitious portfolio demonstration",
                                        quotes=quotes, errors=errors)
            else:
                result = self._fetch_live(market, symbols, force_refresh)
            self._cache[key] = (time.monotonic(), result)
            return result.model_copy(deep=True)

    def _completed_session(self, market: Market, as_of: pd.Timestamp
                           ) -> tuple[pd.Timestamp, datetime, object | None]:
        """休市也可診斷最後交易日，且不猜測週一至週五或固定收盤。"""
        try:
            context = self.calendar.context(market, as_of.to_pydatetime())
            date = context.latest_completed_session
        except NonTradingDayError:
            local = as_of.tz_convert(market_settings(market).timezone)
            calendar = self.calendar._calendar(market, local.year)
            date = local.tz_localize(None).normalize()
            for offset in range(1, 32):
                candidate = date - pd.Timedelta(days=offset)
                if calendar.is_session(candidate):
                    date = candidate
                    break
            else:
                raise CalendarError("過去 31 日找不到已完成交易日。")
            context = None
        calendar = self.calendar._calendar(market, date.year)
        closing = pd.Timestamp(calendar.session_close(date))
        if closing.tzinfo is None or closing > as_of:
            raise CalendarError("交易所收盤時間無效或尚未完成。")
        return date, closing.tz_convert("UTC").to_pydatetime(), context

    def _fetch_live(self, market: Market, symbols: list[str], force_refresh: bool) -> QuotesResponse:
        now = self.now()
        as_of = pd.Timestamp(now)
        if as_of.tzinfo is None:
            raise PortfolioError("報價評估時間必須含時區。")
        completed, close_time, context = self._completed_session(market, as_of)
        loader = self.loader_factory(
            self.settings.cache_dir / "portfolio_prices", workers=self.settings.fetch_workers,
            timeout=self.settings.provider_timeout_seconds, retries=self.settings.provider_retries,
        )
        data = loader.load([Stock(symbol, symbol, "", market) for symbol in symbols],
                           as_of, include_intraday=True, force_refresh=force_refresh)
        quotes: list[QuoteResponse] = []
        errors = dict(loader.errors)
        for symbol in symbols:
            try:
                item = data.get(symbol)
                if item is None:
                    raise DataSourceError(errors.get(symbol, "資料供應商未提供行情。"))
                if item.is_stale:
                    raise DataSourceError("僅有過期快取；保留庫存，不產生新的出場建議。")
                daily = item.daily.loc[item.daily.index <= completed]
                if len(daily) < 50 or pd.Timestamp(daily.index[-1]).normalize() != completed:
                    raise DataSourceError("缺少最近已完成交易日或 50 根完整日 K。")
                closes = daily["close"].astype(float)
                if any(not isfinite(value) or value <= 0 for value in closes):
                    raise DataSourceError("完整日 K 含無效收盤價。")
                emas = {span: float(closes.ewm(span=span, adjust=False).mean().iloc[-1]) for span in (9, 21, 50)}
                latest = float(closes.iloc[-1])
                quote_time = close_time
                price_source = "completed daily close only"
                intraday = item.intraday.loc[item.intraday.index <= as_of]
                if not intraday.empty and intraday.index[-1] >= pd.Timestamp(close_time):
                    latest = float(intraday["close"].iloc[-1])
                    quote_time = pd.Timestamp(intraday.index[-1]).tz_convert("UTC").to_pydatetime()
                    price_source = "completed 1-minute delayed snapshot"
                if context is not None and context.phase == "intraday":
                    # An old daily close is unsuitable as a current intraday
                    # hard-stop quote. Surface the missing minute feed instead.
                    if quote_time < context.session_open or as_of - pd.Timestamp(quote_time) > pd.Timedelta(minutes=15):
                        raise DataSourceError("盤中缺少 15 分鐘內的完整分鐘報價，暫停此持股診斷。")
                turnover = float((daily["close"].tail(20) * daily["volume"].tail(20)).median())
                minimum = 50_000_000 if market is Market.US else 1_000_000_000
                large = symbol in self.settings.large_liquid_symbols and turnover >= minimum
                snapshot = QuoteSnapshot(symbol, item.stock.name, market, latest,
                                         emas[9], emas[21], emas[50], float(closes.iloc[-1]),
                                         True, quote_time, close_time,
                                         f"yfinance/Yahoo Finance · {price_source}", large)
                quotes.append(self._response(snapshot))
                errors.pop(symbol, None)
            except (PortfolioError, DataSourceError, ValueError, KeyError, TypeError) as exc:
                errors[symbol] = str(exc)
        return QuotesResponse(market=market.value, generated_at=now,
                              source="yfinance/Yahoo Finance · delayed portfolio quotes",
                              quotes=quotes, errors=errors)


class RecommendationService:
    """Per-market single-flight scans with in-memory and JSON response caches.

    Cache hits preserve ``generated_at`` and price timestamps. A force refresh
    bypasses both response and provider caches. Stale source data is excluded
    by the strategy engine; old response-cache files are never presented as a
    new recommendation after a network failure.
    """

    def __init__(self, settings: ApiSettings | None = None,
                 now: Callable[[], datetime] | None = None) -> None:
        self.settings = settings or ApiSettings.from_environment()
        self.now = now or (lambda: datetime.now(timezone.utc))
        self._locks = {market: threading.Lock() for market in Market}
        self._responses: dict[tuple[Market, float, bool], tuple[float, CandidatesResponse]] = {}
        self.calendar = ExchangeSessionCalendar()

    def _response_ttl(self, result: CandidatesResponse) -> float:
        """Foreground polling progresses an unfinished round once per minute."""
        if result.coverage_remaining_count is not None and result.coverage_remaining_count > 0:
            return min(self.settings.response_ttl_seconds, self.settings.scan_page_interval_seconds)
        return self.settings.response_ttl_seconds

    def background_cached_response(self, market: Market, threshold: float) -> CandidatesResponse | None:
        """Worker-only hydration: keep old timestamps and never invent prices."""
        path = self._response_path(market, threshold)
        try:
            # A corrupt/unbounded file must not delay hydration indefinitely.
            if path.stat().st_size > 4_000_000:
                return None
            result = CandidatesResponse.model_validate_json(path.read_text(encoding="utf-8"))
            if result.market != market.value or result.source.startswith("mock"):
                return None
            age = (self.now() - result.generated_at).total_seconds()
            if age < 0:
                return None
            return result.model_copy(update={
                "stale": result.stale or age >= self._response_ttl(result),
            })
        except (OSError, ValueError, TypeError):
            return None

    def _response_path(self, market: Market, threshold: float) -> Path:
        # Float-to-hex encodes even fractional thresholds without path injection.
        return self.settings.cache_dir / "responses_expanded_v2" / f"{market.value}_{threshold.hex()}.json"

    def _fresh_disk_response(self, market: Market, threshold: float) -> CandidatesResponse | None:
        try:
            result = CandidatesResponse.model_validate_json(
                self._response_path(market, threshold).read_text(encoding="utf-8")
            )
            age = (self.now() - result.generated_at).total_seconds()
            if (result.market == market.value and not result.source.startswith("mock")
                    and 0 <= age < self._response_ttl(result)):
                return result
        except (OSError, ValueError, TypeError):
            # A corrupt response is only a cache miss; provider caches retain
            # their stricter schema checks and independent error diagnostics.
            pass
        return None

    def get_candidates(self, market: Market, adr_threshold: float,
                       force_refresh: bool = False, demo: bool = False,
                       progress: Progress | None = None) -> CandidatesResponse:
        market = Market(market)
        threshold = float(adr_threshold)
        if not 0 <= threshold <= 30 or pd.isna(threshold):
            raise ValueError("ADR 門檻必須介於 0% 與 30%。")
        key = (market, threshold, demo)
        # Check/recompute atomically. Requests for TW and US remain independent.
        with self._locks[market]:
            cached = self._responses.get(key)
            if (not force_refresh and cached is not None
                    and 0 <= time.monotonic() - cached[0] < self._response_ttl(cached[1])):
                return cached[1].model_copy(deep=True)
            if not force_refresh and not demo:
                disk = self._fresh_disk_response(market, threshold)
                if disk is not None:
                    age = (self.now() - disk.generated_at).total_seconds()
                    self._responses[key] = (time.monotonic() - age, disk)
                    return disk.model_copy(deep=True)
            if demo:
                result = self._demo(market, threshold)
            elif progress is not None and "progress" in inspect.signature(self._scan_live).parameters:
                result = self._scan_live(market, threshold, force_refresh, progress=progress)
            else:
                # Existing injected providers/subclasses retain their original
                # three-argument contract; only the real scanner needs progress.
                result = self._scan_live(market, threshold, force_refresh)
            if progress is not None:
                progress(stage="saving_snapshot")
            self._responses[key] = (time.monotonic(), result)
            if not demo:
                try:
                    _atomic_text(self._response_path(market, threshold), result.model_dump_json(indent=2))
                except OSError as exc:
                    LOGGER.warning("Response cache cannot be written: %s", exc)
            return result.model_copy(deep=True)

    def _scan_live(self, market: Market, threshold: float,
                   force_refresh: bool, progress: Progress | None = None) -> CandidatesResponse:
        report = progress or (lambda **_: None)
        report(stage="loading_calendar")
        as_of = pd.Timestamp(self.now())
        context = self.calendar.context(market, as_of.to_pydatetime())
        report(stage="loading_universe")
        provider = UniverseProvider(
            self.settings.cache_dir / "universe", timeout=self.settings.provider_timeout_seconds,
            retries=self.settings.provider_retries,
        )
        stocks = provider.load(market, force_refresh=force_refresh)
        universe_count = len(stocks)
        core = ("NVDA TSLA AMD PLTR SMCI COIN AVGO META AMZN GOOGL MSFT AAPL "
                "MU NFLX APP CRWD PANW TSM QCOM ORCL INTU NOW CRM UBER LLY "
                "GE VST CEG ANET".split() if market is Market.US else
                "2330.TW 2454.TW 2603.TW 2382.TW 2317.TW 3017.TW 3661.TW "
                "3443.TW 3533.TW 6669.TW 3231.TW 2356.TW 2376.TW 2377.TW "
                "2308.TW 2303.TW 3034.TW 3711.TW 2345.TW 3037.TW 2609.TW "
                "2615.TW 2618.TW 2408.TW 3481.TW 2409.TW 2002.TW 2881.TW "
                "2882.TW 3008.TW".split())
        priorities = {symbol: index for index, symbol in enumerate(core)}
        stocks.sort(key=lambda stock: (priorities.get(stock.symbol, len(core)), stock.symbol))
        if self.settings.scan_pool_limit:
            stocks = stocks[:self.settings.scan_pool_limit]
        # A page is bounded even when the selected scope is the whole market.
        # Force refresh advances this persistent cursor, never resets page one.
        checkpoint = RollingScanCheckpoint(
            self.settings.cache_dir / "scan_coverage", market.value, threshold,
            [stock.symbol for stock in stocks], self.settings.scan_page_size,
        )
        by_symbol = {stock.symbol: stock for stock in stocks}
        stocks = [by_symbol[symbol] for symbol in checkpoint.page_symbols]
        total = len(stocks)
        report(stage="loading_benchmark", total_count=total, universe_count=universe_count,
               **checkpoint.fields())
        benchmark_loader = MarketDataLoader(
            self.settings.cache_dir / "prices", workers=1, batch_size=1,
            timeout=self.settings.provider_timeout_seconds, retries=self.settings.provider_retries,
        )
        benchmark = benchmark_loader.load_benchmark(market, as_of)
        data: dict[str, MarketData] = {}
        loader_errors: dict[str, str] = {}
        loader_warnings: list[str] = list(benchmark_loader.warnings)
        completed = 0
        adr_matches = 0
        adr_symbols: set[str] = set()
        scanner = MomentumScanner(ScannerConfig(
            adr_threshold=threshold, recommendation_limit=self.settings.result_limit,
        ))

        def load_one(stock: Stock) -> tuple[MarketData | None, dict[str, str], list[str]]:
            # Each symbol owns its loader/error state. One malformed response
            # cannot discard its neighbours or escape the per-symbol boundary.
            try:
                loader = MarketDataLoader(
                    self.settings.cache_dir / "prices", workers=1, batch_size=1,
                    timeout=self.settings.provider_timeout_seconds,
                    retries=self.settings.provider_retries,
                )
                fetched = loader.load([stock], as_of, include_intraday=True,
                                      force_refresh=force_refresh)
                return fetched.get(stock.symbol), loader.errors, loader.warnings
            except Exception as exc:
                LOGGER.warning("Skipping %s: %s", stock.symbol, exc)
                return None, {stock.symbol: str(exc)}, []

        for start in range(0, total, self.settings.scan_batch_size):
            report(stage="loading_prices")  # Also checks cooperative cancellation.
            batch = stocks[start:start + self.settings.scan_batch_size]
            with ThreadPoolExecutor(max_workers=min(len(batch), self.settings.fetch_workers)) as executor:
                futures = {executor.submit(load_one, stock): stock for stock in batch}
                for future in as_completed(futures):
                    stock = futures[future]
                    item, errors, warnings = future.result()
                    completed += 1
                    loader_errors.update(errors)
                    loader_warnings.extend(warnings)
                    if item is not None:
                        data[stock.symbol] = item
                        try:
                            if not item.is_stale and scanner.calculate_adr(item.daily) + 1e-10 >= threshold:
                                adr_symbols.add(stock.symbol)
                            if item.is_stale:
                                loader_errors[stock.symbol] = "只有過期來源資料，不列入有效評估。"
                        except (ValueError, TypeError, KeyError, IndexError) as exc:
                            loader_errors[stock.symbol] = str(exc)
                    elif stock.symbol not in loader_errors:
                        loader_errors[stock.symbol] = "資料供應商沒有回傳此標的。"
                    adr_matches = len(adr_symbols - loader_errors.keys())
                    # Save before reporting progress: the deadline callback can
                    # reject that progress, but a completed attempt must survive
                    # process restart. A failed attempt is not verified success.
                    checkpoint.mark_attempt(stock.symbol)
                    report(stage="loading_prices", completed_count=completed,
                           evaluated_count=len(data.keys() - loader_errors.keys()), adr_match_count=adr_matches,
                           failed_count=len(loader_errors), **checkpoint.fields())
            if start + len(batch) < total:
                time.sleep(self.settings.scan_batch_delay_seconds)
        if not data or all(item.is_stale for item in data.values()):
            raise DataSourceError("無可用的最新行情；請檢查資料供應商、網路及快取。")
        # Market-cap/large-stock status cannot be inferred from S&P membership
        # or a high price alone. A user-maintained eligible list ALSO needs
        # observed median trading value to use the higher exposure cap.
        for symbol, item in list(data.items()):
            if symbol in self.settings.large_liquid_symbols:
                daily = item.daily.tail(20)
                turnover = float((daily["close"] * daily["volume"]).median())
                minimum = 50_000_000 if market is Market.US else 1_000_000_000
                if turnover >= minimum:
                    data[symbol] = replace(item, stock=replace(item.stock, large_liquid=True))
        report(stage="calculating_indicators")
        candidates = scanner.evaluate(data, benchmark, context)
        report(stage="serializing_snapshot")
        warnings = list(dict.fromkeys(provider.warnings + loader_warnings + scanner.warnings))
        exclusions = {**loader_errors, **scanner.errors}
        serialized: list[CandidateResponse] = []
        for candidate in candidates:
            try:
                serialized.append(serialize_candidate(candidate, data.get(candidate.stock.symbol)))
            except Exception as exc:
                exclusions[candidate.stock.symbol] = f"推薦欄位驗證失敗：{exc}"
                LOGGER.warning("Skipping invalid candidate %s: %s", candidate.stock.symbol, exc)
        if exclusions:
            warnings.append(f"{len(exclusions)} 個標的因資料或指標不完整被略過。")
            warnings.extend(f"{symbol}: {reason}" for symbol, reason in list(exclusions.items())[:10])
        warnings.extend([
            "Yahoo 為延遲快照，不是交易所即時報價；RS Score 是通過 ADR 與資料門檻股票的百分位。",
            "訊號進場價是 PDH/ORH 觸發界線，完成 K 棒確認價另列；App 不送出交易委託。",
            "大型且流動性身份未確認時，保守採 25% 上限。",
        ])
        if market is Market.TW:
            warnings.append("台股上市與上櫃共用加權指數 ^TWII 作相對動能基準，並非各交易所獨立指數排名。")
        checkpoint.mark_evaluated(data.keys() - exclusions.keys())
        coverage = checkpoint.fields()
        warnings.append(
            f"第 {checkpoint.round} 輪，本頁 {total} 檔；"
            f"累積已嘗試 {coverage['coverage_scanned_count']}/{coverage['coverage_total_count']} 檔"
            f"（含失敗），已驗證 {coverage['coverage_evaluated_count']} 檔。"
            "推薦與 RS 百分位僅代表本頁有效股票，並非全市場同時排名。"
        )
        if coverage["coverage_total_count"] < universe_count:
            warnings.append(
                f"管理員限制選定池為 {coverage['coverage_total_count']}/{universe_count} 檔；"
                "MARTIN_SCAN_POOL_LIMIT=0 才涵蓋完整已取得名單。"
            )
        universe_source = provider.sources.get(market, "public universe")
        degraded = (any(item.is_stale for item in data.values())
                    or universe_source.startswith("stale cache") or bool(exclusions))
        # A failed universe refresh can return an old list. Keep its age visible
        # but do not pretend the failed update is a fresh universe snapshot.
        return CandidatesResponse(
            market=market.value, generated_at=self.now(),
            source=f"yfinance/Yahoo Finance · {universe_source} · {context.calendar_source}",
            universe_count=universe_count, stale=degraded, warnings=warnings[:200],
            evaluated_count=len(data.keys() - exclusions.keys()), scan_pool_size=total,
            adr_match_count=len(adr_symbols - exclusions.keys()),
            universe_is_complete=(
                coverage["coverage_total_count"] == universe_count and
                getattr(provider, "coverage_complete", {}).get(market, False) and
                not universe_source.startswith("stale cache")
            ),
            universe_as_of=(None if market not in provider.captured_at else
                            provider.captured_at[market].to_pydatetime()),
            scan_completed_at=self.now(), missing_symbols=sorted(exclusions),
            candidates=serialized, **coverage,
        )

    def _demo(self, market: Market, threshold: float) -> CandidatesResponse:
        """Deterministic fixtures, explicitly labelled fictitious throughout."""
        now = self.now()
        fixtures = ([
            ("2330.TW", "台積電（示範）", "半導體", 1020.0, 999.6, 4.3, 98.0, True),
            ("2454.TW", "聯發科（示範）", "半導體", 1280.0, 1254.4, 5.0, 94.0, True),
            ("3017.TW", "奇鋐（示範）", "電子零組件", 680.0, 663.0, 6.2, 91.0, False),
            ("2382.TW", "廣達（示範）", "電腦及週邊", 280.0, None, 3.9, 88.0, False),
        ] if market is Market.TW else [
            ("NVDA", "NVIDIA (demo)", "Semiconductors", 150.0, 147.0, 5.8, 99.0, True),
            ("PLTR", "Palantir (demo)", "Software", 100.0, 97.5, 7.2, 96.0, False),
            ("AMD", "AMD (demo)", "Semiconductors", 160.0, 156.0, 5.4, 92.0, True),
            ("TSLA", "Tesla (demo)", "Consumer Discretionary", 250.0, None, 6.5, 87.0, True),
        ])
        output = []
        for rank, (symbol, name, sector, entry, stop, adr, rs, large) in enumerate(fixtures, 1):
            if adr < threshold:
                continue
            output.append(CandidateResponse(
                market=market.value, symbol=symbol, name=name, sector=sector,
                adr_percent=adr, rs_score=rs, rs_rank=rank,
                patterns=["PDH突破", "均線收斂"] if stop is not None else ["動能追蹤／待型態確認"],
                entry_price=entry, trigger_price=entry,
                trigger_type="PDH" if stop is not None else None,
                confirmation_price=entry * 1.003 if stop is not None else None,
                day_low=stop, stop_price=stop,
                stop_source="day_low" if stop is not None else None,
                risk_per_share=None if stop is None else entry - stop, is_large_liquid=large,
                status="confirmed" if stop is not None else "watchlist",
                data_timestamp=now, signal_timestamp=now if stop is not None else None,
                notes=["虛構展示數據：不代表最新行情、真實訊號或投資建議。"],
                daily_closes=[round(entry * (0.7 + i * 0.005), 4) for i in range(60)],
            ))
        return CandidatesResponse(
            market=market.value, generated_at=now, source="mock / fictitious API demonstration",
            universe_count=len(fixtures), stale=False,
            warnings=["示範模式只含虛構展示標的，不是完整台股上市櫃／美股三大交易所掃描。"], candidates=output,
        )


def create_app(service: RecommendationService | None = None,
               quote_service: QuoteService | None = None) -> FastAPI:
    """Dependency-injected construction keeps all API tests network-free."""
    scanner_service = service or RecommendationService()
    holdings_quotes = quote_service or QuoteService(scanner_service.settings)
    settings = scanner_service.settings
    background_scans = BackgroundScanManager(
        scan=lambda market, threshold, force, progress: scanner_service.get_candidates(
            Market(market), threshold, force, False, progress=progress,
        ).model_dump(mode="json", exclude_none=True),
        read_cache=lambda market, threshold: (
            result.model_dump(mode="json", exclude_none=True)
            if (result := scanner_service.background_cached_response(Market(market), threshold)) is not None
            else None
        ),
        timeout_seconds=settings.scan_timeout_seconds,
        cache_ttl_seconds=settings.response_ttl_seconds,
        page_interval_seconds=settings.scan_page_interval_seconds,
        failure_cooldown_seconds=settings.scan_failure_cooldown_seconds,
        now=scanner_service.now,
    )
    application = FastAPI(title="Martin Luk Momentum API", version="1.2.0")
    origins = [origin.strip() for origin in os.getenv("MARTIN_CORS_ORIGINS", "").split(",") if origin.strip()]
    if origins:
        application.add_middleware(
            CORSMiddleware, allow_origins=origins, allow_methods=["GET", "POST"],
            allow_headers=["Accept", "Content-Type"], allow_credentials=False,
        )

    @application.get("/health")
    async def health() -> dict[str, object]:
        # Liveness does not imply upstream finance providers are available.
        return {"status": "ok", "version": "1.2.0", "background_scan": True,
                "provider_verified": False}

    @application.get("/v1/capabilities", response_model=CapabilitiesResponse)
    async def capabilities() -> CapabilitiesResponse:
        # Read only immutable runtime settings: this handshake must finish even
        # when calendars, exchange directories or price providers are offline.
        # Full-universe scope is configured eligibility, not completed coverage.
        return CapabilitiesResponse(
            markets=["tw", "us"],
            scan=ScanCapabilities(
                pool_limit=settings.scan_pool_limit,
                scope="full_universe" if settings.scan_pool_limit == 0 else "limited",
                page_size=settings.scan_page_size,
                page_interval_seconds=settings.scan_page_interval_seconds,
            ),
        )

    @application.get("/v1/candidates", response_model=CandidatesResponse)
    async def candidates(
        market: MarketCode = Query(...),
        adr_threshold: float | None = Query(None, ge=0, le=30),
        force_refresh: bool = Query(False), demo: bool = Query(False),
        background: bool = Query(False),
    ) -> CandidatesResponse | JSONResponse:
        selected = Market(market)
        threshold = market_settings(selected).adr_threshold if adr_threshold is None else adr_threshold
        if background:
            if demo:
                raise HTTPException(status_code=422, detail="背景行情 API 不允許使用 demo=true。")
            status_code, envelope = background_scans.poll(market, threshold, force_refresh)
            return JSONResponse(status_code=status_code, content=envelope,
                                headers={"Retry-After": "3", "Cache-Control": "no-store"})
        try:
            return await to_thread(
                scanner_service.get_candidates, selected, threshold, force_refresh, demo
            )
        except (CalendarError, DataSourceError, ScannerError) as exc:
            raise HTTPException(status_code=503, detail=str(exc), headers={"Retry-After": "300"}) from exc
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            LOGGER.exception("Unexpected momentum scan failure for %s", market)
            raise HTTPException(status_code=503, detail="評估失敗；請查看伺服器日誌與資料源狀態。") from exc

    @application.get("/v1/quotes", response_model=QuotesResponse)
    async def quotes(market: MarketCode = Query(...),
                     symbols: str = Query(..., min_length=1, max_length=800),
                     force_refresh: bool = Query(False), demo: bool = Query(False)) -> QuotesResponse:
        requested = [symbol.strip().upper() for symbol in symbols.split(",")]
        try:
            return await to_thread(holdings_quotes.get_quotes, Market(market), requested, force_refresh, demo)
        except (CalendarError, DataSourceError) as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except (PortfolioError, ValueError, TypeError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            LOGGER.exception("Unexpected portfolio quote failure for %s", market)
            raise HTTPException(status_code=503, detail="行情診斷失敗；請查看資料源狀態。") from exc

    @application.post("/v1/portfolio/analyze")
    async def analyze_portfolio(request: AnalyzePortfolioRequest) -> dict[str, object]:
        try:
            positions = [Position(**position.model_dump()) for position in request.positions]
            if positions:
                requested = list(dict.fromkeys(position.symbol for position in positions))
                result = await to_thread(holdings_quotes.get_quotes, Market(request.market),
                                         requested, request.force_refresh, request.demo)
                snapshots = {quote.symbol: quote.snapshot() for quote in result.quotes}
            else:
                result = QuotesResponse(market=request.market, generated_at=datetime.now(timezone.utc),
                                        source="empty portfolio", quotes=[])
                snapshots = {}
            diagnoses, observed, errors = PortfolioAnalyzer(ExitConfig(request.euphoria_percent)).analyze(
                positions, snapshots, request.account_equity, request.market
            )
            # Keep provider errors linked to position ids; the client retains
            # their unchanged state and displays unavailable diagnostics.
            for position in positions:
                if position.symbol in result.errors:
                    errors[position.id] = result.errors[position.symbol]
            return {"market": request.market, "generated_at": result.generated_at.isoformat(),
                    "source": result.source,
                    "diagnostics": [diagnosis.to_dict() for diagnosis in diagnoses],
                    "updated_positions": [position.to_dict() for position in observed],
                    "errors": errors}
        except (CalendarError, DataSourceError) as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except (PortfolioError, ValueError, TypeError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except Exception as exc:
            LOGGER.exception("Unexpected portfolio analysis failure for %s", request.market)
            raise HTTPException(status_code=503, detail="持股評估失敗；請查看伺服器日誌。") from exc

    application.state.recommendation_service = scanner_service
    application.state.quote_service = holdings_quotes
    application.state.background_scans = background_scans
    return application


app = create_app()
