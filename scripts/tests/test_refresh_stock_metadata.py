"""Metadata assembly fixtures; no network or fresh-market-data claims."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd

from backend.engine.models import Market, Stock
from scripts.refresh_stock_metadata import main, merge_market, read_records


def record(market: str, symbol: str, **extra: object) -> dict[str, object]:
    return {
        'market': market, 'symbol': symbol,
        'code': symbol.split('.')[0] if market == 'TW' else symbol,
        'name_zh': '原中文名', 'name_full_zh': '', 'name_en': 'Previous English',
        'abbr_en': 'Known', 'aliases': ['Curated alias'], 'short_codes': ['KNOWN'],
        **extra,
    }


class RefreshMetadataTests(unittest.TestCase):
    def test_merge_excludes_historical_adr_additions_and_keeps_curated_translations(self):
        old = [record('US', 'NVDA', name_zh='輝達'), record('US', 'TSM', name_zh='台積電ADR')]
        rows, additions = merge_market(old, [Stock('NVDA', 'NVIDIA Common Stock', '', Market.US)], 'US')
        self.assertEqual([row['symbol'] for row in rows], ['NVDA'])
        self.assertEqual(additions, [])
        self.assertEqual(rows[0]['name_zh'], '輝達')
        self.assertEqual(rows[0]['name_full_zh'], '')
        self.assertIn('Curated alias', rows[0]['aliases'])
        self.assertIn('Previous English', rows[0]['aliases'])
        self.assertEqual(old[0]['aliases'], ['Curated alias'])

    def test_new_otc_record_has_four_digit_code_and_does_not_invent_english_name(self):
        rows, _ = merge_market([], [Stock('6488.TWO', '環球晶', '半導體業', Market.TW)], 'TW')
        self.assertEqual(rows[0]['symbol'], '6488.TWO')
        self.assertEqual(rows[0]['code'], '6488')
        self.assertEqual(rows[0]['name_zh'], '環球晶')
        self.assertEqual(rows[0]['name_en'], '')
        self.assertEqual(rows[0]['name_full_zh'], '')

    def test_new_us_record_does_not_invent_legal_chinese_name(self):
        rows, _ = merge_market([], [Stock('NEW', 'New Ordinary Shares', '', Market.US)], 'US')
        self.assertEqual(rows[0]['name_en'], 'New Ordinary Shares')
        self.assertEqual(rows[0]['name_full_zh'], '')

    def test_reader_accepts_tw_and_two_but_rejects_wrong_suffix(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stocks.json'
            rows = [record('TW', '2330.TW'), record('TW', '6488.TWO')]
            path.write_text(json.dumps(rows))
            self.assertEqual(read_records(path), rows)
            path.write_text(json.dumps([record('TW', '6488.OTC')]))
            with self.assertRaises(ValueError):
                read_records(path)

    def provider(self, *, complete: bool = True) -> SimpleNamespace:
        return SimpleNamespace(
            load=lambda market, **_: [Stock('NVDA', 'NVIDIA Common Stock', '', Market.US)] if market is Market.US
                    else [Stock('6488.TWO', '環球晶', '', Market.TW)],
            sources={Market.US: 'cache: real upstream (2026-10-01)', Market.TW: 'cache: real ISIN (2026-10-02)'},
            captured_at={Market.US: pd.Timestamp('2026-10-01T00:00:00Z'),
                         Market.TW: pd.Timestamp('2026-10-02T00:00:00Z')},
            coverage_complete={Market.US: complete, Market.TW: complete},
            coverage_warnings={Market.US: ['Name-based classifier; not a verified exact taxonomy'], Market.TW: []},
            statistics={Market.US: {'scope': 'us_nyse_nasdaq_nyse_american_common', 'classification_verified': False},
                        Market.TW: {'scope': 'tw_twse_tpex_common', 'classification_verified': True}},
            warnings=['Name-based classifier; not a verified exact taxonomy'],
        )

    def run_main(self, provider: SimpleNamespace, path: Path, *flags: str) -> int:
        with patch('backend.engine.data_loader.UniverseProvider', return_value=provider), \
                patch('scripts.refresh_stock_metadata.validate_records', side_effect=lambda rows: rows), \
                redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            return main(['--output', str(path), *flags])

    def test_partial_refresh_rejected_before_overwriting_either_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stocks_master.json'
            original = json.dumps([record('US', 'NVDA'), record('TW', '2330.TW')])
            path.write_text(original)
            sources = path.with_name('stocks_master_sources.json')
            sources.write_text('{"schema_version":1,"sources":{}}')
            self.assertEqual(self.run_main(self.provider(complete=False), path), 1)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(sources.read_text(), '{"schema_version":1,"sources":{}}')

    def test_explicit_partial_refresh_keeps_origin_time_and_drops_sp500_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stocks_master.json'
            path.write_text(json.dumps([record('US', 'NVDA'), record('US', 'TSM'), record('TW', '2330.TW')]))
            sources = path.with_name('stocks_master_sources.json')
            sources.write_text(json.dumps({'schema_version': 1, 'snapshot_date': '2026-10-15',
                'refreshed_at': '2026-10-15T00:00:00Z', 'additional_us_symbols': ['TSM'],
                'coverage': {'us_sp500_snapshot': 500, 'us_additional_major': 1}, 'sources': {}}))
            self.assertEqual(self.run_main(self.provider(complete=False), path, '--offline', '--allow-partial'), 0)
            metadata = json.loads(sources.read_text())
            self.assertEqual(metadata['schema_version'], 2)
            self.assertEqual(metadata['snapshot_date'], '2026-10-01')
            self.assertEqual(metadata['sources']['us']['captured_at'], '2026-10-01T00:00:00+00:00')
            self.assertFalse(metadata['sources']['us']['coverage_complete'])
            self.assertIn('assembled_at', metadata)
            self.assertNotIn('refreshed_at', metadata)
            self.assertNotIn('additional_us_symbols', metadata)
            self.assertNotIn('us_sp500_snapshot', metadata['coverage'])
            self.assertNotIn('TSM', [row['symbol'] for row in json.loads(path.read_text())])
            self.assertEqual(metadata['sources']['tw']['warnings'], [])

    def test_missing_source_timestamp_prevents_fake_current_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stocks_master.json'
            original = json.dumps([record('US', 'NVDA'), record('TW', '2330.TW')])
            path.write_text(original)
            provider = self.provider()
            provider.captured_at = {}
            self.assertEqual(self.run_main(provider, path), 1)
            self.assertEqual(path.read_text(), original)

    def test_single_market_refresh_does_not_stamp_unknown_other_origin_as_current(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'stocks_master.json'
            path.write_text(json.dumps([record('US', 'NVDA'), record('TW', '2330.TW')]))
            self.assertEqual(self.run_main(self.provider(), path, '--market', 'us'), 0)
            metadata = json.loads(path.with_name('stocks_master_sources.json').read_text())
            self.assertIsNone(metadata['snapshot_date'])
            self.assertEqual(metadata['sources']['us']['captured_at'], '2026-10-01T00:00:00+00:00')


if __name__ == '__main__':
    unittest.main()
