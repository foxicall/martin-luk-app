#!/usr/bin/env python3
"""Rebuild broad search identities from the bundled, dated public snapshots.

No network, quotes or signals. Existing curated bilingual aliases survive.
For a current official refresh, use refresh_stock_metadata.py instead. The
bundled Taiwan issuer file lacks CFI: unknown classifications are disclosed,
not promoted to verified ordinary shares by this import.
"""
from __future__ import annotations

from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.engine.listed_universe import parse_nasdaq_directory
from scripts.sync_stock_search import validate_records
from scripts.refresh_stock_metadata import merge_market, atomic_json


def main() -> None:
    directory = ROOT / 'metadata_snapshots'
    sources = json.loads((directory / 'SOURCES.json').read_text(encoding='utf-8'))
    for name, expected in sources['bundled_files'].items():
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f'Snapshot hash mismatch: {name}')
    old = json.loads((ROOT / 'stocks_master.json').read_text(encoding='utf-8'))
    us_stocks, statistics = [], {}
    for filename, source in [('nasdaqlisted.txt', 'nasdaq'), ('otherlisted.txt', 'other')]:
        parsed = parse_nasdaq_directory((directory / filename).read_text(encoding='utf-8'), source=source)
        us_stocks.extend(parsed.stocks)
        statistics[source] = parsed.statistics
    unique = {stock.symbol: stock for stock in us_stocks}
    us, _ = merge_market(old, unique.values(), 'US')

    cfi = {}
    for filename, suffix in [('twse_equities_common_20260326.csv', '.TW'),
                             ('tpex_equities_common_20260326.csv', '.TWO')]:
        with (directory / filename).open(encoding='utf-8', newline='') as handle:
            for row in csv.DictReader(handle):
                cfi[row['code'] + suffix] = row
    names = {}
    for row in json.loads((directory / 'tw_names_20261014.json').read_text(encoding='utf-8')):
        names[row['c'] + ('.TW' if row['m'] == 'listed' else '.TWO')] = row
    prior = {row['symbol']: row for row in old if row['market'] == 'TW'}
    tw = []
    unmatched, excluded = [], []
    with (directory / 'tw_stock_list_20261006.csv').open(encoding='utf-8', newline='') as handle:
        for item in csv.DictReader(handle):
            code = item['code']
            # This company file includes TDR issuers. Reject their 91xx codes,
            # and all six-digit TDRs, instead of treating every issuer as stock.
            if (not re.fullmatch(r'\d{4}', code) or code.startswith('91') or
                    item['market'] not in ('TWSE', 'OTC')):
                excluded.append(item['ticker'])
                continue
            symbol = code + ('.TW' if item['market'] == 'TWSE' else '.TWO')
            existing = prior.get(symbol, {})
            old_cfi = cfi.get(symbol)
            latest_name = names.get(symbol)
            short_name = (latest_name or {}).get('n') or (old_cfi or {}).get('name') or existing.get('name_zh') or item['name']
            aliases = list(existing.get('aliases', []))
            for value in [existing.get('name_zh'), existing.get('name_full_zh'), item['name']]:
                if value and value != short_name:
                    aliases.append(value)
            if old_cfi is None:
                unmatched.append(symbol)
            tw.append({
                'market': 'TW', 'symbol': symbol, 'code': code,
                'name_zh': short_name, 'name_full_zh': item['name'],
                'name_en': existing.get('name_en', ''), 'abbr_en': existing.get('abbr_en', ''),
                'aliases': list(dict.fromkeys(aliases)), 'short_codes': existing.get('short_codes', []),
            })
    records = sorted(tw + us, key=lambda row: (row['market'], row['symbol']))
    validate_records(records)
    counts = Counter(row['market'] for row in records)
    twse = sum(row['symbol'].endswith('.TW') for row in tw)
    provenance = {
        'schema_version': 2,
        'snapshot_date': '2026-10-06',
        'coverage': {'total': len(records), 'us': counts['US'], 'tw': counts['TW'],
                     'twse': twse, 'tpex': len(tw) - twse},
        'scope': {'us': 'NYSE / Nasdaq / NYSE American common-stock identities; conservative name classification',
                  'tw': 'TWSE + TPEx ordinary-stock search identities; excludes identified TDRs'},
        'is_current_complete_verified': False,
        'source_dates': {'us_directory_footer': '2026-10-14 07:00 (timezone unspecified)',
                         'tw_issuer_mirror_commit': '2026-10-06T15:01:35Z',
                         'tw_cfi_snapshot_commit': '2026-03-26T14:21:37Z',
                         'tw_name_enrichment_as_of': '2026-10-14'},
        'classification': {
            'us': statistics,
            'tw_cfi_matches_to_old_snapshot': len(tw) - len(unmatched),
            'tw_without_cfi_match': unmatched,
            'tw_excluded_tdr_or_nonfour_digit': excluded,
        },
        'sources': sources,
        'warnings': [
            '搜尋字典是掛牌身份快照，不含報價、指標、可交易狀態或即時買點。',
            '美股目錄沒有完整 CFI；名稱未能確認的證券已保守排除。不能保證零誤判或完整涵蓋。',
            '台股公司名錄可能沿用舊資料；已排除已辨識的 91xx/六碼存託憑證，尚未取得新逐檔 CFI。',
            f'台股 {len(unmatched)} 檔未與 2026-03-26 的同市場 CFI ES 身份匹配，不能宣稱類別已核證。',
            '上市／上櫃轉板、下市與改名可能改變成分。正式背景掃描重新向官方名錄取得普通股，不以字典冒充最新全池。',
        ],
        'field_policy': {
            'name_zh': 'Verified source short name or preserved curated name; US English source name is fallback.',
            'name_full_zh': 'Verified issuer company name when available; unknown US legal translations remain empty.',
            'name_en': 'Curated company name or source Security Name; never invented.',
            'quotes': 'No prices or signals in this file.',
        },
        'rebuild': 'python3 scripts/import_bundled_metadata.py; python3 scripts/sync_stock_search.py',
        'refresh': 'python3 scripts/refresh_stock_metadata.py --market all --allow-partial; python3 scripts/sync_stock_search.py',
    }
    atomic_json(ROOT / 'stocks_master.json', records)
    atomic_json(ROOT / 'stocks_master_sources.json', provenance)
    print(f'Bundled identities: US={counts["US"]}, TW={counts["TW"]} (TWSE={twse}, TPEx={len(tw)-twse}), total={len(records)}; not a verified current full universe.')


if __name__ == '__main__':
    main()
