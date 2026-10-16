"""持股 JSON 庫存、CRUD 與批次診斷；市場帳戶分開，不混合 USD/TWD。"""
from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import threading
from typing import Iterable, Mapping

from .data_loader import _atomic_text
from .exit_engine import (ExitAdvisoryEngine, ExitConfig, PortfolioDiagnosis,
                          PortfolioError, Position, QuoteSnapshot)
from .models import Market


class PortfolioStorageError(PortfolioError):
    """庫存檔讀寫或版本錯誤；禁止悄悄覆蓋損毀資料。"""


class PortfolioAnalyzer:
    def __init__(self, config: ExitConfig | None = None) -> None:
        self.engine = ExitAdvisoryEngine(config)

    def analyze(self, positions: Iterable[Position], quotes: Mapping[str, QuoteSnapshot],
                account_equity: float, market: Market | str
                ) -> tuple[list[PortfolioDiagnosis], list[Position], dict[str, str]]:
        selected = Market(market)
        items = list(positions)
        if len({position.id for position in items}) != len(items):
            raise PortfolioError("持股 id 不得重複。")
        if len({(position.market, position.symbol) for position in items}) != len(items):
            raise PortfolioError("同市場股票只可建立一筆合併持股，避免拆分庫存繞過曝險限制。")
        if any(position.market is not selected for position in items):
            raise PortfolioError("同一診斷帳戶只能包含同幣別市場的持股。")
        # Validate equity even when there are no positions.
        from .exit_engine import _number
        _number(account_equity, "account_equity")
        diagnoses: list[PortfolioDiagnosis] = []
        updated: list[Position] = []
        errors: dict[str, str] = {}
        for position in items:
            try:
                quote = quotes.get(position.symbol)
                if quote is None:
                    raise PortfolioError("缺少可靠行情；此持股不產生買賣建議。")
                diagnosis, observed = self.engine.analyze(position, quote, account_equity)
                diagnoses.append(diagnosis)
                updated.append(observed)
            except (PortfolioError, ValueError, ArithmeticError) as exc:
                errors[position.id] = str(exc)
                updated.append(position)
        return diagnoses, updated, errors


class PortfolioTracker:
    """原子 JSON 儲存。單程序鎖；多程序部署須另加檔案鎖／資料庫。

    原始 1R 不會隨浮動停損改變。使用者刻意修正股票／成本／初始
    停損時視為新的交易基礎，清除最高 R 與浮動停損後重新觀察。
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._lock = threading.RLock()
        self._positions: dict[str, Position] = {}
        self.reload()

    def reload(self) -> list[Position]:
        with self._lock:
            try:
                payload = json.loads(self.path.read_text(encoding="utf-8"))
                if not isinstance(payload, dict) or set(payload) != {"schema_version", "positions"}:
                    raise ValueError("庫存根欄位錯誤")
                if (type(payload["schema_version"]) is not int or payload["schema_version"] != 1
                        or not isinstance(payload["positions"], list)):
                    raise ValueError("庫存版本或 positions 格式錯誤")
                items = [Position(**row) for row in payload["positions"]]
                if len({position.id for position in items}) != len(items):
                    raise ValueError("持股 id 重複")
                if len({(position.market, position.symbol) for position in items}) != len(items):
                    raise ValueError("同市場股票持股重複；請合併股數與加權成本")
            except FileNotFoundError:
                if self._positions:
                    raise PortfolioStorageError("既有庫存檔遺失；拒絕清空記憶體庫存。")
                items = []
            except (OSError, ValueError, TypeError, KeyError) as exc:
                raise PortfolioStorageError(f"庫存檔無法安全讀取：{exc}") from exc
            self._positions = {position.id: position for position in items}
            return list(self._positions.values())

    def _commit(self, next_positions: dict[str, Position]) -> None:
        payload = {"schema_version": 1,
                   "positions": [position.to_dict() for position in next_positions.values()]}
        try:
            _atomic_text(self.path, json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False))
        except (OSError, ValueError, TypeError) as exc:
            raise PortfolioStorageError(f"庫存檔寫入失敗：{exc}") from exc
        self._positions = next_positions

    def list_positions(self, market: Market | str | None = None) -> list[Position]:
        with self._lock:
            return [position for position in self._positions.values()
                    if market is None or position.market == Market(market)]

    def add(self, position: Position) -> Position:
        with self._lock:
            if position.id in self._positions:
                raise PortfolioError("持股 id 已存在。")
            if any((item.market, item.symbol) == (position.market, position.symbol)
                   for item in self._positions.values()):
                raise PortfolioError("同市場股票已有庫存，請編輯合併股數與加權成本。")
            self._commit({**self._positions, position.id: position})
            return position

    def update(self, position: Position) -> Position:
        with self._lock:
            original = self._positions.get(position.id)
            if original is None:
                raise PortfolioError("持股不存在。")
            if any(item.id != position.id and (item.market, item.symbol) == (position.market, position.symbol)
                   for item in self._positions.values()):
                raise PortfolioError("修改後股票與另一筆庫存重複，請先合併持股。")
            changed_basis = (position.symbol, position.market, position.entry_price, position.initial_stop) != (
                original.symbol, original.market, original.entry_price, original.initial_stop
            )
            if changed_basis:
                position = replace(position, peak_r=0.0, trailing_stop=position.initial_stop)
            else:
                # Editing name, shares or EMA configuration does not erase
                # previously observed peaks or lower the active hard stop.
                position = replace(
                    position, peak_r=max(original.peak_r, position.peak_r),
                    trailing_stop=max(original.trailing_stop or original.initial_stop,
                                      position.trailing_stop or position.initial_stop),
                )
            self._commit({**self._positions, position.id: position})
            return position

    def delete(self, position_id: str) -> None:
        with self._lock:
            if position_id not in self._positions:
                raise PortfolioError("持股不存在。")
            self._commit({key: value for key, value in self._positions.items() if key != position_id})

    def diagnose(self, quotes: Mapping[str, QuoteSnapshot], account_equity: float,
                 market: Market | str, config: ExitConfig | None = None
                 ) -> tuple[list[PortfolioDiagnosis], dict[str, str]]:
        with self._lock:
            diagnoses, updated, errors = PortfolioAnalyzer(config).analyze(
                self.list_positions(market), quotes, account_equity, market
            )
            self._commit({**self._positions, **{position.id: position for position in updated}})
            return diagnoses, errors


def demo_quote(symbol: str, market: Market | str) -> QuoteSnapshot:
    """明確標記的固定展示報價；無資料的代碼不合成示範數據。"""
    selected = Market(market)
    fixtures: dict[str, tuple[str, float, float, float, float, float, bool]] = {
        "2330.TW": ("台積電（示範）", 1080, 1050, 1025, 980, 1075, True),
        "2454.TW": ("聯發科（示範）", 1356, 1320, 1290, 1230, 1348, True),
        "3017.TW": ("奇鋐（示範）", 653, 669, 660, 630, 655, False),
        "2382.TW": ("廣達（示範）", 296, 290, 282, 268, 294, False),
        "2317.TW": ("鴻海（示範）", 220, 212, 205, 190, 217, True),
        "NVDA": ("NVIDIA (demo)", 159, 155, 150, 140, 158, True),
        "PLTR": ("Palantir (demo)", 112.5, 108, 103, 95, 111, False),
        "AMD": ("AMD (demo)", 155, 157, 153, 145, 154, True),
        "TSLA": ("Tesla (demo)", 300, 260, 250, 235, 298, True),
        "AAPL": ("Apple (demo)", 225, 220, 215, 205, 224, True),
        "MSFT": ("Microsoft (demo)", 430, 425, 418, 405, 429, True),
    }
    row = fixtures.get(symbol)
    if row is None or symbol.endswith((".TW", ".TWO")) != (selected is Market.TW):
        raise PortfolioError("示範資料沒有此代碼；請選用示範股票或切換真實 API。")
    name, price, ema9, ema21, ema50, close, large = row
    instant = datetime(2026, 10, 13, 6, tzinfo=timezone.utc)
    closed = datetime(2026, 10, 13, 5, 30, tzinfo=timezone.utc) if selected is Market.TW else datetime(2026, 10, 12, 20, tzinfo=timezone.utc)
    return QuoteSnapshot(symbol, name, selected, price, ema9, ema21, ema50,
                         close, True, instant, closed, "mock / fictitious portfolio demonstration", large)
