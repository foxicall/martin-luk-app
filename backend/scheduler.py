"""Optional server scanner for cron / Windows Task Scheduler / a foreground loop.

No job is started by importing the API. This CLI warms the same JSON cache read
by Uvicorn and uses exchange calendars rather than weekday-only scheduling.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import threading

from .api import RecommendationService
from .engine.data_loader import _atomic_text
from .engine.models import Market

LOGGER = logging.getLogger(__name__)


def run_cycle(service: RecommendationService, markets: list[Market], scheduled: bool,
              demo: bool = False) -> int:
    """Persist deduplication only after a successful scan, so failures retry."""
    slot_path = service.settings.cache_dir / "schedule_slots.json"
    try:
        slots = json.loads(slot_path.read_text(encoding="utf-8"))
        if not isinstance(slots, dict) or any(not isinstance(key, str) or not isinstance(value, str)
                                               for key, value in slots.items()):
            slots = {}
    except (OSError, ValueError, TypeError):
        slots = {}
    failures = 0
    for market in markets:
        try:
            now = datetime.now(timezone.utc)
            slot_key = None
            if scheduled:
                slot = service.calendar.scheduled_slot(market, now)
                if slot is None:
                    continue
                context = service.calendar.context(market, now)
                slot_key = f"{context.session_date.date()}:{slot}"
                if slots.get(market.value) == slot_key:
                    continue
            result = service.get_candidates(
                market, 3.5 if market is Market.TW else 5.0, force_refresh=True, demo=demo
            )
            print(f"{market.value}: {len(result.candidates)} candidates / {result.universe_count} stocks; "
                  f"generated_at={result.generated_at.isoformat()}")
            if slot_key is not None and not demo:
                slots[market.value] = slot_key
                _atomic_text(slot_path, json.dumps(slots, ensure_ascii=False, indent=2))
        except Exception as exc:
            failures += 1
            LOGGER.error("%s scan failed: %s", market.value, exc)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description="TWSE / TPEx / NYSE / Nasdaq / NYSE American cache warmup and exchange-aware scheduler")
    parser.add_argument("--market", choices=("tw", "us", "all"), default="all")
    parser.add_argument("--scheduled", action="store_true", help="Only scan the requested exchange schedule slots")
    parser.add_argument("--loop", action="store_true", help="Check the exchange schedules every 30 seconds")
    parser.add_argument("--demo", action="store_true", help="Explicit fictitious demo; does not write live response caches")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    markets = list(Market) if args.market == "all" else [Market(args.market)]
    service = RecommendationService()
    try:
        if not args.loop:
            return 1 if run_cycle(service, markets, args.scheduled, args.demo) else 0
        stop = threading.Event()
        while not stop.is_set():
            run_cycle(service, markets, scheduled=True, demo=args.demo)
            stop.wait(30)
    except KeyboardInterrupt:
        LOGGER.info("Scheduler stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
