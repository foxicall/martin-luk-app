"""交易所交易日、開收盤時間與跨時區排程判定。

此模組刻意不以「星期一至星期五」代替交易所日曆。缺少依賴、
日期超出日曆範圍或讀取日曆失敗時，會中止該市場評估並回報原因。
只有已確認的休市日會回傳 ``should_run=False``。
"""

from __future__ import annotations

from datetime import datetime, time, timedelta
from importlib.metadata import PackageNotFoundError, version
from typing import Callable, Protocol
from zoneinfo import ZoneInfo

import pandas as pd

from .models import EvaluationContext, Market, StrategyError, market_settings


class CalendarError(StrategyError):
    """交易所日曆無法可靠取得，或排程輸入不合法。"""


class NonTradingDayError(CalendarError):
    """指定市場的當地日期是已確認的休市日。"""


class ExchangeCalendarLike(Protocol):
    """``exchange_calendars`` 的最小介面，也可注入測試日曆。"""

    first_session: pd.Timestamp
    last_session: pd.Timestamp

    def is_session(self, date: pd.Timestamp) -> bool: ...

    def previous_session(self, date: pd.Timestamp) -> pd.Timestamp: ...

    def session_open(self, date: pd.Timestamp) -> pd.Timestamp: ...

    def session_close(self, date: pd.Timestamp) -> pd.Timestamp: ...


CalendarFactory = Callable[[str, pd.Timestamp, pd.Timestamp], ExchangeCalendarLike]


def _exchange_calendar_factory(
    name: str, start: pd.Timestamp, end: pd.Timestamp
) -> ExchangeCalendarLike:
    """延遲載入依賴；使用本地套件規則，不需每次請求金融網站。"""
    try:
        import exchange_calendars as calendars
    except ImportError as exc:
        raise CalendarError(
            "缺少 exchange-calendars；請執行 python -m pip install -r backend/requirements.txt。"
            "無法以一般工作日代替交易所休市日。"
        ) from exc
    try:
        return calendars.get_calendar(name, start=start, end=end)
    except Exception as exc:
        raise CalendarError(f"無法建立 {name} 交易所日曆：{exc}") from exc


class ExchangeSessionCalendar:
    """將具時區的評估時點映射到交易所 session。

    美股排程以紐約時間 08:45、16:30 執行；台股排程以台北時間
    08:30、14:00 執行。所有輸入必須含時區，避免作業系統所在時區
    或美國夏令時間造成錯誤。日曆物件按市場及年份快取。
    """

    SCHEDULE_TIMES: dict[Market, tuple[time, time]] = {
        Market.US: (time(8, 45), time(16, 30)),
        Market.TW: (time(8, 30), time(14, 0)),
    }

    def __init__(self, calendar_factory: CalendarFactory | None = None) -> None:
        self._factory = calendar_factory or _exchange_calendar_factory
        self._calendars: dict[tuple[Market, int], ExchangeCalendarLike] = {}
        self._custom_factory = calendar_factory is not None

    @staticmethod
    def _local_timestamp(market: Market | str, as_of: datetime) -> tuple[Market, pd.Timestamp]:
        try:
            selected_market = Market(market)
        except (TypeError, ValueError) as exc:
            raise CalendarError(f"不支援的市場：{market!r}") from exc
        try:
            timestamp = pd.Timestamp(as_of)
        except (TypeError, ValueError) as exc:
            raise CalendarError(f"不合法的評估時間：{as_of!r}") from exc
        if pd.isna(timestamp) or timestamp.tzinfo is None:
            raise CalendarError("as_of 必須是有效且含時區的 datetime，例如 2026-10-13T14:00:00+08:00。")
        settings = market_settings(selected_market)
        return selected_market, timestamp.tz_convert(ZoneInfo(settings.timezone))

    def _calendar(self, market: Market, year: int) -> ExchangeCalendarLike:
        key = (market, year)
        if key not in self._calendars:
            settings = market_settings(market)
            # 提供前一整年，讓年初第一個 session 也能找到前一交易日。
            start = pd.Timestamp(year=year - 1, month=1, day=1)
            end = pd.Timestamp(year=year + 1, month=12, day=31)
            try:
                self._calendars[key] = self._factory(settings.calendar, start, end)
            except CalendarError:
                raise
            except Exception as exc:
                raise CalendarError(f"{settings.calendar} 日曆載入失敗：{exc}") from exc
        return self._calendars[key]

    @staticmethod
    def _session_date(value: object) -> pd.Timestamp:
        """Session label 是市場日期，移除時區但不改變其日曆日期。"""
        timestamp = pd.Timestamp(value)
        if timestamp.tzinfo is not None:
            timestamp = timestamp.tz_localize(None)
        return timestamp.normalize()

    def _source(self, market: Market) -> str:
        name = market_settings(market).calendar
        if self._custom_factory:
            return f"injected_calendar:{name}"
        try:
            installed_version = version("exchange-calendars")
        except PackageNotFoundError:
            installed_version = "unknown"
        return f"exchange_calendars/{installed_version}:{name}"

    def context(self, market: Market | str, as_of: datetime) -> EvaluationContext:
        """建立當地交易日的評估上下文；已休市則拋出專用例外。

        開盤前與盤中只允許使用上一個已完成日 K；收盤後才允許
        當日日 K。提早收盤直接採交易所日曆的實際收盤時間。
        """
        selected_market, local = self._local_timestamp(market, as_of)
        calendar = self._calendar(selected_market, local.year)
        date = local.tz_localize(None).normalize()
        try:
            first = self._session_date(calendar.first_session)
            last = self._session_date(calendar.last_session)
            if not first <= date <= last:
                raise CalendarError(
                    f"{market_settings(selected_market).calendar} 日期 {date.date()} "
                    f"超出已載入日曆範圍 {first.date()} 至 {last.date()}。"
                )
            if not calendar.is_session(date):
                raise NonTradingDayError(
                    f"{selected_market.value} {date.date()} 為交易所休市日。"
                )
            previous = self._session_date(calendar.previous_session(date))
            opening = pd.Timestamp(calendar.session_open(date))
            closing = pd.Timestamp(calendar.session_close(date))
            if opening.tzinfo is None or closing.tzinfo is None:
                raise CalendarError("日曆開收盤時間缺少時區，無法判定交易階段。")
            opening = opening.tz_convert(local.tzinfo)
            closing = closing.tz_convert(local.tzinfo)
            if previous >= date or closing <= opening:
                raise CalendarError("日曆包含不合法的前一交易日或開收盤時間。")
        except CalendarError:
            raise
        except Exception as exc:
            raise CalendarError(
                f"讀取 {market_settings(selected_market).calendar} "
                f"{date.date()} 的交易日資料失敗：{exc}"
            ) from exc

        phase = "premarket" if local < opening else "postmarket" if local >= closing else "intraday"
        latest_completed = date if phase == "postmarket" else previous
        return EvaluationContext(
            as_of=local,
            market=selected_market,
            session_date=date,
            previous_session=previous,
            phase=phase,
            session_open=opening,
            session_close=closing,
            latest_completed_session=latest_completed,
            calendar_source=self._source(selected_market),
        )

    def scheduled_slot(
        self, market: Market | str, as_of: datetime, window_minutes: int = 10
    ) -> str | None:
        """回傳應執行的排程階段，供 CLI 使用同日同階段去重。

        允許從指定時刻開始、到窗口結束前執行一次。例如 08:45 的
        十分鐘窗口是 [08:45, 08:55)。提早抵達不執行；休市不執行；
        日曆失效則拋例外，不能偽裝成正常跳過。
        """
        if isinstance(window_minutes, bool) or not isinstance(window_minutes, int) or window_minutes <= 0:
            raise CalendarError("window_minutes 必須為正整數。")
        selected_market, local = self._local_timestamp(market, as_of)
        try:
            self.context(selected_market, local.to_pydatetime())
        except NonTradingDayError:
            return None
        for phase, clock_time in zip(("premarket", "postmarket"), self.SCHEDULE_TIMES[selected_market]):
            scheduled = pd.Timestamp(datetime.combine(local.date(), clock_time), tz=local.tzinfo)
            if scheduled <= local < scheduled + timedelta(minutes=window_minutes):
                return phase
        return None

    def should_run(
        self, market: Market | str, as_of: datetime, window_minutes: int = 10
    ) -> bool:
        """指定時間是否為已確認交易日的排程窗口。"""
        return self.scheduled_slot(market, as_of, window_minutes) is not None
