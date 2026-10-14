"""市場資料驗證與時間邊界；只讀取評估時點已經完成的價格。"""
from __future__ import annotations

from numbers import Integral

import numpy as np
import pandas as pd

from .models import DataValidationError, EvaluationContext, InsufficientDataError, market_settings

OHLCV_COLUMNS = ("open", "high", "low", "close", "volume")


def require_aware_time(value: pd.Timestamp) -> pd.Timestamp:
    try:
        result = pd.Timestamp(value)
    except (ValueError, TypeError, OverflowError) as exc:
        raise DataValidationError("時間必須可解析且附時區。") from exc
    if pd.isna(result) or result.tzinfo is None:
        raise DataValidationError("時間必須附時區，例如 2026-10-13T08:45:00-04:00。")
    return result


def validate_structure(frame: pd.DataFrame, name: str = "data") -> None:
    if not isinstance(frame, pd.DataFrame) or not isinstance(frame.index, pd.DatetimeIndex):
        raise DataValidationError(f"{name}: 需要 DatetimeIndex 的 DataFrame。")
    if frame.index.hasnans or not frame.index.is_unique or not frame.index.is_monotonic_increasing:
        raise DataValidationError(f"{name}: 時間索引必須唯一、遞增且有效。")
    if not frame.columns.is_unique or set(OHLCV_COLUMNS) - set(frame.columns):
        raise DataValidationError(f"{name}: 需要唯一的小寫 open/high/low/close/volume 欄位。")


def validate_ohlcv(frame: pd.DataFrame, min_rows: int = 1, name: str = "data") -> pd.DataFrame:
    validate_structure(frame, name)
    if isinstance(min_rows, bool) or not isinstance(min_rows, Integral) or min_rows < 0:
        raise DataValidationError("min_rows 必須為非負整數。")
    if len(frame) < min_rows:
        raise InsufficientDataError(f"{name}: 需要 {min_rows} 根資料，僅有 {len(frame)} 根。")
    values = frame.loc[:, list(OHLCV_COLUMNS)]
    if any(not pd.api.types.is_numeric_dtype(values[c]) or
           pd.api.types.is_bool_dtype(values[c]) or pd.api.types.is_complex_dtype(values[c])
           for c in values):
        raise DataValidationError(f"{name}: OHLCV 必須是實數。")
    if not np.isfinite(values.to_numpy(dtype=float)).all():
        raise DataValidationError(f"{name}: 不可有缺值或無限值。")
    if (values[["open", "high", "low", "close"]] <= 0).any().any() or (values["volume"] < 0).any():
        raise DataValidationError(f"{name}: 價格必須為正數，成交量不可為負。")
    if ((values["low"] > values[["open", "close"]].min(axis=1)) |
        (values["high"] < values[["open", "close"]].max(axis=1))).any():
        raise DataValidationError(f"{name}: 必須符合 low ≤ open/close ≤ high。")
    return frame.copy()


def normalize_daily(raw: pd.DataFrame, timezone: str) -> pd.DataFrame:
    """單檔供應商日K轉小寫；日K索引是交易日標籤，不轉換成其他日期。"""
    data = raw.rename(columns=lambda c: str(c).lower()).copy()
    if not isinstance(data.index, pd.DatetimeIndex):
        data.index = pd.to_datetime(data.index)
    data.index = pd.DatetimeIndex(data.index.date)
    return validate_ohlcv(data.loc[:, list(OHLCV_COLUMNS)].sort_index(), name="normalized_daily")


def normalize_intraday(raw: pd.DataFrame, timezone: str, interval_minutes: int = 1) -> pd.DataFrame:
    """供應商開始時間轉為本系統的K棒結束時間。"""
    if interval_minutes not in (1, 5):
        raise DataValidationError("僅支援1／5分鐘資料。")
    data = raw.rename(columns=lambda c: str(c).lower()).copy()
    index = pd.DatetimeIndex(data.index)
    index = index.tz_localize(timezone) if index.tz is None else index.tz_convert(timezone)
    data.index = index + pd.Timedelta(minutes=interval_minutes)
    return validate_ohlcv(data.loc[:, list(OHLCV_COLUMNS)].sort_index(), min_rows=0, name="normalized_intraday")


def completed_daily(
    frame: pd.DataFrame, context: EvaluationContext, include_session: bool = False
) -> pd.DataFrame:
    """預設僅前日以前；include_session 也只會包含已收盤的當日日K。"""
    validate_structure(frame, "daily")
    if not (frame.index == frame.index.normalize()).all():
        raise DataValidationError("日K索引必須是午夜交易日標籤。")
    if pd.Index(frame.index.date).has_duplicates:
        raise DataValidationError("每個交易日只能有一根日K。")
    cutoff = context.latest_completed_session.date() if include_session else context.previous_session.date()
    return validate_ohlcv(frame.loc[frame.index.date <= cutoff], min_rows=0, name="completed_daily")


def intraday_snapshot(
    frame: pd.DataFrame, context: EvaluationContext, regular_session: bool = True
) -> pd.DataFrame:
    validate_structure(frame, "intraday")
    if frame.index.tz is None:
        raise DataValidationError("分鐘K索引必須附時區並代表結束時間。")
    data = frame.copy()
    data.index = data.index.tz_convert(market_settings(context.market).timezone)
    mask = (data.index <= require_aware_time(context.as_of)) & (data.index.date == context.session_date.date())
    if regular_session:
        mask &= (data.index > context.session_open) & (data.index <= context.session_close)
    data = data.loc[mask]
    return validate_ohlcv(data, min_rows=0, name="intraday_snapshot")


def ema(close: pd.Series, period: int) -> pd.Series:
    if not isinstance(period, Integral) or isinstance(period, bool) or period < 1:
        raise DataValidationError("EMA period 必須是正整數。")
    return close.ewm(span=period, adjust=False, min_periods=period).mean()


def atr(frame: pd.DataFrame, period: int) -> pd.Series:
    """ATR 與 ADR 分開定義：ATR 的 true range 納入前日收盤跳空。"""
    data = validate_ohlcv(frame)
    if not isinstance(period, Integral) or isinstance(period, bool) or period < 1:
        raise DataValidationError("ATR period 必須是正整數。")
    previous = data["close"].shift(1)
    ranges = pd.concat([data["high"] - data["low"], (data["high"] - previous).abs(),
                        (data["low"] - previous).abs()], axis=1).max(axis=1)
    return ranges.rolling(period, min_periods=period).mean()
