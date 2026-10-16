"""Non-blocking, per-market background jobs for the mobile snapshot API.

Only short in-memory bookkeeping occurs in ``poll``. All disk/provider work
runs in daemon workers. A deadline closes a job, not a Python thread: an
unresponsive worker keeps its market slot until it really exits, preventing
force-refresh from spawning an unbounded number of abandoned requests.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
import logging
import os
from pathlib import Path
import threading
import time
from typing import Any, Callable
from uuid import uuid4

LOGGER = logging.getLogger(__name__)
Progress = Callable[..., None]
Snapshot = dict[str, Any]


class ScanCancelled(RuntimeError):
    """Cooperative stop between provider calls after the job deadline."""


class RollingScanCheckpoint:
    """Persist attempted coverage; this never claims an attempted quote passed.

    The caller holds the per-market service lock. A new universe identity or
    ADR threshold gets its own state. Writes are atomic; crashes can repeat a
    symbol, but cannot skip symbols whose attempt was never recorded.
    """

    SCOPE = "twse-tpex-nyse-nasdaq-american-ordinary-v2"

    def __init__(self, directory: Path, market: str, threshold: float,
                 symbols: list[str], page_size: int) -> None:
        self.path = directory / f"{market}_{float(threshold).hex()}.json"
        self.symbols = list(dict.fromkeys(symbols))
        fingerprint_input = self.SCOPE + "\n" + "\n".join(self.symbols)
        self.fingerprint = hashlib.sha256(fingerprint_input.encode()).hexdigest()
        self.round = 1
        self.attempted: set[str] = set()
        self.evaluated: set[str] = set()
        try:
            if self.path.stat().st_size > 4_000_000:
                raise ValueError("oversized checkpoint")
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("checkpoint root must be a JSON object")
            attempted = raw.get("attempted_symbols")
            evaluated = raw.get("evaluated_symbols")
            if (raw.get("schema") != 1 or raw.get("fingerprint") != self.fingerprint or
                    type(raw.get("round")) is not int or raw["round"] < 1 or
                    not isinstance(attempted, list) or not isinstance(evaluated, list) or
                    not all(isinstance(value, str) for value in attempted + evaluated) or
                    not set(attempted).issubset(self.symbols) or
                    not set(evaluated).issubset(attempted)):
                raise ValueError("incompatible checkpoint")
            self.round = raw["round"]
            self.attempted, self.evaluated = set(attempted), set(evaluated)
        except (OSError, ValueError, TypeError, KeyError):
            pass
        if self.symbols and len(self.attempted) == len(self.symbols):
            self.round += 1
            self.attempted.clear()
            self.evaluated.clear()
        self.page_start = len(self.attempted)
        self.page_symbols = [symbol for symbol in self.symbols if symbol not in self.attempted][:page_size]
        self._save()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".{self.path.name}.{uuid4().hex}.tmp")
        try:
            temporary.write_text(json.dumps({
                "schema": 1, "fingerprint": self.fingerprint, "round": self.round,
                "attempted_symbols": sorted(self.attempted),
                "evaluated_symbols": sorted(self.evaluated),
            }, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)

    def mark_attempt(self, symbol: str) -> None:
        if symbol not in self.page_symbols:
            raise ValueError("symbol is not in this scan page")
        self.attempted.add(symbol)
        self._save()

    def mark_evaluated(self, symbols: set[str]) -> None:
        self.evaluated.update(symbols & self.attempted)
        self._save()

    def fields(self) -> dict[str, Any]:
        return {
            "coverage_total_count": len(self.symbols),
            "coverage_scanned_count": len(self.attempted),
            "coverage_evaluated_count": len(self.evaluated),
            "coverage_remaining_count": len(self.symbols) - len(self.attempted),
            "coverage_round": self.round,
            "scan_page_start": self.page_start,
            "scan_page_size": len(self.page_symbols),
            "universe_fingerprint": self.fingerprint,
        }


@dataclass
class _Slot:
    job_id: str = ""
    threshold: float = 0.0
    worker_live: bool = False
    completed_monotonic: float = 0.0
    state: dict[str, Any] = field(default_factory=dict)


class BackgroundScanManager:
    """Single process / one uvicorn worker; TW and US have independent slots."""

    def __init__(
        self,
        scan: Callable[[str, float, bool, Progress], Snapshot],
        read_cache: Callable[[str, float], Snapshot | None],
        *, timeout_seconds: float = 180,
        cache_ttl_seconds: float = 300,
        page_interval_seconds: float = 60,
        failure_cooldown_seconds: float = 30,
        now: Callable[[], datetime] | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.scan = scan
        self.read_cache = read_cache
        self.timeout_seconds = timeout_seconds
        self.cache_ttl_seconds = cache_ttl_seconds
        self.page_interval_seconds = page_interval_seconds
        self.failure_cooldown_seconds = failure_cooldown_seconds
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.monotonic = monotonic
        self._lock = threading.Lock()
        self._slots: dict[str, _Slot] = {}
        self._snapshots: dict[tuple[str, float], Snapshot] = {}

    def _iso(self) -> str:
        return self.now().isoformat()

    def _fresh(self, snapshot: Snapshot) -> bool:
        try:
            timestamp = datetime.fromisoformat(snapshot["generated_at"].replace("Z", "+00:00"))
            age = (self.now() - timestamp).total_seconds()
            # Partial source warnings are disclosed by stale=true, but do not
            # make every subsequent read immediately launch another full scan.
            remaining = snapshot.get("coverage_remaining_count")
            ttl = (min(self.cache_ttl_seconds, self.page_interval_seconds)
                   if type(remaining) is int and remaining > 0 else self.cache_ttl_seconds)
            return 0 <= age < ttl
        except (ValueError, TypeError, KeyError):
            return False

    def poll(self, market: str, threshold: float, force: bool = False) -> tuple[int, Snapshot]:
        """Return immediately; repeated polling never restarts an active job."""
        launch: tuple[str, bool] | None = None
        with self._lock:
            slot = self._slots.setdefault(market, _Slot())
            snapshot = self._snapshots.get((market, threshold))
            cooldown = (slot.state.get("status") == "failed" and
                        self.monotonic() - slot.completed_monotonic < self.failure_cooldown_seconds)
            needs_scan = force or snapshot is None or not self._fresh(snapshot)
            if not slot.worker_live and not cooldown and needs_scan:
                job_id = uuid4().hex
                slot.job_id, slot.threshold, slot.worker_live = job_id, threshold, True
                stamp = self._iso()
                slot.state = {
                    "job_id": job_id, "status": "queued", "stage": "queued",
                    "started_at": None, "updated_at": stamp, "completed_at": None,
                    "completed_count": 0, "total_count": 0, "evaluated_count": 0,
                    "adr_match_count": 0, "failed_count": 0, "universe_count": 0,
                    "error": None,
                }
                launch = (job_id, force)
            state = dict(slot.state)
            active = state.get("status") in {"queued", "running"}
            if snapshot is not None:
                # Do not rewrite generated_at; it is the original scan time.
                snapshot = dict(snapshot)
                snapshot["stale"] = (bool(snapshot.get("stale")) or active or
                                     state.get("status") == "failed" or not self._fresh(snapshot))
            status_code = 200 if snapshot is not None else (503 if state.get("status") == "failed" else 202)
            envelope = {"market": market, "scan": state, "snapshot": snapshot, "retry_after_seconds": 3}

        if launch is not None:
            job_id, force = launch
            try:
                worker = threading.Thread(
                    target=self._run, args=(market, threshold, job_id, force),
                    name=f"market-scan-{market}-{job_id[:8]}", daemon=True,
                )
                worker.start()
            except Exception as exc:
                self._finish_failure(market, job_id, f"無法啟動背景掃描：{exc}")
                with self._lock:
                    slot.worker_live = False
                return self.poll(market, threshold)
        return status_code, envelope

    def _progress(self, market: str, job_id: str, **updates: Any) -> None:
        with self._lock:
            slot = self._slots[market]
            if slot.job_id != job_id or slot.state.get("status") not in {"queued", "running"}:
                raise ScanCancelled("掃描已逾時或結束，忽略遲到資料。")
            allowed = {"stage", "completed_count", "total_count", "evaluated_count",
                       "adr_match_count", "failed_count", "universe_count",
                       "coverage_total_count", "coverage_scanned_count", "coverage_evaluated_count",
                       "coverage_remaining_count", "coverage_round", "scan_page_start",
                       "scan_page_size", "universe_fingerprint"}
            slot.state.update({key: value for key, value in updates.items() if key in allowed})
            slot.state.update(status="running", updated_at=self._iso())

    def _finish_failure(self, market: str, job_id: str, error: str, *, timed_out: bool = False) -> None:
        with self._lock:
            slot = self._slots[market]
            if slot.job_id != job_id or slot.state.get("status") not in {"queued", "running"}:
                return
            stamp = self._iso()
            slot.state.update(status="failed", stage="timed_out" if timed_out else "failed",
                              error=error[:1000], updated_at=stamp, completed_at=stamp)
            slot.completed_monotonic = self.monotonic()

    def _run(self, market: str, threshold: float, job_id: str, force: bool) -> None:
        timer = threading.Timer(
            self.timeout_seconds,
            lambda: self._finish_failure(
                market, job_id, f"市場掃描超過 {self.timeout_seconds:g} 秒；保留既有快照，請稍後重試。",
                timed_out=True,
            ),
        )
        timer.daemon = True
        timer.start()
        try:
            with self._lock:
                slot = self._slots[market]
                if slot.job_id != job_id or slot.state.get("status") != "queued":
                    raise ScanCancelled("啟動前背景掃描已逾時。")
                stamp = self._iso()
                slot.state.update(started_at=stamp, updated_at=stamp,
                                  status="running", stage="reading_cache")
            cached = self.read_cache(market, threshold)
            if cached is not None:
                self._progress(market, job_id, stage="reading_cache")
                with self._lock:
                    if self._slots[market].state.get("status") not in {"queued", "running"}:
                        raise ScanCancelled("快照讀取完成時工作已逾時。")
                    self._snapshots.setdefault((market, threshold), cached)
            result = self.scan(
                market, threshold, force,
                lambda **updates: self._progress(market, job_id, **updates),
            )
            with self._lock:
                slot = self._slots[market]
                if slot.job_id != job_id or slot.state.get("status") not in {"queued", "running"}:
                    return  # A deadline cannot be undone by a late result.
                self._snapshots[market, threshold] = result
                stamp = self._iso()
                def count(value: Any, fallback: int = 0) -> int:
                    return value if type(value) is int and value >= 0 else fallback
                universe = count(result.get("universe_count"))
                total = min(count(result.get("scan_pool_size"), universe), universe)
                missing = result.get("missing_symbols")
                failed = min(len(missing) if isinstance(missing, list) else 0, total)
                # Legacy snapshots do not prove how many were evaluated. Keep
                # unknown counters at zero instead of inventing scan evidence.
                evaluated = min(count(result.get("evaluated_count")), total - failed)
                adr_matches = min(count(result.get("adr_match_count")), evaluated)
                slot.state.update(
                    status="completed", stage="completed", updated_at=stamp,
                    completed_at=stamp, error=None,
                    completed_count=total, total_count=total,
                    evaluated_count=evaluated, adr_match_count=adr_matches,
                    failed_count=failed, universe_count=universe,
                )
                for field_name in (
                    "coverage_total_count", "coverage_scanned_count", "coverage_evaluated_count",
                    "coverage_remaining_count", "coverage_round", "scan_page_start",
                    "scan_page_size", "universe_fingerprint",
                ):
                    if field_name in result:
                        slot.state[field_name] = result[field_name]
                slot.completed_monotonic = self.monotonic()
                # All disk/provider/calculation work has returned. Publish the
                # completed state and release its slot atomically so a different
                # ADR threshold never sees 202 + completed + null snapshot.
                # An expired job never enters this branch and retains its slot
                # until the actually blocked worker reaches finally below.
                slot.worker_live = False
        except ScanCancelled:
            pass
        except Exception as exc:
            LOGGER.exception("Background market scan failed for %s", market)
            self._finish_failure(market, job_id, str(exc) or type(exc).__name__)
        finally:
            timer.cancel()
            with self._lock:
                slot = self._slots[market]
                if slot.job_id == job_id:
                    slot.worker_live = False

