"""以真實突破低點計算多頭部位，嚴格限制名目停損風險。

The 0.5% limit describes a loss *at the planned stop price*. Gaps, slippage,
fees, and execution failures can make the realized loss larger. This module
does not place orders or invent a stop to make a candidate pass the rules.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation, localcontext
import math
from numbers import Real

from .models import Candidate, RiskError, RiskPlan


def _positive_decimal(value: float, field: str) -> Decimal:
    """Convert financial inputs through their decimal representation.

    Reject booleans, strings, NaN, infinity, and zero/negative amounts instead
    of silently coercing an invalid quote or account value into an order.
    Decimal values are also accepted for callers that keep decimal prices.
    """
    if isinstance(value, bool) or not isinstance(value, (Real, Decimal)):
        raise RiskError(f"{field} 必須是有限的正數。")
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise RiskError(f"{field} 無法轉換為有效金額。") from exc
    if not result.is_finite() or result <= 0:
        raise RiskError(f"{field} 必須是有限的正數。")
    try:
        representable = float(result)
    except (ValueError, OverflowError) as exc:
        raise RiskError(f"{field} 超出可輸出的數值範圍。") from exc
    if not math.isfinite(representable) or representable <= 0:
        raise RiskError(f"{field} 超出可輸出的數值範圍。")
    return result


def _floor_ratio(numerator: Decimal, denominator: Decimal) -> int:
    """Floor an exact rational quotient without division-rounding artifacts."""
    num_top, num_bottom = numerator.as_integer_ratio()
    den_top, den_bottom = denominator.as_integer_ratio()
    return (num_top * den_bottom) // (num_bottom * den_top)


class RiskEngine:
    """Calculate one independent position in the market's account currency.

    ``capital`` and the candidate's price must use the same currency. Use
    separate instances for USD and TWD accounts. The risk fraction is fixed
    at 0.005; ``lot_size=1`` permits TW odd lots, while 1000 rounds down to
    whole TW board lots. Existing portfolio exposure must be managed by the
    caller; ``available_cash`` optionally imposes a stricter cash limit.
    """

    RISK_FRACTION = Decimal("0.005")
    LARGE_POSITION_CAP = Decimal("0.35")
    OTHER_POSITION_CAP = Decimal("0.25")
    DEFAULT_STOP_LIMIT = Decimal("0.05")
    TIGHT_STOP_MIN = Decimal("0.015")
    TIGHT_STOP_MAX = Decimal("0.03")

    def __init__(self, capital: float, lot_size: int = 1) -> None:
        self._capital = _positive_decimal(capital, "capital")
        if isinstance(lot_size, bool) or not isinstance(lot_size, int) or lot_size < 1:
            raise RiskError("lot_size 必須是正整數。")
        self.capital = float(self._capital)
        self.lot_size = lot_size

    def plan(self, candidate: Candidate, available_cash: float | None = None) -> RiskPlan:
        """Size a confirmed breakout using actual observed stop prices.

        Stop choice:
        * Distance <= 5%: actual breakout-day low.
        * Distance > 5%: actual entry-bar low, only if distance is 1.5%–3%.

        A watchlist candidate or a missing/unsuitable low raises ``RiskError``
        so reports can show the reason instead of a fictional executable plan.
        Floor shares to satisfy the risk budget, exposure cap, available cash,
        and lot size simultaneously. All checks use decimal prices.
        """
        if candidate.status != "confirmed":
            raise RiskError("型態尚未確認，觀察名單不提供可執行的停損或股數。")
        entry = _positive_decimal(candidate.entry_price, "entry_price")
        if candidate.day_low is None:
            raise RiskError("缺少突破日實際低點，無法計算停損。")
        day_low = _positive_decimal(candidate.day_low, "day_low")
        if day_low >= entry:
            raise RiskError("突破日低點必須低於進場價。")
        cash = self._capital if available_cash is None else _positive_decimal(
            available_cash, "available_cash"
        )
        # Dynamic precision covers the exponent span of finite price/account
        # inputs. Exact integer-ratio division below then prevents a quotient
        # infinitesimally below an integer from rounding up into an extra share.
        values = [self._capital, entry, day_low, cash]
        entry_bar_low: Decimal | None = None
        if candidate.entry_bar_low is not None:
            entry_bar_low = _positive_decimal(candidate.entry_bar_low, "entry_bar_low")
            if entry_bar_low >= entry or entry_bar_low < day_low:
                raise RiskError("進場 K 棒低點須不低於當日低點，且低於進場價。")
            values.append(entry_bar_low)
        precision = max(
            50,
            max(value.adjusted() for value in values)
            - min(value.as_tuple().exponent for value in values)
            + 50,
        )
        with localcontext() as context:
            context.prec = precision
            stop = day_low
            stop_source = "day_low"
            if entry - day_low > entry * self.DEFAULT_STOP_LIMIT:
                if entry_bar_low is None:
                    raise RiskError("當日低點距進場價超過 5%，但缺少進場 K 棒實際低點。")
                tight_distance = entry - entry_bar_low
                if not (
                    entry * self.TIGHT_STOP_MIN
                    <= tight_distance
                    <= entry * self.TIGHT_STOP_MAX
                ):
                    raise RiskError("進場 K 棒停損距離不在 1.5%～3%：略過，不合成停損價。")
                stop = entry_bar_low
                stop_source = "entry_bar_low"

            risk_per_share = entry - stop
            risk_budget = self._capital * self.RISK_FRACTION
            position_cap = (
                self.LARGE_POSITION_CAP
                if candidate.stock.large_liquid is True
                else self.OTHER_POSITION_CAP
            )
            # Maximum amount from the requested formula:
            # (capital * 0.005) / ((entry - stop) / entry).
            # Taking exact share quotients is algebraically equivalent and
            # avoids rounding that maximum amount before sizing.
            share_limit = min(
                _floor_ratio(risk_budget, risk_per_share),
                _floor_ratio(self._capital * position_cap, entry),
                _floor_ratio(cash, entry),
            )
            shares = (share_limit // self.lot_size) * self.lot_size
            if shares < self.lot_size:
                raise RiskError("風險、現金或部位上限不足以買進一個最小交易單位。")
            amount = entry * shares
            risk_amount = risk_per_share * shares
            # Guard the contract even if sizing logic is changed later.
            if risk_amount > risk_budget or amount > self._capital * position_cap or amount > cash:
                raise RiskError("部位計算超過風險、曝險或現金限制。")
            return RiskPlan(
                entry_price=float(entry),
                stop_price=float(stop),
                shares=shares,
                amount=float(amount),
                position_pct=float(amount / self._capital * 100),
                risk_amount=float(risk_amount),
                risk_budget=float(risk_budget),
                sl_pct=float(risk_per_share / entry * 100),
                risk_per_share=float(risk_per_share),
                stop_source=stop_source,
                lot_size=self.lot_size,
            )
