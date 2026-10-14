#!/usr/bin/env python3
"""Check the SDK-free preview's embedded JS, Dart mock parity and risk edges.

This does not claim to compile Flutter or replace Flutter widget tests. Node.js
evaluates the exact browser strategy script, independently of a DOM or network.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import shutil
import subprocess
import sys
from decimal import Decimal, ROUND_DOWN
from pathlib import Path


def dart_specs(source: str) -> dict[str, list[list[object]]]:
    """Read the fixed _MockSpec declarations; fail loudly if Dart mocks change."""
    declarations = re.findall(r"const _MockSpec\((.*?)\),", source)
    if len(declarations) != 16:
        raise ValueError("Expected 16 Dart mock declarations; update preview fixtures.")
    rows: list[list[object]] = []
    for declaration in declarations:
        tokens = re.findall(r"'(?:[^'\\]|\\.)*'|true|false|null|-?\d+(?:\.\d+)?", declaration)
        if len(tokens) != 10:
            raise ValueError(f"Unexpected Dart mock declaration: {declaration}")
        row: list[object] = []
        for token in tokens:
            if token.startswith("'"):
                row.append(ast.literal_eval(token))
            elif token == "true":
                row.append(True)
            elif token == "false":
                row.append(False)
            elif token == "null":
                row.append(None)
            else:
                row.append(float(token) if "." in token else int(token))
        rows.append(row)
    return {"tw": rows[:8], "us": rows[8:]}


def expected_plan(entry: str, stop: str, equity: str, large: bool, lot: int = 1) -> dict[str, object]:
    """An independent Python Decimal oracle for finite fixture values."""
    price, stop_price, capital = map(Decimal, (entry, stop, equity))
    risk = price - stop_price
    cap = Decimal(".35" if large else ".25")
    budget = capital * Decimal(".005")
    risk_shares = (budget / risk).to_integral_value(rounding=ROUND_DOWN)
    cap_shares = (capital * cap / price).to_integral_value(rounding=ROUND_DOWN)
    shares = int(min(risk_shares, cap_shares)) // lot * lot
    return {
        "shares": shares,
        "amount": float(price * shares),
        "riskAmount": float(risk * shares),
        "riskBudget": float(budget),
        "positionPercent": float(price * shares / capital * 100),
        "stopPercent": float(risk / price * 100),
        "capPercent": float(cap * 100),
        "targets": {str(r): float(price + risk * r) for r in (3, 5, 10)},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    node = shutil.which("node")
    if node is None:
        print("ERROR: Node.js is required to evaluate preview JavaScript.", file=sys.stderr)
        return 2
    try:
        root = args.project.resolve()
        html = (root / "preview/index.html").read_text(encoding="utf-8")
        dart = (root / "lib/services/candidate_repository.dart").read_text(encoding="utf-8")
        scripts = {}
        for name in ("strategy-core", "preview-ui"):
            match = re.search(rf'<script id="{name}">(.*?)</script>', html, re.S)
            if match is None:
                raise ValueError(f"Missing embedded {name} script")
            scripts[name] = match.group(1)
        fixture_inputs = [
            ("100", "98.5", "100000", True, 1),  # Inclusive lower stop boundary.
            ("100", "97", "100000", True, 1),  # Inclusive upper stop boundary.
            ("100", "98.5", "100000", False, 1),  # Smaller-stock exposure cap binds.
            ("105", "102.9", "100000", True, 1),  # Decimal subtraction/share boundary.
            ("100", "98", "100000", True, 1),  # Exact risk budget, no extra share.
            ("0.01", "0.00985", "100000", True, 1),  # Tiny prices, exact 1.5% boundary.
            ("100", "98", "1000000", False, 1000),  # Trading-lot floor, no rounded-up risk.
            ("100", "98", "800", True, 1),  # Too few shares to trim 10%–15%.
            ("100", "95", "100000", True, 1),  # Exact observed day-low 5% boundary.
            ("100", "99", "100000", False, 1),  # Day-low may be tighter than 1.5%.
        ]
        fixtures = [
            {
                "entry": float(entry), "stop": float(stop), "equity": float(equity),
                "large": large, "lot": lot,
                "expected": expected_plan(entry, stop, equity, large, lot),
            }
            for entry, stop, equity, large, lot in fixture_inputs
        ]
        payload = {"scripts": scripts, "specs": dart_specs(dart), "fixtures": fixtures}
        harness = r"""
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const payload = JSON.parse(fs.readFileSync(0,'utf8'));
for (const [name,source] of Object.entries(payload.scripts)) new vm.Script(source,{filename:name+'.js'});
vm.runInThisContext(payload.scripts['strategy-core']);
const api = globalThis.PreviewStrategy;
let checks = 0;
const test = (message, fn) => {fn();checks++;};
const approximately = (a,b) => assert.ok(Math.abs(a-b) <= 1e-10 * Math.max(1,Math.abs(b)),`${a} != ${b}`);
test('Dart mock declarations are synchronized',()=>assert.deepEqual(api.mockSpecs,payload.specs));
for (const market of ['tw','us']) {
  const candidates = api.mockCandidates(market), threshold = market === 'tw' ? 3.5 : 5, equity = market === 'tw' ? 1000000 : 50000;
  test(market+' contains 8 exact candidates',()=>assert.equal(candidates.length,8));
  test(market+' has two watchlist setups without stops',()=>assert.equal(candidates.filter(c=>c.status==='watchlist' && c.stop_price===null).length,2));
  for (const c of candidates) {
    test('candidate validation '+c.symbol,()=>assert.deepEqual(api.validateCandidate(c,market),c));
    if (c.status === 'confirmed') {
      test('risk invariant '+c.symbol,()=>{
        const p=api.calculate(c,equity);
        assert.ok(Number.isInteger(p.shares) && p.shares>0);
        assert.ok(p.riskAmount<=equity*.005+1e-10);
        assert.ok(p.amount<=equity*(c.is_large_liquid?.35:.25)+1e-10);
        assert.ok(p.stopPercent>=1.5 && p.stopPercent<=3);
      });
    } else test('no fabricated order '+c.symbol,()=>assert.throws(()=>api.calculate(c,equity)));
  }
  test(market+' ADR equality is inclusive',()=>assert.equal(api.filteredCandidates(candidates,candidates[0].adr_percent,'rs',equity).some(c=>c.symbol===candidates[0].symbol),true));
  for (const sort of ['adr','rs','position']) test(market+' sort '+sort,()=>{
    const rows=api.filteredCandidates(candidates,threshold,sort,equity);
    const score=c=>sort==='adr'?c.adr_percent:sort==='rs'?c.rs_score:c.status==='confirmed'?api.calculate(c,equity).positionPercent:0;
    rows.forEach((c,i)=>{assert.ok(c.adr_percent>=threshold);if(i>0)assert.ok(score(rows[i-1])>=score(c));});
    assert.equal(rows.slice(0,6).length,6);assert.equal(rows.slice(6).length,2);
  });
}
for (const f of payload.fixtures) test('Decimal oracle '+JSON.stringify(f),()=>{
  const c={status:'confirmed',entry_price:f.entry,stop_price:f.stop,is_large_liquid:f.large};
  const p=api.calculate(c,f.equity,f.lot);
  assert.equal(p.shares,f.expected.shares);
  for(const key of ['amount','riskAmount','riskBudget','positionPercent','stopPercent','capPercent']) approximately(p[key],f.expected[key]);
  for(const r of [3,5,10]) approximately(p.targets[r],f.expected.targets[r]);
  if(p.trimShares>0) assert.ok(p.trimShares/p.shares >= .10 && p.trimShares/p.shares <= .15);
});
const base={...api.mockCandidates('us')[0]};
for(const equity of [0,-1,NaN,Infinity,'50000']) test('invalid equity '+equity,()=>assert.throws(()=>api.calculate(base,equity)));
for(const stop of [base.entry_price,0,base.entry_price*.949]) test('invalid stop '+stop,()=>assert.throws(()=>api.calculate({...base,stop_price:stop,day_low:stop},50000)));
test('alternate stop requires real minute-bar evidence',()=>assert.throws(()=>api.calculate({...base,stop_source:'entry_bar_low',day_low:base.entry_price*.9,entry_bar_low:null},50000)));
test('alternate stop within 1.5-3 percent uses actual low',()=>{
  const c={...base,stop_source:'entry_bar_low',day_low:126,entry_bar_low:137.2,stop_price:137.2};
  approximately(api.calculate(c,50000).stopPercent,2);
});
for(const stop of [139,135]) test('invalid alternate stop '+stop,()=>assert.throws(()=>api.calculate({...base,stop_source:'entry_bar_low',day_low:126,entry_bar_low:stop,stop_price:stop},50000)));
test('insufficient equity',()=>assert.throws(()=>api.calculate(base,1)));
test('trim below valid integer range is zero',()=>assert.equal(api.calculate({...base,entry_price:100,trigger_price:100,stop_price:98,day_low:98},800).trimShares,0));
for(const lot of [0,-1,1.5,Infinity]) test('invalid lot '+lot,()=>assert.throws(()=>api.calculate(base,50000,lot)));
test('unsafe integer share count',()=>assert.throws(()=>api.calculate({...base,entry_price:.01,trigger_price:.01,stop_price:.0098,day_low:.0098},1e20)));
const snapshot={market:'us',source:'mock fixture',universe_count:8,stale:false,warnings:[],generated_at:api.demoTime,candidates:api.mockCandidates('us'),missing_symbols:[]};
test('valid API snapshot',()=>assert.equal(api.validateSnapshot(snapshot,'us').candidates.length,8));
test('duplicate symbols rejected',()=>assert.throws(()=>api.validateSnapshot({...snapshot,candidates:[base,base]},'us')));
test('wrong market rejected',()=>assert.throws(()=>api.validateSnapshot(snapshot,'tw')));
test('number strings rejected',()=>assert.throws(()=>api.validateCandidate({...base,entry_price:'140'},'us')));
test('missing confirmed stop rejected',()=>assert.throws(()=>api.validateCandidate({...base,stop_price:null},'us')));
test('timestamps without timezone rejected',()=>assert.throws(()=>api.validateCandidate({...base,data_timestamp:'2026-10-13T06:00:00'},'us')));
test('overflowing calendar date rejected',()=>assert.throws(()=>api.validateCandidate({...base,data_timestamp:'2026-02-31T06:00:00Z'},'us')));
test('small universe rejected',()=>assert.throws(()=>api.validateSnapshot({...snapshot,universe_count:1},'us')));
test('invalid cache status rejected',()=>assert.throws(()=>api.validateSnapshot({...snapshot,stale:'false'},'us')));
test('unknown signal state rejected',()=>assert.throws(()=>api.validateCandidate({...base,status:'buy-now'},'us')));
console.log(`${checks} preview checks passed: syntax, Dart mocks, ADR/pagination, exact position risk, API validation.`);
"""
        result = subprocess.run(
            [node, "-e", harness], input=json.dumps(payload, ensure_ascii=False),
            text=True, capture_output=True, check=False, timeout=30,
        )
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        return result.returncode
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
