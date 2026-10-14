"""Momentum screening and *as-of* entry confirmation for US and TW equities.

All percentage values in this module are expressed in percentage points (5.0
means 5%). Daily bars are session labels; intraday timestamps label the end
of a bar. A confirmed signal carries the low known at the signal's timestamp,
never a later low observed during the same trading day.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Mapping

import pandas as pd

from .data_utils import atr, ema, require_aware_time, validate_ohlcv, validate_structure
from .models import Candidate, EvaluationContext, Market, MarketData


class ScannerError(ValueError):
    """An invalid configuration or unavailable market benchmark."""


@dataclass(frozen=True)
class ScannerConfig:
    """Adjustable interpretations of qualitative momentum strategy rules."""

    adr_threshold: float | None = None
    adr_period: int = 20
    gap_threshold_pct: float = 2.0
    volume_ratio_threshold: float = 1.5
    premarket_min_volume: int = 100_000
    premarket_volume_fraction: float = 0.01
    potent_top_n: int = 20
    leader_top_n: int = 20
    recommendation_limit: int = 20
    compression_spread_pct: float = 2.0
    contraction_ratio: float = 0.8
    narrow_range_pct: float = 3.0
    or_minutes: int = 5
    rs20_weight: float = 0.5
    rs60_weight: float = 0.5

    def __post_init__(self) -> None:
        positive = (
            self.adr_period, self.gap_threshold_pct, self.volume_ratio_threshold,
            self.premarket_min_volume, self.premarket_volume_fraction,
            self.potent_top_n, self.leader_top_n, self.recommendation_limit,
            self.compression_spread_pct, self.contraction_ratio,
            self.narrow_range_pct,
        )
        if any(not isfinite(float(v)) or v <= 0 for v in positive):
            raise ScannerError("Scanner thresholds and periods must be positive and finite.")
        if self.adr_threshold is not None and (
            not isfinite(self.adr_threshold) or self.adr_threshold < 0
        ):
            raise ScannerError("adr_threshold must be finite and nonnegative.")
        if isinstance(self.or_minutes, bool) or self.or_minutes not in (1, 5):
            raise ScannerError("or_minutes must be 1 or 5.")
        if (not isfinite(self.rs20_weight) or not isfinite(self.rs60_weight)
                or min(self.rs20_weight, self.rs60_weight) < 0
                or self.rs20_weight + self.rs60_weight <= 0):
            raise ScannerError("RS weights must be finite, nonnegative, and have positive sum.")
        if any(isinstance(v, bool) or not isinstance(v, int) for v in (
            self.adr_period, self.potent_top_n, self.leader_top_n,
            self.recommendation_limit, self.premarket_min_volume,
        )):
            raise ScannerError("Periods, counts, and volume thresholds must be integers.")


@dataclass(frozen=True)
class _Screened:
    data: MarketData
    daily: pd.DataFrame
    adr_pct: float


@dataclass(frozen=True)
class _Entry:
    patterns: tuple[str, ...]
    entry_price: float
    day_low: float
    entry_bar_low: float | None
    signal_time: pd.Timestamp
    notes: tuple[str, ...] = ()
    trigger_type: str | None = None
    confirmation_price: float | None = None


def _ohlcv(frame: pd.DataFrame, minimum: int = 1) -> pd.DataFrame:
    """Accept title/lower-case source columns and validate execution prices."""
    if not isinstance(frame, pd.DataFrame) or len(frame) < minimum:
        raise ScannerError(f"At least {minimum} OHLCV bars are required.")
    if not isinstance(frame.index, pd.DatetimeIndex):
        raise ScannerError("OHLCV must have a DatetimeIndex.")
    result = frame.rename(columns={str(c): str(c).lower() for c in frame.columns}).copy()
    return validate_ohlcv(result, min_rows=minimum, name="scanner OHLCV")


def _session_labels(index: pd.DatetimeIndex) -> pd.DatetimeIndex:
    """Yahoo daily indices represent local exchange dates, not UTC instants."""
    return index.tz_localize(None).normalize() if index.tz is not None else index.normalize()


class MomentumScanner:
    """Three scanners plus pattern confirmation; one invalid stock is isolated.

    ``errors`` records per-symbol exclusions and ``warnings`` records degraded
    evidence. The caller should include both in its report. Ranking is computed
    over all ADR-qualified symbols with valid benchmark endpoints, before the
    recommendation count is truncated.
    """

    def __init__(self, config: ScannerConfig | None = None) -> None:
        self.config = config or ScannerConfig()
        self.errors: dict[str, str] = {}
        self.warnings: list[str] = []

    def calculate_adr(self, daily: pd.DataFrame) -> float:
        """SMA((High - Low) / Low, period) × 100; this is ADR, not ATR."""
        bars = _ohlcv(daily, self.config.adr_period)
        value = float(((bars["high"] - bars["low"]) / bars["low"])
                      .tail(self.config.adr_period).mean() * 100.0)
        if not isfinite(value):
            raise ScannerError("ADR is not finite.")
        return value

    def _threshold(self, market: Market) -> float:
        if self.config.adr_threshold is not None:
            return self.config.adr_threshold
        return 3.5 if market == Market.TW else 5.0

    @staticmethod
    def _daily_snapshot(frame: pd.DataFrame, endpoint: pd.Timestamp) -> pd.DataFrame:
        if not isinstance(frame, pd.DataFrame):
            raise ScannerError("Daily data requires a DataFrame.")
        if not isinstance(frame.index, pd.DatetimeIndex):
            raise ScannerError("Daily data requires a DatetimeIndex.")
        validate_structure(frame.rename(columns=lambda c: str(c).lower()), "daily")
        if not (frame.index == frame.index.normalize()).all():
            raise ScannerError("Daily timestamps must be midnight session labels.")
        labels = _session_labels(frame.index)
        subset = frame.loc[labels <= pd.Timestamp(endpoint).normalize()].copy()
        subset.index = labels[labels <= pd.Timestamp(endpoint).normalize()]
        return _ohlcv(subset)

    def _eligible(
        self, data: Mapping[str, MarketData], context: EvaluationContext,
    ) -> dict[str, _Screened]:
        self._validate_context(context)
        eligible: dict[str, _Screened] = {}
        endpoint = pd.Timestamp(context.latest_completed_session).normalize()
        for symbol, item in data.items():
            try:
                if item.stock.market != context.market:
                    continue
                if item.is_stale:
                    raise ScannerError("Data source marked this stock stale.")
                bars = self._daily_snapshot(item.daily, endpoint)
                if bars.index[-1] != endpoint:
                    raise ScannerError(f"Latest completed daily bar is not {endpoint.date()}.")
                if len(bars) < max(61, self.config.adr_period):
                    raise ScannerError("At least 61 completed daily bars are needed for RS60.")
                adr_pct = self.calculate_adr(bars)
                # Inclusive threshold, with only floating arithmetic roundoff tolerated.
                if adr_pct + 1e-10 < self._threshold(context.market):
                    continue
                eligible[symbol] = _Screened(item, bars, adr_pct)
            except (ValueError, TypeError, KeyError, IndexError, AttributeError) as exc:
                self.errors[symbol] = str(exc)
        return eligible

    @staticmethod
    def _validate_context(context: EvaluationContext) -> None:
        for value in (context.as_of, context.session_open, context.session_close):
            require_aware_time(value)
        if context.phase not in ("premarket", "intraday", "postmarket"):
            raise ScannerError("Unknown evaluation phase.")
        if context.session_open >= context.session_close:
            raise ScannerError("Session open must precede close.")
        if pd.Timestamp(context.latest_completed_session).tzinfo is not None:
            raise ScannerError("Completed daily session labels must be timezone naive.")

    @staticmethod
    def _intraday(
        item: MarketData, context: EvaluationContext, *, premarket: bool = False,
    ) -> pd.DataFrame:
        frame = item.intraday
        if frame is None or frame.empty:
            return pd.DataFrame()
        if not isinstance(frame.index, pd.DatetimeIndex) or frame.index.tz is None:
            raise ScannerError("Intraday timestamps must be timezone aware.")
        interval = int(frame.attrs.get("interval_minutes", 1))
        if interval not in (1, 5):
            raise ScannerError("Only 1-minute or 5-minute intraday bars are supported.")
        local = frame.index.tz_convert(context.session_open.tzinfo)
        today = local.tz_localize(None).normalize() == context.session_date
        completed = frame.index <= context.as_of
        if premarket:
            interval_start = context.session_open.normalize() + pd.Timedelta(hours=4)
            in_session = (frame.index > interval_start) & (frame.index <= context.session_open)
        else:
            in_session = ((frame.index > context.session_open)
                          & (frame.index <= context.session_close))
        subset = frame.loc[today & completed & in_session].copy()
        if subset.empty:
            return pd.DataFrame()
        result = _ohlcv(subset)
        result.index = result.index.tz_convert(context.session_open.tzinfo)
        result.attrs["interval_minutes"] = interval
        return result

    def _gaps(
        self, eligible: Mapping[str, _Screened], context: EvaluationContext,
    ) -> dict[str, tuple[str, ...]]:
        matches: dict[str, tuple[str, ...]] = {}
        if context.phase == "premarket" and context.market == Market.TW:
            return matches  # TWSE has no continuous, executed premarket session.
        for symbol, screened in eligible.items():
            try:
                daily = screened.daily
                if context.phase == "premarket":
                    bars = self._intraday(screened.data, context, premarket=True)
                    if bars.empty:
                        continue
                    previous_close = float(daily["close"].iloc[-1])
                    gap = (float(bars["close"].iloc[-1]) / previous_close - 1) * 100
                    baseline = float(daily["volume"].tail(20).mean())
                    volume = float(bars["volume"].sum())
                    if (baseline > 0 and gap >= self.config.gap_threshold_pct
                            and volume >= self.config.premarket_min_volume
                            and volume / baseline >= self.config.premarket_volume_fraction):
                        matches[symbol] = (
                            "盤前量以累積盤前量／過去20日平均日量為代理，並非同時段歷史相對量。",
                        )
                    continue
                # For live intraday snapshots daily bars end at the previous session.
                # After close, daily today's open/volume are valid final observations.
                if context.phase == "postmarket":
                    current = daily.iloc[-1]
                    previous = daily.iloc[-2]
                    baseline = float(daily["volume"].iloc[-21:-1].mean())
                    gap = (float(current["open"]) / float(previous["close"]) - 1) * 100
                    volume = float(current["volume"])
                    note = "跳空及相對量使用已收盤日K，非盤前成交資料。"
                else:
                    bars = self._intraday(screened.data, context)
                    interval = int(bars.attrs.get("interval_minutes", 1))
                    if bars.empty or bars.index[0] != context.session_open + pd.Timedelta(minutes=interval):
                        continue
                    baseline = float(daily["volume"].tail(20).mean())
                    gap = (float(bars["open"].iloc[0]) / float(daily["close"].iloc[-1]) - 1) * 100
                    volume = float(bars["volume"].sum())
                    note = "盤中相對量採截至評估時間的累積量／過去20日平均日量，非同時段相對量。"
                if (baseline > 0 and gap >= self.config.gap_threshold_pct
                        and volume / baseline >= self.config.volume_ratio_threshold):
                    matches[symbol] = (note,)
            except (ValueError, TypeError, KeyError, IndexError, AttributeError) as exc:
                self.warnings.append(f"{symbol}: Gap 掃描略過：{exc}")
        return matches

    def _potent(self, eligible: Mapping[str, _Screened]) -> list[str]:
        scored: list[tuple[str, float]] = []
        for symbol, screened in eligible.items():
            bars = screened.daily
            baseline = float(bars["volume"].iloc[-21:-1].mean())
            if baseline <= 0 or float(bars["volume"].iloc[-1]) / baseline < self.config.volume_ratio_threshold:
                continue
            returns = [float(bars["close"].iloc[-1] / bars["close"].iloc[-1 - n] - 1) * 100
                       for n in (1, 2, 3)]
            # Rank the strongest positive 1–3 session acceleration; volume is a gate.
            score = max(returns)
            if score > 0:
                scored.append((symbol, score))
        return [symbol for symbol, _ in sorted(scored, key=lambda x: (-x[1], x[0]))
                [:self.config.potent_top_n]]

    def _relative_scores(
        self, eligible: Mapping[str, _Screened], benchmark: pd.DataFrame,
        context: EvaluationContext,
    ) -> dict[str, tuple[float, float, float]]:
        try:
            reference = self._daily_snapshot(benchmark, context.latest_completed_session)
            if reference.index[-1] != context.latest_completed_session:
                raise ScannerError("Benchmark latest bar does not match the completed session.")
        except (ValueError, TypeError, KeyError, IndexError, AttributeError) as exc:
            raise ScannerError(f"Valid market benchmark required; evaluation refused: {exc}") from exc
        scores: dict[str, tuple[float, float, float]] = {}
        weight_sum = self.config.rs20_weight + self.config.rs60_weight
        for symbol, screened in eligible.items():
            try:
                bars = screened.daily
                relative: list[float] = []
                for period in (20, 60):
                    start, end = bars.index[-period - 1], bars.index[-1]
                    if start not in reference.index or end not in reference.index:
                        raise ScannerError(f"Benchmark missing exact RS{period} endpoint {start.date()} or {end.date()}.")
                    stock_return = float(bars["close"].iloc[-1] / bars["close"].iloc[-period - 1] - 1)
                    benchmark_return = float(reference.at[end, "close"] / reference.at[start, "close"] - 1)
                    relative.append((stock_return - benchmark_return) * 100)
                score = (relative[0] * self.config.rs20_weight
                         + relative[1] * self.config.rs60_weight) / weight_sum
                if not all(isfinite(v) for v in (*relative, score)):
                    raise ScannerError("Relative momentum is not finite.")
                scores[symbol] = (relative[0], relative[1], score)
            except (ValueError, TypeError, KeyError, IndexError) as exc:
                self.errors[symbol] = str(exc)
        return scores

    def scan_gap(self, data: Mapping[str, MarketData], context: EvaluationContext) -> list[str]:
        """Gap ≥ 2% plus volume evidence; TW premarket returns an empty list."""
        self.errors, self.warnings = {}, []
        return sorted(self._gaps(self._eligible(data, context), context))

    def scan_premarket(self, data: Mapping[str, MarketData], context: EvaluationContext) -> list[str]:
        """Compatibility alias for the gap/episodic-pivot candidate scanner."""
        return self.scan_gap(data, context)

    def scan_potent(self, data: Mapping[str, MarketData], context: EvaluationContext) -> list[str]:
        """Rank positive returns over 1/2/3 sessions with last-session RVOL."""
        self.errors, self.warnings = {}, []
        return self._potent(self._eligible(data, context))

    def scan_leaders(
        self, data: Mapping[str, MarketData], benchmark: pd.DataFrame,
        context: EvaluationContext,
    ) -> list[str]:
        """Weighted RS20/RS60 excess returns relative to the market benchmark."""
        self.errors, self.warnings = {}, []
        scores = self._relative_scores(self._eligible(data, context), benchmark, context)
        return sorted(scores, key=lambda s: (-scores[s][2], s))[:self.config.leader_top_n]

    def detect_compression(self, daily: pd.DataFrame) -> bool:
        """Above all three EMAs, narrow EMA spread, and ATR/return-volatility contraction."""
        bars = _ohlcv(daily, 50)
        close = bars["close"]
        last = float(close.iloc[-1])
        averages = [float(ema(close, p).iloc[-1]) for p in (9, 21, 50)]
        if last < max(averages):
            return False
        if (max(averages) - min(averages)) / last * 100 > self.config.compression_spread_pct:
            return False
        atr_long = float(atr(bars, 20).iloc[-1])
        atr_short = float(atr(bars, 5).iloc[-1])
        changes = close.pct_change().dropna()
        std_long, std_short = float(changes.tail(20).std(ddof=0)), float(changes.tail(5).std(ddof=0))
        atr_contracted = atr_long > 0 and atr_short / atr_long <= self.config.contraction_ratio
        std_contracted = std_long > 0 and std_short / std_long <= self.config.contraction_ratio
        return bool(atr_contracted or std_contracted)

    def _base_patterns(self, prior: pd.DataFrame) -> tuple[str, ...]:
        if len(prior) < 50:
            return ()
        patterns: list[str] = []
        if self.detect_compression(prior):
            patterns.append("均線收斂")
        previous, preceding = prior.iloc[-1], prior.iloc[-2]
        if previous["high"] <= preceding["high"] and previous["low"] >= preceding["low"]:
            patterns.append("內包日")
        range_pct = float((previous["high"] - previous["low"]) / previous["low"] * 100)
        if range_pct <= self.config.narrow_range_pct:
            patterns.append("窄幅整理")
        return tuple(patterns)

    @staticmethod
    def _contiguous(bars: pd.DataFrame, context: EvaluationContext) -> bool:
        interval = int(bars.attrs.get("interval_minutes", 1))
        if bars.empty or bars.index[0] != context.session_open + pd.Timedelta(minutes=interval):
            return False
        expected = pd.date_range(context.session_open + pd.Timedelta(minutes=interval), periods=len(bars), freq=f"{interval}min")
        return bool(bars.index.equals(expected))

    def _entry(
        self, screened: _Screened, context: EvaluationContext,
        *, gap_candidate: bool,
    ) -> tuple[_Entry | None, tuple[str, ...], pd.DataFrame]:
        daily = screened.daily
        prior = daily.loc[daily.index <= context.previous_session]
        patterns = self._base_patterns(prior)
        if context.phase == "premarket":
            premarket_bars = (self._intraday(screened.data, context, premarket=True)
                              if context.market == Market.US else pd.DataFrame())
            return None, patterns, premarket_bars
        bars = self._intraday(screened.data, context)
        entries: list[_Entry] = []
        if not bars.empty and context.phase == "intraday":
            interval = int(bars.attrs.get("interval_minutes", 1))
            expected_last = pd.Timestamp(context.as_of).floor(f"{interval}min")
            if bars.index[-1] < expected_last:
                self.warnings.append(f"{screened.data.stock.symbol}: 最新分鐘K未涵蓋評估時點，僅列追蹤。")
                return None, patterns, bars
        if not bars.empty and self._contiguous(bars, context):
            # At an end-of-day evaluation a downloaded minute series can end
            # early. The final daily close is the current observation and must
            # govern whether an earlier breakout still holds.
            last_price = (float(daily["close"].iloc[-1])
                          if context.phase == "postmarket" else float(bars["close"].iloc[-1]))
            interval = int(bars.attrs.get("interval_minutes", 1))
            pdh = float(prior["high"].iloc[-1])
            if ("均線收斂" in patterns and ("內包日" in patterns or "窄幅整理" in patterns)
                    and last_price > pdh):
                closes = bars["close"]
                previous_closes = closes.shift(1)
                previous_closes.iloc[0] = float(prior["close"].iloc[-1])
                crosses = (closes > pdh) & (previous_closes <= pdh)
                for stamp in bars.index[crosses]:
                    row = bars.loc[stamp]
                    entries.append(_Entry(
                        ("PDH突破", *patterns), pdh,
                        float(bars.loc[:stamp, "low"].min()), float(row["low"]),
                        stamp,
                        ("Trigger 為前日高點；突破須嚴格高於此價。確認 K 收盤另列，觸發界線不保證成交價。",),
                        trigger_type="PDH", confirmation_price=float(row["close"]),
                    ))
            opening_end = context.session_open + pd.Timedelta(minutes=self.config.or_minutes)
            if gap_candidate and interval <= self.config.or_minutes:
                opening = bars.loc[bars.index <= opening_end]
                # Every opening bar must be present and completed before searching.
                complete = (len(opening) * interval == self.config.or_minutes
                            and self.config.or_minutes % interval == 0)
                if complete:
                    orh = float(opening["high"].max())
                    after = bars.loc[bars.index > opening_end]
                    if not after.empty and last_price > orh:
                        previous_close = float(opening["close"].iloc[-1])
                        for stamp, row in after.iterrows():
                            current_close = float(row["close"])
                            if current_close > orh and previous_close <= orh:
                                entries.append(_Entry(
                                    ("ORH突破",), orh,
                                    float(bars.loc[:stamp, "low"].min()), float(row["low"]),
                                    stamp,
                                    (f"ORH 採開盤首{self.config.or_minutes}分鐘完整成交K。",
                                     "Trigger 為開盤區間高點；突破須嚴格高於此價，並非保證成交價。"),
                                    trigger_type="ORH", confirmation_price=current_close,
                                ))
                            previous_close = current_close
        elif not bars.empty:
            self.warnings.append(f"{screened.data.stock.symbol}: 開盤分鐘K不完整，略過盤中突破確認。")
        # Daily confirmation is deliberately distinct from reconstructing an ORH.
        # Its entry time is today's close, so today's day-low is already known.
        if (not entries and context.phase == "postmarket" and bars.empty
                and "均線收斂" in patterns
                and ("內包日" in patterns or "窄幅整理" in patterns)):
            current = daily.iloc[-1]
            if float(current["close"]) > float(prior["high"].iloc[-1]):
                entries.append(_Entry(
                    ("PDH突破", *patterns), float(prior["high"].iloc[-1]),
                    float(current["low"]), None, context.session_close,
                    ("僅有日K：PDH 為前日高點、確認價為當日收盤；缺少分鐘進場 K，不合成紧密停損。",),
                    trigger_type="PDH", confirmation_price=float(current["close"]),
                ))
        # The most recent valid crossing is the relevant historical reference.
        entry = max(entries, key=lambda e: e.signal_time) if entries else None
        return entry, patterns, bars

    def evaluate(
        self, data: Mapping[str, MarketData], benchmark: pd.DataFrame,
        context: EvaluationContext,
    ) -> list[Candidate]:
        """Merge scan membership and generate confirmed entries or pending watchlists.

        A watchlist price is a conditional breakout trigger, not an executable
        recommendation. Its stop inputs remain ``None`` until the entry exists.
        Missing benchmarks raise ScannerError rather than inventing RS values.
        """
        self.errors, self.warnings = {}, []
        eligible = self._eligible(data, context)
        scores = self._relative_scores(eligible, benchmark, context)
        ordered = sorted(scores, key=lambda s: (-scores[s][2], s))
        ranks = {symbol: i + 1 for i, symbol in enumerate(ordered)}
        # All scanner membership is based on valid, benchmark-aligned stocks.
        valid = {symbol: eligible[symbol] for symbol in ordered}
        gaps = self._gaps(valid, context)
        potent = set(self._potent(valid))
        leaders = set(ordered[:self.config.leader_top_n])
        output: list[Candidate] = []
        for symbol in ordered:
            reasons = tuple(label for label, included in (
                ("Gap", symbol in gaps), ("Potent", symbol in potent), ("Leader", symbol in leaders),
            ) if included)
            if not reasons:
                continue
            screened = valid[symbol]
            try:
                entry, patterns, bars = self._entry(screened, context, gap_candidate=symbol in gaps)
                prior = screened.daily.loc[screened.daily.index <= context.previous_session]
                if entry is None:
                    trigger = (float(prior["high"].iloc[-1])
                               if "內包日" in patterns or "窄幅整理" in patterns
                               else float(prior["high"].tail(20).max()))
                    status, day_low, bar_low, signal_time = "watchlist", None, None, None
                    entry_price = trigger
                    trigger_type = "PDH" if "內包日" in patterns or "窄幅整理" in patterns else None
                    confirmation_price = None
                    notes = ("待完整突破K確認；條件觸發價非買進委託，尚無有效停損及股數。",)
                    candidate_patterns = patterns or ("動能追蹤／待型態確認",)
                else:
                    status = "confirmed"
                    entry_price, day_low, bar_low = entry.entry_price, entry.day_low, entry.entry_bar_low
                    signal_time, notes = entry.signal_time, entry.notes
                    trigger_type, confirmation_price = entry.trigger_type, entry.confirmation_price
                    candidate_patterns = entry.patterns
                # Daily timestamps are session labels. Minute evidence carries its
                # last completed close instant, already supplied as a bar-end label.
                if context.phase == "postmarket":
                    data_time = context.session_close
                elif not bars.empty:
                    data_time = bars.index[-1]
                else:
                    data_time = pd.Timestamp(screened.daily.index[-1])
                rs20, rs60, score = scores[symbol]
                count = len(ordered)
                percentile = 100.0 if count == 1 else 100.0 * (count - ranks[symbol]) / (count - 1)
                output.append(Candidate(
                    stock=screened.data.stock, adr_pct=screened.adr_pct,
                    rs20=rs20, rs60=rs60, momentum_score=score,
                    rs_rank=ranks[symbol], rs_percentile=percentile,
                    scanners=reasons, patterns=candidate_patterns, status=status,
                    entry_price=entry_price, day_low=day_low, entry_bar_low=bar_low,
                    signal_time=signal_time, data_time=data_time,
                    notes=tuple(screened.data.warnings) + gaps.get(symbol, ()) + notes,
                    trigger_price=entry_price, trigger_type=trigger_type,
                    confirmation_price=confirmation_price,
                ))
            except (ValueError, TypeError, KeyError, IndexError, AttributeError) as exc:
                self.errors[symbol] = str(exc)
        output.sort(key=lambda c: (c.status != "confirmed", c.rs_rank, c.stock.symbol))
        return output[:self.config.recommendation_limit]


# Short alias for callers preferring the generic engine name.
Scanner = MomentumScanner
