"""公開股票池、Yahoo 批量行情，以及不使用 pickle 的本地快取。

行情是資料供應商的延遲快照，不能視為交易所即時報價。所有盤中索引
都代表「K 棒結束時間」；日線則使用市場當地的無時區交易日期。
"""

from __future__ import annotations

import importlib
import json
import logging
import os
import re
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, TypeVar
from urllib.parse import quote

import pandas as pd
try:
    import requests
except ImportError:
    requests = None  # type: ignore[assignment]
# Offline demo startup does not need requests. Listed-universe parsers only use
# Python's standard library; a live provider reports a missing HTTP dependency.
_RequestException = requests.RequestException if requests is not None else ConnectionError

from .market_calendar import ExchangeSessionCalendar, NonTradingDayError
from .models import Market, MarketData, Stock, market_settings

LOGGER = logging.getLogger(__name__)
OHLCV = ["open", "high", "low", "close", "volume"]
T = TypeVar("T")


class DataSourceError(RuntimeError):
    """資料來源不可用或回應內容不符合預期。"""


class CacheError(DataSourceError):
    """快取損毀或缺少必要的中繼資料，不能安全地使用。"""


def _now() -> pd.Timestamp:
    return pd.Timestamp.now(tz="UTC")


def _aware(value: Any, name: str) -> pd.Timestamp:
    timestamp = pd.Timestamp(value)
    if pd.isna(timestamp) or timestamp.tzinfo is None:
        raise ValueError(f"{name} 必須是包含時區的有效時間。")
    return timestamp.tz_convert("UTC")


def _atomic_text(path: Path, text: str) -> None:
    """先寫同目錄暫存檔再 rename，避免排程中斷留下半份快取。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as handle:
            temporary = handle.name
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def _retry(operation: Callable[[], T], attempts: int, delay: float) -> T:
    for attempt in range(attempts):
        try:
            return operation()
        except (_RequestException, DataSourceError, OSError, ValueError) as exc:
            if attempt + 1 == attempts:
                raise DataSourceError(str(exc)) from exc
            time.sleep(min(delay * 2**attempt, 8.0))
    raise AssertionError("unreachable")


class UniverseProvider:
    """TWSE＋TPEx / Nasdaq＋NYSE＋NYSE American 的公開普通股名錄。

    日內共用 24 小時快取；schema 2＋scope 防止舊 S&P 500 快取被誤認為
    完整市場。每個來源獨立容錯，部分結果必須附上不完整標記與警告。
    """

    US_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt"
    US_OTHER_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt"
    TW_URL = "https://isin.twse.com.tw/isin/C_public.jsp?strMode=2"
    TW_OTC_URL = "https://isin.twse.com.tw/isin/C_public.jsp?strMode=4"
    CACHE_SCHEMA_VERSION = 2

    def __init__(
        self,
        cache_dir: str | Path,
        ttl_hours: float = 24,
        timeout: float = 8,
        retries: int = 2,
    ) -> None:
        if ttl_hours <= 0 or timeout <= 0 or retries < 1:
            raise ValueError("ttl_hours、timeout 與 retries 必須大於零。")
        if requests is None:
            raise DataSourceError("即時股票池需要 requests；請安裝 backend/requirements.txt。")
        self.cache_dir = Path(cache_dir)
        self.ttl = pd.Timedelta(hours=ttl_hours)
        # Each actual HTTP attempt is bounded even when a caller supplies 25s.
        self.timeout = min(timeout, 8.0)
        self.retries = retries
        self.warnings: list[str] = []
        self.sources: dict[Market, str] = {}
        self.captured_at: dict[Market, pd.Timestamp] = {}
        self.statistics: dict[Market, dict[str, Any]] = {}
        self.coverage_complete: dict[Market, bool] = {}
        self.coverage_warnings: dict[Market, list[str]] = {}
        self._download_metadata: dict[Market, dict[str, Any]] = {}
        self._cache_metadata: dict[Market, dict[str, Any]] = {}
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) "
                          "Chrome/120.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/plain,text/html,application/json;q=0.9,*/*;q=0.8",
        })

    def _path(self, market: Market) -> Path:
        return self.cache_dir / f"universe_{market.value}.json"

    def _read_cache(self, market: Market) -> tuple[list[Stock], pd.Timestamp, str]:
        from .listed_universe import SCOPES

        path = self._path(market)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("快取根節點必須為 JSON object")
            if (payload.get("schema_version") != self.CACHE_SCHEMA_VERSION
                    or payload.get("market") != market.value
                    or payload.get("scope") != SCOPES[market]):
                raise ValueError("股票池版本、市場或範圍不符；舊 S&P 500／僅上市快取必須重新下載")
            captured = _aware(payload["captured_at"], "captured_at")
            source = payload["source"]
            if not isinstance(source, str) or not source:
                raise ValueError("缺少來源")
            statistics = payload["statistics"]
            complete = payload["coverage_complete"]
            warnings = payload["coverage_warnings"]
            if (not isinstance(statistics, dict) or not isinstance(complete, bool)
                    or not isinstance(warnings, list)
                    or not all(isinstance(item, str) for item in warnings)):
                raise ValueError("缺少來源覆蓋率／分類中繼資料")
            stocks: list[Stock] = []
            for row in payload["stocks"]:
                if not isinstance(row, dict):
                    raise ValueError("股票欄位必須為 JSON object")
                if not all(isinstance(row.get(key), str) and row[key] for key in ("symbol", "name")):
                    raise ValueError("股票代碼或名稱缺失")
                if not isinstance(row.get("sector", ""), str) or not isinstance(row.get("large_liquid", False), bool):
                    raise ValueError("股票欄位型別錯誤")
                if market is Market.TW and not re.fullmatch(r"\d{4}\.TW(?:O)?", row["symbol"]):
                    raise ValueError("台灣代碼缺少正確 .TW／.TWO 後綴")
                stocks.append(Stock(
                    symbol=row["symbol"], name=row["name"], sector=row.get("sector", ""),
                    market=market, large_liquid=row.get("large_liquid", False),
                ))
            if not stocks or len({stock.symbol for stock in stocks}) != len(stocks):
                raise ValueError("股票名單為空或代碼重複")
            self._cache_metadata[market] = {
                "statistics": statistics, "coverage_complete": complete,
                "coverage_warnings": warnings,
            }
            return stocks, captured, source
        except FileNotFoundError:
            raise
        except (OSError, ValueError, TypeError, KeyError) as exc:
            raise CacheError(f"股票池快取不可使用 {path}: {exc}") from exc

    def _get_html(self, url: str, *, taiwan: bool = False) -> str:
        def request() -> str:
            response = self.session.get(url, timeout=self.timeout)
            response.raise_for_status()
            response.encoding = "big5" if taiwan else "utf-8"
            return response.text
        return _retry(request, self.retries, 0.15)

    def _fetch_sources(self, market: Market) -> list[Stock]:
        from .listed_universe import (
            SCOPES, US_CLASSIFICATION_WARNING, parse_nasdaq_directory, parse_tw_isin,
        )

        configurations = (
            [("Nasdaq", self.US_URL, "nasdaq"), ("NYSE／NYSE American", self.US_OTHER_URL, "other")]
            if market is Market.US else
            [("TWSE", self.TW_URL, "listed"), ("TPEx", self.TW_OTC_URL, "otc")]
        )
        stocks_by_symbol: dict[str, Stock] = {}
        source_stats: dict[str, dict[str, Any]] = {}
        source_status: dict[str, dict[str, Any]] = {}
        successful_urls: list[str] = []
        warnings: list[str] = []
        failures: list[str] = []
        unknown_count = 0
        duplicate_count = 0
        for label, url, parser_mode in configurations:
            try:
                text = self._get_html(url, taiwan=market is Market.TW)
                parsed = (parse_nasdaq_directory(text, source=parser_mode)
                          if market is Market.US else parse_tw_isin(text, listing=parser_mode))
                source_stats[label] = parsed.statistics
                source_status[label] = {"ok": True, "url": url, "count": len(parsed.stocks)}
                successful_urls.append(url)
                unknown_count += parsed.statistics.get("unknown_security_type", 0)
                for stock in parsed.stocks:
                    if stock.symbol in stocks_by_symbol:
                        duplicate_count += 1
                    else:
                        stocks_by_symbol[stock.symbol] = stock
            except (DataSourceError, _RequestException, OSError, ValueError) as exc:
                message = f"{market.value}: {label} 名錄失敗 ({exc})；本次股票池不完整。"
                source_status[label] = {"ok": False, "url": url, "error": str(exc)}
                warnings.append(message)
                failures.append(message)
        if not stocks_by_symbol:
            raise DataSourceError("；".join(failures) or "公開名錄沒有可確認的普通股。")
        if market is Market.US:
            warnings.append(US_CLASSIFICATION_WARNING)
            if unknown_count:
                warnings.append(f"us: 名稱無法確認為普通股的 {unknown_count} 檔已保守排除；請勿視為全市場核證清單。")
        metadata = {
            "source": " + ".join(successful_urls),
            "statistics": {
                "scope": SCOPES[market], "sources": source_status,
                "source_statistics": source_stats, "included": len(stocks_by_symbol),
                "source_count": len(successful_urls), "expected_source_count": 2,
                "unknown_security_type": unknown_count, "cross_source_duplicates": duplicate_count,
                "classification_method": ("conservative_security_name_patterns" if market is Market.US
                                          else "ISIN_CFI_ES_and_four_digit_code"),
                "classification_verified": market is Market.TW,
            },
            # Full source delivery is not a claim of verified security taxonomy.
            "coverage_complete": len(successful_urls) == 2 and unknown_count == 0,
            "coverage_warnings": warnings,
        }
        self._download_metadata[market] = metadata
        self.warnings.extend(warnings)
        return sorted(stocks_by_symbol.values(), key=lambda stock: stock.symbol)

    def _fetch_us(self) -> list[Stock]:
        return self._fetch_sources(Market.US)

    def _fetch_tw(self) -> list[Stock]:
        return self._fetch_sources(Market.TW)

    def _restore_cache_metadata(self, market: Market, *, stale: bool = False) -> None:
        metadata = self._cache_metadata[market]
        self.statistics[market] = metadata["statistics"]
        self.coverage_complete[market] = metadata["coverage_complete"] and not stale
        self.coverage_warnings[market] = list(metadata["coverage_warnings"])
        self.warnings.extend(metadata["coverage_warnings"])

    def load(
        self, market: Market, force_refresh: bool = False, offline: bool = False
    ) -> list[Stock]:
        from .listed_universe import SCOPES

        market = Market(market)
        cached: tuple[list[Stock], pd.Timestamp, str] | None = None
        cache_problem: Exception | None = None
        try:
            cached = self._read_cache(market)
        except (FileNotFoundError, CacheError) as exc:
            cache_problem = exc
            if isinstance(exc, CacheError):
                self.warnings.append(str(exc))
        if cached is not None:
            age = _now() - cached[1]
            fresh = pd.Timedelta(0) <= age <= self.ttl
            if offline or (fresh and not force_refresh):
                self.sources[market] = f"cache: {cached[2]} ({cached[1].isoformat()})"
                self.captured_at[market] = cached[1]
                self._restore_cache_metadata(market, stale=not fresh)
                if not fresh:
                    self.warnings.append(f"{market.value}: 使用過期股票池快取，抓取時間 {cached[1].isoformat()}。")
                return cached[0]
        if offline:
            raise DataSourceError(f"{market.value}: 離線模式沒有符合新股票池範圍的快取。{cache_problem or ''}")
        try:
            stocks = self._fetch_us() if market is Market.US else self._fetch_tw()
            metadata = self._download_metadata[market]
            captured = _now()
            payload = {
                "schema_version": self.CACHE_SCHEMA_VERSION, "market": market.value,
                "scope": SCOPES[market], "source": metadata["source"],
                "captured_at": captured.isoformat(), "statistics": metadata["statistics"],
                "coverage_complete": metadata["coverage_complete"],
                "coverage_warnings": metadata["coverage_warnings"],
                "stocks": [
                    {"symbol": stock.symbol, "name": stock.name, "sector": stock.sector,
                     "large_liquid": stock.large_liquid} for stock in stocks
                ],
            }
            try:
                _atomic_text(self._path(market), json.dumps(payload, ensure_ascii=False, indent=2))
            except OSError as exc:
                self.warnings.append(f"股票池已下載，但快取寫入失敗: {exc}")
            self.sources[market] = metadata["source"]
            self.captured_at[market] = captured
            self.statistics[market] = metadata["statistics"]
            self.coverage_complete[market] = metadata["coverage_complete"]
            self.coverage_warnings[market] = list(metadata["coverage_warnings"])
            return stocks
        except (DataSourceError, _RequestException, OSError, ValueError) as exc:
            if cached is not None:
                self.sources[market] = f"stale cache: {cached[2]} ({cached[1].isoformat()})"
                self.captured_at[market] = cached[1]
                self._restore_cache_metadata(market, stale=True)
                self.warnings.append(f"{market.value}: 公開清單更新失敗 ({exc})；使用舊股票池快取 {cached[1].isoformat()}。")
                return cached[0]
            raise DataSourceError(f"{market.value}: 股票池抓取失敗且沒有有效快取: {exc}") from exc

@dataclass(frozen=True)
class _CachedFrame:
    frame: pd.DataFrame
    captured_at: pd.Timestamp
    fresh: bool


def _empty_intraday(timezone: str) -> pd.DataFrame:
    return pd.DataFrame(columns=OHLCV, index=pd.DatetimeIndex([], tz=timezone, name="timestamp"), dtype=float)


def _validate_frame(frame: pd.DataFrame, *, minimum: int = 1) -> None:
    if not isinstance(frame.index, pd.DatetimeIndex) or frame.index.hasnans:
        raise ValueError("OHLCV 索引必須是有效 DatetimeIndex。")
    if frame.index.has_duplicates or not frame.index.is_monotonic_increasing:
        raise ValueError("OHLCV 時間必須遞增且不可重複。")
    if any(column not in frame for column in OHLCV) or len(frame) < minimum:
        raise ValueError(f"OHLCV 缺少必要欄位或少於 {minimum} 筆資料。")
    values = frame[OHLCV].apply(pd.to_numeric, errors="coerce")
    if values.isna().any().any() or values.isin([float("inf"), -float("inf")]).any().any():
        raise ValueError("OHLCV 包含 NaN、無限值或非數值。")
    if (values[["open", "high", "low", "close"]] <= 0).any().any() or (values.volume < 0).any():
        raise ValueError("價格必須為正，成交量不得為負。")
    if (values.high < values[["open", "close", "low"]].max(axis=1)).any() or (values.low > values[["open", "close", "high"]].min(axis=1)).any():
        raise ValueError("OHLC 高低價關係不一致。")


def _normalize(raw: pd.DataFrame, timezone: str, interval: str) -> pd.DataFrame:
    frame = raw.copy()
    if isinstance(frame.columns, pd.MultiIndex):
        raise DataSourceError("單一股票 OHLCV 仍含多層欄位。")
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    if any(column not in frame for column in OHLCV):
        raise DataSourceError("Yahoo 回應缺少 OHLCV 欄位。")
    frame = frame[OHLCV].apply(pd.to_numeric, errors="coerce")
    # Yahoo 多檔批次對齊會產生整列空值，這些不是交易 K 棒。
    frame = frame.dropna(how="all").sort_index()
    index = pd.DatetimeIndex(frame.index)
    if interval == "1d":
        if index.tz is not None:
            index = index.tz_convert(timezone).tz_localize(None)
        frame.index = index.normalize()
    else:
        if index.tz is None:
            index = index.tz_localize(timezone, ambiguous="raise", nonexistent="raise")
        else:
            index = index.tz_convert(timezone)
        # Yahoo timestamps are bar starts; entry engines only use completed bars.
        frame.index = index + pd.Timedelta(minutes=1)
    frame.index.name = "timestamp"
    frame = frame.loc[~frame.index.duplicated(keep="last")]
    # CSV 不儲存 pandas 的 freq 屬性，統一索引表示避免快取/線上差異。
    frame.index = pd.DatetimeIndex(frame.index.tolist(), name="timestamp")
    _validate_frame(frame, minimum=100 if interval == "1d" else 1)
    return frame.astype(float)


class MarketDataLoader:
    """受控並行 Yahoo 批次行情，日線 6h / 分線 5min TTL。

    Yahoo minute 最多抓近期七日；缺少盤中資料會保留日線並附警告。
    不會為真實股票悄悄替換 mock data，也不會停用 TLS/代理 CA 驗證。
    """

    def __init__(
        self, cache_dir: str | Path, workers: int = 6, offline: bool = False,
        batch_size: int = 40, timeout: float = 25, retries: int = 3,
        request_interval: float = 0.35,
    ) -> None:
        if workers < 1 or batch_size < 1 or timeout <= 0 or retries < 1 or request_interval < 0:
            raise ValueError("workers、batch_size、timeout、retries 必須為正；request_interval 不得為負。")
        self.cache_dir = Path(cache_dir)
        self.workers = workers
        self.offline = offline
        self.batch_size = batch_size
        self.timeout = timeout
        self.retries = retries
        self.request_interval = request_interval
        self.errors: dict[str, str] = {}
        self.warnings: list[str] = []
        self._rate_lock = threading.Lock()
        self._last_request = 0.0
        self._calendar = ExchangeSessionCalendar()

    def _paths(self, symbol: str, interval: str) -> tuple[Path, Path]:
        stem = f"{quote(symbol, safe='')}_{interval}"
        return self.cache_dir / f"{stem}.csv", self.cache_dir / f"{stem}.json"

    def _read_cache(self, stock: Stock, interval: str) -> _CachedFrame:
        csv_path, meta_path = self._paths(stock.symbol, interval)
        if not csv_path.exists() and not meta_path.exists():
            raise FileNotFoundError(csv_path)
        try:
            metadata = json.loads(meta_path.read_text(encoding="utf-8"))
            if not isinstance(metadata, dict):
                raise ValueError("快取中繼資料必須為 JSON object")
            if metadata.get("schema_version") != 1 or metadata.get("symbol") != stock.symbol or metadata.get("interval") != interval:
                raise ValueError("版本、代碼或 K 棒週期不符")
            if metadata.get("provider") != "yfinance/Yahoo Finance" or metadata.get("adjustment") != "auto_adjust=True":
                raise ValueError("來源或 OHLC 調整方式不符")
            captured = _aware(metadata["captured_at"], "captured_at")
            frame = pd.read_csv(csv_path, index_col="timestamp")
            if interval == "1d":
                frame.index = pd.DatetimeIndex(pd.to_datetime(frame.index, errors="raise"))
                if frame.index.tz is not None or not frame.index.equals(frame.index.normalize()):
                    raise ValueError("日線日期必須為無時區午夜")
            else:
                frame.index = pd.DatetimeIndex(pd.to_datetime(frame.index, utc=True, errors="raise")).tz_convert(market_settings(stock.market).timezone)
            frame.index.name = "timestamp"
            frame = frame[OHLCV].astype(float)
            _validate_frame(frame, minimum=100 if interval == "1d" else 1)
            if pd.Timestamp(metadata["last_bar_timestamp"]) != frame.index[-1]:
                raise ValueError("最後 K 棒時間與中繼資料不符")
            age = _now() - captured
            ttl = pd.Timedelta(hours=6) if interval == "1d" else pd.Timedelta(minutes=5)
            return _CachedFrame(frame, captured, pd.Timedelta(0) <= age <= ttl)
        except (OSError, ValueError, TypeError, KeyError, pd.errors.ParserError) as exc:
            raise CacheError(f"行情快取損毀 {csv_path}: {exc}") from exc

    def _write_cache(self, stock: Stock, interval: str, frame: pd.DataFrame, captured: pd.Timestamp) -> None:
        csv_path, meta_path = self._paths(stock.symbol, interval)
        metadata = {
            "schema_version": 1, "symbol": stock.symbol, "interval": interval,
            "provider": "yfinance/Yahoo Finance", "origin": "public Yahoo download API",
            "adjustment": "auto_adjust=True", "captured_at": captured.isoformat(),
            "last_bar_timestamp": frame.index[-1].isoformat(),
        }
        # Metadata is committed last; interrupted writes are detected on the next read.
        _atomic_text(csv_path, frame.to_csv(index_label="timestamp"))
        _atomic_text(meta_path, json.dumps(metadata, ensure_ascii=False, indent=2))

    def _rate_limit(self) -> None:
        with self._rate_lock:
            wait = self.request_interval - (time.monotonic() - self._last_request)
            if wait > 0:
                time.sleep(wait)
            self._last_request = time.monotonic()

    def _download_batch(self, symbols: list[str], interval: str, prepost: bool) -> dict[str, pd.DataFrame]:
        try:
            yf = importlib.import_module("yfinance")
        except ImportError as exc:
            raise DataSourceError("線上行情需要 yfinance；請執行 pip install -r requirements.txt。") from exc

        def download() -> dict[str, pd.DataFrame]:
            self._rate_limit()
            try:
                raw = yf.download(
                    tickers=symbols, period="1y" if interval == "1d" else "7d",
                    interval=interval, auto_adjust=True, prepost=prepost,
                    progress=False, threads=False, group_by="ticker", timeout=self.timeout,
                    ignore_tz=False,
                )
            except Exception as exc:
                # Provider transport exceptions vary by yfinance version.
                raise DataSourceError(f"Yahoo {interval} 請求失敗: {exc}") from exc
            if raw is None or raw.empty:
                raise DataSourceError(f"Yahoo {interval} 回傳空資料。")
            frames: dict[str, pd.DataFrame] = {}
            if isinstance(raw.columns, pd.MultiIndex):
                for symbol in symbols:
                    if symbol in raw.columns.get_level_values(0):
                        frames[symbol] = raw[symbol].copy()
                    elif symbol in raw.columns.get_level_values(1):
                        frames[symbol] = raw.xs(symbol, axis=1, level=1).copy()
            elif len(symbols) == 1:
                frames[symbols[0]] = raw.copy()
            frames = {symbol: frame for symbol, frame in frames.items() if not frame.dropna(how="all").empty}
            if not frames:
                raise DataSourceError("Yahoo 回應未包含任何要求的代碼。")
            return frames
        return _retry(download, self.retries, 0.75)

    def _fetch(self, stocks: list[Stock], interval: str) -> tuple[dict[str, pd.DataFrame], dict[str, str]]:
        results: dict[str, pd.DataFrame] = {}
        errors: dict[str, str] = {}
        # 市場分批，避免台股不必要地要求盤前資料。
        batches = [
            group[start:start + self.batch_size]
            for market in Market
            for group in [[stock for stock in stocks if stock.market is market]]
            for start in range(0, len(group), self.batch_size)
        ]
        with ThreadPoolExecutor(max_workers=self.workers) as executor:
            futures = {
                executor.submit(self._download_batch, [stock.symbol for stock in batch], interval, batch[0].market is Market.US): batch
                for batch in batches
            }
            for future in as_completed(futures):
                batch = futures[future]
                try:
                    downloaded = future.result()
                except Exception as exc:
                    for stock in batch:
                        errors[stock.symbol] = str(exc)
                    continue
                for stock in batch:
                    try:
                        raw = downloaded.get(stock.symbol)
                        if (raw is None or raw.dropna(how="all").empty) and len(batch) > 1:
                            # Yahoo 批次可能只漏掉部分代碼；單檔重試仍受相同節流限制。
                            retried = self._download_batch([stock.symbol], interval, stock.market is Market.US)
                            raw = retried.get(stock.symbol)
                        if raw is None or raw.empty:
                            raise DataSourceError("Yahoo 未回傳此代碼的資料。")
                        results[stock.symbol] = _normalize(raw, market_settings(stock.market).timezone, interval)
                    except (DataSourceError, ValueError, TypeError) as exc:
                        errors[stock.symbol] = str(exc)
        return results, errors

    def _available(self, frame: pd.DataFrame, market: Market, as_of: pd.Timestamp, interval: str) -> pd.DataFrame:
        if interval != "1d":
            return frame.loc[frame.index <= as_of].copy()
        try:
            context = self._calendar.context(market, as_of.to_pydatetime())
        except NonTradingDayError:
            # CLI 排程會跳過休市日；獨立 loader 的離線讀取仍允許查看之前資料。
            local_date = as_of.tz_convert(market_settings(market).timezone).normalize().tz_localize(None)
            return frame.loc[frame.index < local_date].copy()
        # 日曆收盤時間包括美股提早收盤，不以固定 16:00 判定。
        return frame.loc[frame.index <= context.latest_completed_session].copy()

    def load(
        self, stocks: list[Stock], as_of: pd.Timestamp, include_intraday: bool = True,
        force_refresh: bool = False,
    ) -> dict[str, MarketData]:
        as_of = _aware(as_of, "as_of")
        self.errors = {}
        self.warnings = []
        if len({stock.symbol for stock in stocks}) != len(stocks):
            raise ValueError("請求股票代碼不可重複。")
        frames: dict[tuple[str, str], _CachedFrame] = {}
        messages: dict[str, list[str]] = {stock.symbol: [] for stock in stocks}
        stale: dict[str, bool] = {stock.symbol: False for stock in stocks}
        intervals = ["1d", "1m"] if include_intraday else ["1d"]
        for interval in intervals:
            needed: list[Stock] = []
            for stock in stocks:
                try:
                    cached = self._read_cache(stock, interval)
                    frames[stock.symbol, interval] = cached
                    if self.offline or (cached.fresh and not force_refresh):
                        if not cached.fresh:
                            stale[stock.symbol] = True
                            messages[stock.symbol].append(f"{interval}: 離線使用過期快取 ({cached.captured_at.isoformat()})。")
                        continue
                except (FileNotFoundError, CacheError) as exc:
                    if isinstance(exc, CacheError):
                        messages[stock.symbol].append(str(exc))
                if self.offline:
                    messages[stock.symbol].append(f"{interval}: 離線模式沒有可用快取。")
                    stale[stock.symbol] = True
                else:
                    needed.append(stock)
            if self.offline or not needed:
                continue
            fetched, failures = self._fetch(needed, interval)
            captured = _now()
            for stock in needed:
                key = stock.symbol, interval
                if stock.symbol in fetched:
                    frame = fetched[stock.symbol]
                    frames[key] = _CachedFrame(frame, captured, True)
                    try:
                        self._write_cache(stock, interval, frame, captured)
                    except OSError as exc:
                        messages[stock.symbol].append(f"{interval}: 已下載，但快取寫入失敗 ({exc})。")
                else:
                    problem = failures.get(stock.symbol, "沒有有效行情")
                    if key in frames:
                        stale[stock.symbol] = True
                        messages[stock.symbol].append(f"{interval}: 更新失敗 ({problem})；使用舊快取 {frames[key].captured_at.isoformat()}。")
                    else:
                        messages[stock.symbol].append(f"{interval}: 下載失敗 ({problem})。")
                        stale[stock.symbol] = True
        result: dict[str, MarketData] = {}
        for stock in stocks:
            key = stock.symbol, "1d"
            if key not in frames:
                self.errors[stock.symbol] = "；".join(messages[stock.symbol]) or "沒有日線資料。"
                continue
            daily = self._available(frames[key].frame, stock.market, as_of, "1d")
            if len(daily) < 100:
                self.errors[stock.symbol] = f"as_of 之前只有 {len(daily)} 根完整日 K，至少需要 100 根。"
                continue
            minute_key = stock.symbol, "1m"
            intraday = _empty_intraday(market_settings(stock.market).timezone)
            captures = [frames[key].captured_at]
            if minute_key in frames:
                intraday = self._available(frames[minute_key].frame, stock.market, as_of, "1m")
                captures.append(frames[minute_key].captured_at)
            if include_intraday and intraday.empty:
                messages[stock.symbol].append("無可用的完整 1 分 K；ORH/盤前訊號不能確認。")
            if stock.market is Market.TW and include_intraday:
                messages[stock.symbol].append("Yahoo 台股沒有可靠的盤前競價成交量；盤前只能保留待觀察候選。")
            result[stock.symbol] = MarketData(
                stock=stock, daily=daily, intraday=intraday,
                fetched_at=max(captures), is_stale=stale[stock.symbol],
                warnings=tuple(messages[stock.symbol]),
            )
            self.warnings.extend(f"{stock.symbol}: {message}" for message in messages[stock.symbol])
        self.warnings.extend(f"{symbol}: {message}" for symbol, message in self.errors.items())
        return result

    def load_benchmark(self, market: Market, as_of: pd.Timestamp) -> pd.DataFrame:
        market = Market(market)
        as_of = _aware(as_of, "as_of")
        symbol = market_settings(market).benchmark
        benchmark = Stock(symbol, symbol, "Benchmark", market, True)
        previous_errors, previous_warnings = self.errors.copy(), self.warnings.copy()
        try:
            data = self.load([benchmark], as_of, include_intraday=False)
            if symbol not in data:
                raise DataSourceError(f"基準 {symbol} 無法讀取: {self.errors.get(symbol, 'unknown')}")
            if data[symbol].is_stale:
                raise DataSourceError(f"基準 {symbol} 只有過期快取，無法可靠計算 RS。")
            return data[symbol].daily
        finally:
            # 讀基準不應抹除已完成的股票抓取診斷。
            self.errors = {**previous_errors, **self.errors}
            self.warnings = previous_warnings + self.warnings
