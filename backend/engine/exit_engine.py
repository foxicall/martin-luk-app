"""持股診斷與出場建議；不送出委託，也不假設未觀察到的歷史最高價。

所有 R 倍數永久以原始進場價減原始停損為分母。日線 EMA 出場只
使用已確認的完整收盤；盤中跌破 EMA 會改變健康度，但不代替收盤。
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from datetime import datetime
from decimal import Decimal, localcontext
import math
from numbers import Real
import re
from typing import Literal

from .models import Market


class PortfolioError(ValueError):
    """持股、行情或診斷參數無效；呼叫端應顯示錯誤而非偽造建議。"""


def _number(value: float, label: str, *, positive: bool = True) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (Real, Decimal)):
        raise PortfolioError(f"{label} 必須為有限數字。")
    result = Decimal(str(value))
    if not result.is_finite() or (positive and result <= 0):
        raise PortfolioError(f"{label} 必須為有限{'正' if positive else ''}數。")
    try:
        converted = float(result)
    except (ValueError, OverflowError) as exc:
        raise PortfolioError(f"{label} 超出可表示範圍。") from exc
    if not math.isfinite(converted) or (positive and converted <= 0):
        raise PortfolioError(f"{label} 超出可表示範圍。")
    return result


def validate_symbol(symbol: str, market: Market | str) -> str:
    """限定公開源股票代碼，禁止路徑或任意查詢片段。"""
    try:
        selected = Market(market)
    except (ValueError, TypeError) as exc:
        raise PortfolioError("market 必須為 tw 或 us。") from exc
    pattern = r"[0-9]{4}\.(?:TW|TWO)" if selected is Market.TW else r"[A-Z][A-Z0-9-]{0,14}"
    if not isinstance(symbol, str) or re.fullmatch(pattern, symbol) is None:
        raise PortfolioError("股票代碼格式錯誤；台股請使用四位數普通股代碼加 .TW（上市）或 .TWO（上櫃）。")
    return symbol


def _aware(value: datetime | None, label: str) -> None:
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise PortfolioError(f"{label} 必須為含時區的時間。")


@dataclass(frozen=True)
class Position:
    """一筆持股；peak_r/trailing_stop 是先前實際觀察並保存的狀態。"""

    id: str
    symbol: str
    market: Market | str
    entry_price: float
    shares: int
    initial_stop: float
    peak_r: float = 0.0
    trailing_stop: float | None = None
    trailing_ema: Literal[9, 21, 50] = 9
    main_uptrend: bool = False
    name: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id.strip() or len(self.id) > 100:
            raise PortfolioError("id 必須為非空且不超過 100 字元的字串。")
        validate_symbol(self.symbol, self.market)
        object.__setattr__(self, "market", Market(self.market))
        entry = _number(self.entry_price, "entry_price")
        stop = _number(self.initial_stop, "initial_stop")
        if stop >= entry:
            raise PortfolioError("初始停損必須低於買進成本，才能建立固定正值 1R。")
        if isinstance(self.shares, bool) or not isinstance(self.shares, int) or self.shares < 1:
            raise PortfolioError("shares 必須為正整數（股，非張）。")
        if self.shares > 2**53 - 1:
            raise PortfolioError("shares 超過跨平台精確整數範圍。")
        peak = _number(self.peak_r, "peak_r", positive=False)
        if peak < 0:
            raise PortfolioError("peak_r 不得小於零。")
        if self.trailing_stop is not None and _number(self.trailing_stop, "trailing_stop") < stop:
            raise PortfolioError("浮動硬停損不得低於原始停損。")
        if (isinstance(self.trailing_ema, bool) or not isinstance(self.trailing_ema, int)
                or self.trailing_ema not in (9, 21, 50)):
            raise PortfolioError("trailing_ema 必須為 9、21 或 50。")
        if not isinstance(self.main_uptrend, bool) or not isinstance(self.name, str):
            raise PortfolioError("主升段旗標或名稱型別錯誤。")

    def to_dict(self) -> dict[str, object]:
        payload = asdict(self)
        payload["market"] = self.market.value
        return payload


@dataclass(frozen=True)
class QuoteSnapshot:
    """EMA 與 last_close 均屬同一個已完成日線；current_price 可為分線。"""

    symbol: str
    name: str
    market: Market | str
    current_price: float
    ema9: float
    ema21: float
    ema50: float
    last_close: float | None
    close_confirmed: bool
    quote_timestamp: datetime
    close_timestamp: datetime | None
    source: str
    is_large_liquid: bool = False

    def __post_init__(self) -> None:
        validate_symbol(self.symbol, self.market)
        object.__setattr__(self, "market", Market(self.market))
        for field in ("current_price", "ema9", "ema21", "ema50"):
            _number(getattr(self, field), field)
        if not isinstance(self.close_confirmed, bool) or not isinstance(self.is_large_liquid, bool):
            raise PortfolioError("close_confirmed 與 is_large_liquid 必須為布林值。")
        _aware(self.quote_timestamp, "quote_timestamp")
        if self.last_close is not None:
            _number(self.last_close, "last_close")
        if self.close_timestamp is not None:
            _aware(self.close_timestamp, "close_timestamp")
        if self.close_confirmed and (self.last_close is None or self.close_timestamp is None):
            raise PortfolioError("已確認收盤必須具備收盤價及收盤時間。")
        if self.close_timestamp is not None and self.close_timestamp > self.quote_timestamp:
            raise PortfolioError("完整收盤时间不得晚於行情時間。")
        if not isinstance(self.source, str) or not self.source.strip() or not isinstance(self.name, str):
            raise PortfolioError("行情來源與名稱格式錯誤。")

    def to_dict(self) -> dict[str, object]:
        payload = asdict(self)
        payload["market"] = self.market.value
        payload["quote_timestamp"] = self.quote_timestamp.isoformat()
        payload["close_timestamp"] = None if self.close_timestamp is None else self.close_timestamp.isoformat()
        return payload


@dataclass(frozen=True)
class ExitConfig:
    """正乖離閾值可設定為 15%～20%；預設 20%。"""

    euphoria_percent: float = 20.0

    def __post_init__(self) -> None:
        if not Decimal("15") <= _number(self.euphoria_percent, "euphoria_percent") <= Decimal("20"):
            raise PortfolioError("正乖離閾值必須介於 15%～20%。")


@dataclass(frozen=True)
class PortfolioDiagnosis:
    position_id: str
    symbol: str
    name: str
    market: str
    current_price: float
    entry_price: float
    shares: int
    initial_stop: float
    risk_per_share: float
    current_r: float
    peak_r: float
    unrealized_pnl: float
    position_value: float
    exposure_pct: float
    exposure_cap_pct: float
    over_exposure: bool
    health: str
    trailing_stop: float
    effective_trailing_ema: int
    ema9: float
    ema21: float
    ema50: float
    targets: dict[str, float]
    action: Literal["hold", "trim", "exit"]
    action_label: str
    reason_codes: tuple[str, ...]
    trim_shares: int | None
    trim_percent: float | None
    quote_timestamp: datetime
    close_timestamp: datetime | None
    close_confirmed: bool
    source: str

    def to_dict(self) -> dict[str, object]:
        payload = asdict(self)
        payload["reason_codes"] = list(self.reason_codes)
        payload["quote_timestamp"] = self.quote_timestamp.isoformat()
        payload["close_timestamp"] = None if self.close_timestamp is None else self.close_timestamp.isoformat()
        return payload


class ExitAdvisoryEngine:
    """純計算引擎：硬停損優先、完整收盤次之、最後強勢分批止盈。"""

    def __init__(self, config: ExitConfig | None = None) -> None:
        self.config = config or ExitConfig()

    def analyze(self, position: Position, quote: QuoteSnapshot,
                account_equity: float) -> tuple[PortfolioDiagnosis, Position]:
        if position.symbol != quote.symbol or position.market != quote.market:
            raise PortfolioError("持股與行情代碼／市場不一致。")
        equity = _number(account_equity, "account_equity")
        # Keep decimal boundaries stable (2R, 3R and 35% equality). Float only
        # appears at the JSON boundary, never in trigger comparisons.
        with localcontext() as context:
            context.prec = 80
            entry = _number(position.entry_price, "entry_price")
            initial = _number(position.initial_stop, "initial_stop")
            price = _number(quote.current_price, "current_price")
            risk = entry - initial
            current_r = (price - entry) / risk
            peak = max(Decimal(str(position.peak_r)), current_r, Decimal("0"))
            hard_stop = max(initial, initial if position.trailing_stop is None else Decimal(str(position.trailing_stop)))
            if peak >= 2:
                hard_stop = max(hard_stop, entry)
            # A closing EMA rule is separate from the intraday hard stop. EMA
            # is not silently promoted to a touch-sensitive stop price.
            track = position.trailing_ema if position.main_uptrend and peak >= 3 else 9
            ema = Decimal(str(getattr(quote, f"ema{track}")))
            ema9 = Decimal(str(quote.ema9))
            value = price * position.shares
            exposure = value / equity * 100
            cap = Decimal("35") if quote.is_large_liquid else Decimal("25")
            health = ("severely_weak" if price < Decimal(str(quote.ema50)) else
                      "strong" if price >= ema9 else
                      "consolidating" if price >= Decimal(str(quote.ema21)) else "weak")
            targets = {str(multiple): float(entry + risk * multiple) for multiple in (1, 2, 3, 5, 10)}
            reasons: list[str] = []
            action: Literal["hold", "trim", "exit"] = "hold"
            label = f"持有（維持 {track}EMA 收盤追蹤）"
            trim_shares: int | None = None
            trim_percent: float | None = None
            if price <= hard_stop:
                action = "exit"
                reason = "breakeven_stop" if hard_stop == entry and peak >= 2 else "hard_stop"
                reasons.append(reason)
                label = "🔴 保本停損觸發：建議全數平倉" if reason == "breakeven_stop" else "🔴 硬停損觸發：建議全數平倉"
            elif quote.close_confirmed and quote.last_close is not None and Decimal(str(quote.last_close)) < ema:
                action = "exit"
                reasons.append(f"close_below_ema{track}")
                label = f"🔴 完整收盤跌破 {track}EMA：建議全數平倉"
            else:
                if current_r >= 3:
                    reached = 10 if current_r >= 10 else 5 if current_r >= 5 else 3
                    reasons.append(f"target_{reached}r")
                if exposure > 35:
                    reasons.append("position_above_35pct")
                if (price - ema9) / ema9 * 100 > Decimal(str(self.config.euphoria_percent)):
                    reasons.append("euphoria")
                if reasons:
                    action = "trim"
                    proposed = position.shares * 15 // 100
                    # Respect the requested percentage after whole-share
                    # rounding. A one-share holding has no executable trim.
                    if proposed > 0 and proposed * 100 >= position.shares * 10:
                        trim_shares = proposed
                        trim_percent = float(Decimal(proposed) / position.shares * 100)
                    prefix = (f"達到 {reasons[0].split('_')[1].upper()}：" if reasons[0].startswith("target_") else "強勢訊號：")
                    label = (f"🟢 {prefix}建議減碼 {trim_shares} 股（{trim_percent:.1f}%）" if trim_shares is not None else
                             f"🟢 {prefix}建議分批 10%～15%；整股數不足，不產生可執行股數")
            if exposure > cap:
                reasons.append("exposure_cap_exceeded")
            if peak >= 2:
                reasons.append("breakeven_armed")
            result = PortfolioDiagnosis(
                position_id=position.id, symbol=position.symbol, name=position.name or quote.name,
                market=position.market.value, current_price=float(price), entry_price=float(entry),
                shares=position.shares, initial_stop=float(initial), risk_per_share=float(risk),
                current_r=float(current_r), peak_r=float(peak),
                unrealized_pnl=float((price - entry) * position.shares), position_value=float(value),
                exposure_pct=float(exposure), exposure_cap_pct=float(cap), over_exposure=exposure > cap,
                health=health, trailing_stop=float(hard_stop), effective_trailing_ema=track,
                ema9=quote.ema9, ema21=quote.ema21, ema50=quote.ema50, targets=targets,
                action=action, action_label=label, reason_codes=tuple(reasons),
                trim_shares=trim_shares, trim_percent=trim_percent,
                quote_timestamp=quote.quote_timestamp, close_timestamp=quote.close_timestamp,
                close_confirmed=quote.close_confirmed, source=quote.source,
            )
            # Extremely small risk units or huge prices must not leak Infinity
            # into JSON or into a future persisted state.
            outputs = [result.risk_per_share, result.current_r, result.peak_r,
                       result.unrealized_pnl, result.position_value, result.exposure_pct,
                       result.trailing_stop, *targets.values()]
            if any(not math.isfinite(value) for value in outputs):
                raise PortfolioError("診斷數值超出可表示範圍。")
            updated = replace(position, peak_r=float(peak), trailing_stop=float(hard_stop))
            return result, updated
