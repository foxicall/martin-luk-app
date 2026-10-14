#!/usr/bin/env python3
"""Compare the production Python/embedded-JS engines without a server or SDK.

Cases isolate risk thresholds, hard-stop priority, finalized closes, exposure,
integer trim quantities and previously observed breakeven state.
"""
from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.engine.exit_engine import ExitAdvisoryEngine, ExitConfig, Position, QuoteSnapshot


def main() -> int:
    node = shutil.which("node")
    if node is None:
        print("Node.js is required for production JavaScript parity checks.", file=sys.stderr)
        return 2
    now = datetime(2026, 10, 13, 15, 0, tzinfo=timezone.utc)
    prior_close = datetime(2026, 10, 12, 20, 0, tzinfo=timezone.utc)
    holding = Position("parity", "NVDA", "us", 100.0, 100, 98.0)
    quote = QuoteSnapshot("NVDA", "NVIDIA demo", "us", 102.0, 101.0, 99.0, 95.0,
                          102.0, True, now, prior_close, "offline parity fixture", True)
    cases: list[tuple[str, Position, QuoteSnapshot, float, float]] = []

    def case(name: str, position: Position = holding, snapshot: QuoteSnapshot = quote,
             equity: float = 50_000.0, threshold: float = 20.0) -> None:
        cases.append((name, position, snapshot, equity, threshold))

    case("ordinary hold")
    for price in (98.0, 97.9, 104.0, 106.0, 110.0, 120.0):
        case(f"observed price {price}", snapshot=replace(quote, current_price=price))
    observed = replace(holding, peak_r=3.0, trailing_stop=100.0)
    case("retrace retains breakeven", observed, replace(quote, current_price=103.0))
    case("breakeven equality exits", observed, replace(quote, current_price=100.0))
    case("intraday below EMA does not imply final close", snapshot=replace(quote, current_price=99.0, close_confirmed=False))
    case("finalized close equal to EMA holds", snapshot=replace(quote, last_close=101.0))
    case("finalized close below EMA beats 3R trim", snapshot=replace(quote, current_price=106.0, last_close=100.0))
    case("hard stop beats final EMA reason", snapshot=replace(quote, current_price=98.0, last_close=90.0))
    case("qualified main uptrend uses 21 EMA", replace(observed, main_uptrend=True, trailing_ema=21), replace(quote, last_close=100.0))
    case("without main uptrend reverts to 9 EMA", replace(observed, trailing_ema=21), replace(quote, last_close=100.0))
    case("less than observed 3R cannot widen to 50 EMA", replace(holding, peak_r=2.0, main_uptrend=True, trailing_ema=50), replace(quote, last_close=100.0))
    case("21 EMA finalized weakness exits", replace(observed, main_uptrend=True, trailing_ema=21), replace(quote, last_close=98.0))
    case("50 EMA health takes priority with inverted EMAs", snapshot=replace(quote, ema9=90.0, ema21=110.0, ema50=105.0, close_confirmed=False))
    for shares in (250, 260, 350, 351):
        case(f"exposure {shares} shares", replace(holding, shares=shares),
             replace(quote, current_price=100.0, is_large_liquid=False), equity=100_000.0)
    for shares in range(1, 45):
        case(f"whole-share trim {shares}", replace(holding, shares=shares), replace(quote, current_price=106.0))
    wide_basis = replace(holding, initial_stop=50.0, trailing_stop=50.0)
    case("euphoria exact20 does not trim", wide_basis, replace(quote, current_price=120.0, ema9=100.0))
    case("euphoria greater20 trims", wide_basis, replace(quote, current_price=120.1, ema9=100.0))
    case("configured15 strict equality", wide_basis, replace(quote, current_price=115.0, ema9=100.0), threshold=15.0)
    case("configured15 exceeded", wide_basis, replace(quote, current_price=115.1, ema9=100.0), threshold=15.0)
    case("previous profitable hard stop never decreases", replace(holding, trailing_stop=103.0), replace(quote, current_price=104.0))
    case("decimal arithmetic at exact3R", replace(holding, entry_price=105.0, initial_stop=102.9, trailing_stop=102.9), replace(quote, current_price=111.3))

    html = (ROOT / "preview/index.html").read_text(encoding="utf-8")
    scripts = []
    for identifier in ("strategy-core", "portfolio-core"):
        match = re.search(rf'<script id="{identifier}">(.*?)</script>', html, re.S)
        if match is None:
            raise ValueError(f"Missing {identifier} production script")
        scripts.append(match.group(1))
    fixtures = []
    for name, position, snapshot, equity, threshold in cases:
        diagnosis, _ = ExitAdvisoryEngine(ExitConfig(threshold)).analyze(position, snapshot, equity)
        fixtures.append({"name": name, "position": position.to_dict(), "quote": snapshot.to_dict(),
                         "equity": equity, "threshold": threshold, "expected": diagnosis.to_dict()})
    harness = r"""
const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
const payload=JSON.parse(fs.readFileSync(0,'utf8'));
for(const source of payload.scripts)vm.runInThisContext(source);
for(const fixture of payload.fixtures){
  const actual=globalThis.PortfolioCore.diagnose(fixture.position,fixture.quote,fixture.equity,fixture.threshold);
  const expected=fixture.expected;
  for(const key of ['action','health','over_exposure','effective_trailing_ema','trim_shares'])assert.equal(actual[key],expected[key],fixture.name+':'+key);
  assert.deepEqual(actual.reason_codes,expected.reason_codes,fixture.name+': reasons');
  for(const key of ['current_r','peak_r','unrealized_pnl','position_value','exposure_pct','exposure_cap_pct','trailing_stop'])assert.ok(Math.abs(actual[key]-expected[key])<=1e-12*Math.max(1,Math.abs(expected[key])),fixture.name+':'+key);
  for(const multiple of ['1','2','3','5','10'])assert.ok(Math.abs(actual.targets[multiple]-expected.targets[multiple])<=1e-12*Math.max(1,Math.abs(expected.targets[multiple])),fixture.name+':target'+multiple);
}
console.log(payload.fixtures.length+' Python/HTML portfolio parity scenarios passed.');
"""
    result = subprocess.run([node, "-e", harness], input=json.dumps({"scripts": scripts, "fixtures": fixtures}),
                            text=True, capture_output=True, timeout=30, check=False)
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Portfolio parity check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
