"""Offline fixtures: test real parsers and cache semantics, never live evidence."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from backend.engine.data_loader import CacheError, DataSourceError, UniverseProvider
from backend.engine.listed_universe import parse_nasdaq_directory, parse_tw_isin
from backend.engine.models import Market

NASDAQ_HEADER = "Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares\n"
OTHER_HEADER = "ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol\n"


def nasdaq(*rows: tuple[str, str, str, str]) -> str:
    return NASDAQ_HEADER + "\n".join(
        f"{symbol}|{name}|Q|{test}|N|100|{etf}|N"
        for symbol, name, etf, test in rows
    ) + "\nFile Creation Time: 1015202610:00|||||||\n"


def other(*rows: tuple[str, str, str]) -> str:
    return OTHER_HEADER + "\n".join(
        f"{symbol}|{name}|{exchange}|{symbol}|N|100|N|{symbol}"
        for symbol, name, exchange in rows
    ) + "\nFile Creation Time: 1015202610:00|||||||\n"


def isin(*rows: tuple[str, str, str, str, str]) -> str:
    return '<html><table><tr><th>有價證券代號及名稱</th></tr>' + ''.join(
        '<tr>' + ''.join(f'<td>{cell}</td>' for cell in
                        [f'{code}\u3000{name}', 'TW0000000000', '2000/01/01', listing, '半導體業', cfi, '']) + '</tr>'
        for code, name, listing, cfi, _ in rows
    ) + '</table></html>'


class ListedParserTests(unittest.TestCase):
    def test_nasdaq_filters_etf_depositary_preference_units_warrants_and_unknown(self):
        text = nasdaq(
            ('NVDA', 'NVIDIA Corporation - Common Stock', 'N', 'N'),
            ('QQQ', 'Index Fund Common Shares', 'Y', 'N'),
            ('TEST', 'Test Common Stock', 'N', 'Y'),
            ('ADR', 'Foreign American Depositary Shares', 'N', 'N'),
            ('PREF', 'Example Preferred Stock', 'N', 'N'),
            ('WARR', 'Example Common Stock Warrants', 'N', 'N'),
            ('RIGHT', 'Example Common Stock Rights', 'N', 'N'),
            ('UNIT', 'Example Common Units', 'N', 'N'),
            ('UNKW', 'Unclassified Corporate Security', 'N', 'N'),
            ('ORD', 'Example Class A Ordinary Shares', 'N', 'N'),
            ('NVDA', 'NVIDIA Corporation - Common Stock', 'N', 'N'),
        )
        parsed = parse_nasdaq_directory(text, source='nasdaq')
        self.assertEqual([s.symbol for s in parsed.stocks], ['NVDA', 'ORD'])
        self.assertEqual(parsed.statistics['unknown_security_type'], 1)
        self.assertEqual(parsed.statistics['excluded_test_or_etf'], 2)
        self.assertEqual(parsed.statistics['excluded_security_type'], 5)
        self.assertEqual(parsed.statistics['duplicates'], 1)
        self.assertEqual(parsed.statistics['rows'], 11)
        self.assertFalse(parsed.statistics['classification_verified'])

    def test_other_exchange_scope_and_share_class_yahoo_spelling(self):
        parsed = parse_nasdaq_directory(other(
            ('BRK.B', 'Berkshire Hathaway Class B Common Stock', 'N'),
            ('COMP', 'Company Common Shares', 'A'),
            ('ARCA', 'Arca Common Stock', 'P'),
            ('CBOE', 'Cboe Common Stock', 'Z'),
            ('IEX', 'Outside Common Stock', 'V'),
        ), source='other')
        self.assertEqual([s.symbol for s in parsed.stocks], ['BRK-B', 'COMP'])
        self.assertEqual(parsed.statistics['excluded_exchange'], 3)

    def test_closed_end_funds_and_beneficial_interests_are_not_operating_shares(self):
        parsed = parse_nasdaq_directory(other(
            ('CEF', 'Income Fund Inc. Common Stock', 'N'),
            ('BEN', 'Income Trust Common Shares of Beneficial Interest', 'N'),
            ('INV', 'Example Investment Trust Common Stock', 'N'),
            ('REIT', 'Example Real Estate Investment Trust Common Stock', 'N'),
            ('TRST', 'Corporate Trust Inc. Common Stock', 'N'),
        ), source='other')
        self.assertEqual([s.symbol for s in parsed.stocks], ['REIT', 'TRST'])
        self.assertEqual(parsed.statistics['excluded_security_type'], 3)

    def test_truncated_directory_without_footer_is_rejected(self):
        text = NASDAQ_HEADER + 'NVDA|NVIDIA Common Stock|Q|N|N|100|N|N\n'
        with self.assertRaisesRegex(ValueError, 'File Creation Time'):
            parse_nasdaq_directory(text, source='nasdaq')

    def test_short_or_extra_width_stock_rows_are_rejected_even_with_footer(self):
        footer = 'File Creation Time: 1015202610:00|||||||\n'
        for row in (
            'NVDA|NVIDIA Common Stock|Q|N|N|100|N\n',
            'NVDA|NVIDIA Common Stock|Q|N|N|100|N|N|EXTRA\n',
        ):
            with self.subTest(row=row), self.assertRaisesRegex(ValueError, '欄位數'):
                parse_nasdaq_directory(NASDAQ_HEADER + row + footer, source='nasdaq')

    def test_stock_after_footer_is_rejected_but_short_footer_is_allowed(self):
        text = NASDAQ_HEADER + 'NVDA|NVIDIA Common Stock|Q|N|N|100|N|N\n' \
            + 'File Creation Time: 1015202610:00||||||\n'
        parsed = parse_nasdaq_directory(text, source='nasdaq')
        self.assertEqual([stock.symbol for stock in parsed.stocks], ['NVDA'])
        with self.assertRaisesRegex(ValueError, '結尾標記後'):
            parse_nasdaq_directory(text + 'AMD|AMD Common Stock|Q|N|N|100|N|N\n', source='nasdaq')

    def test_taiwan_listing_suffix_and_cfi_ordinary_stock(self):
        html = isin(
            ('2330', '台積電', '上市', 'ESVUFR', ''),
            ('6488', '環球晶', '上櫃', 'ESVUFR', ''),
            ('0050', '基金', '上市', 'CEOGEU', ''),
            ('9101', '存託憑證', '上市', 'ED', ''),
            ('2002', '特別股', '上市', 'EP', ''),
            ('2330', '台積電', '上市', 'ESVUFR', ''),
        )
        listed = parse_tw_isin(html, listing='listed')
        otc = parse_tw_isin(html, listing='otc')
        self.assertEqual([s.symbol for s in listed.stocks], ['2330.TW'])
        self.assertEqual([s.symbol for s in otc.stocks], ['6488.TWO'])
        self.assertEqual(listed.statistics['duplicates'], 1)
        self.assertTrue(otc.statistics['classification_verified'])

    def test_changed_or_empty_source_is_rejected_instead_of_empty_full_list(self):
        for text in ('<html>blocked</html>', NASDAQ_HEADER):
            with self.assertRaises(ValueError):
                parse_nasdaq_directory(text, source='nasdaq')
        with self.assertRaises(ValueError):
            parse_tw_isin('<html>blocked</html>', listing='listed')

    def test_twse_innovation_board_is_listed_but_emerging_board_is_not(self):
        parsed = parse_tw_isin(isin(
            ('2330', '台積電', '上市', 'ESVUFR', ''),
            ('9991', '創新示範公司', '上市臺灣創新板', 'ESVUFR', ''),
            ('9992', '興櫃示範公司', '興櫃', 'ESVUFR', ''),
            ('9993', '其他市場示範公司', '上櫃', 'ESVUFR', ''),
        ), listing='listed')
        self.assertEqual([s.symbol for s in parsed.stocks], ['2330.TW', '9991.TW'])


class ListedProviderTests(unittest.TestCase):
    def make_provider(self, path: str, **kwargs: object) -> UniverseProvider:
        fake_requests = SimpleNamespace(Session=lambda: SimpleNamespace(headers={}))
        with patch('backend.engine.data_loader.requests', fake_requests):
            return UniverseProvider(path, retries=1, **kwargs)

    def test_partial_source_failure_is_returned_with_warning_not_full_coverage(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            def source(url: str, **_: object) -> str:
                if url == provider.US_OTHER_URL:
                    raise DataSourceError('unit HTTP 429')
                return nasdaq(('NVDA', 'NVIDIA Common Stock', 'N', 'N'))
            with patch.object(provider, '_get_html', side_effect=source):
                self.assertEqual([s.symbol for s in provider.load(Market.US)], ['NVDA'])
            self.assertFalse(provider.coverage_complete[Market.US])
            self.assertEqual(provider.statistics[Market.US]['source_count'], 1)
            self.assertIn(provider.US_URL, provider.sources[Market.US])
            self.assertTrue(any('429' in warning for warning in provider.warnings))
            self.assertTrue(any('100%' in warning for warning in provider.warnings))
            self.assertFalse(provider.statistics[Market.US]['sources']['NYSE／NYSE American']['ok'])
            cached = self.make_provider(temp)
            with patch.object(cached, '_get_html', side_effect=AssertionError('cache should be used')):
                cached.load(Market.US)
            self.assertFalse(cached.coverage_complete[Market.US])
            self.assertEqual(cached.captured_at[Market.US], provider.captured_at[Market.US])

    def test_unknown_classification_is_counted_and_not_marked_full(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            responses = {
                provider.US_URL: nasdaq(('NVDA', 'NVIDIA Common Stock', 'N', 'N'),
                                       ('UNK', 'Unclassified', 'N', 'N')),
                provider.US_OTHER_URL: other(('BRK.B', 'Berkshire Common Stock', 'N')),
            }
            with patch.object(provider, '_get_html', side_effect=lambda url, **_: responses[url]):
                stocks = provider.load(Market.US)
            self.assertEqual([s.symbol for s in stocks], ['BRK-B', 'NVDA'])
            self.assertFalse(provider.coverage_complete[Market.US])
            self.assertEqual(provider.statistics[Market.US]['unknown_security_type'], 1)
            self.assertEqual(provider.statistics[Market.US]['source_count'], 2)

    def test_taiwan_both_sources_success_cache_scope_and_timestamp(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            responses = {
                provider.TW_URL: isin(('2330', '台積電', '上市', 'ESVUFR', '')),
                provider.TW_OTC_URL: isin(('6488', '環球晶', '上櫃', 'ESVUFR', '')),
            }
            with patch.object(provider, '_get_html', side_effect=lambda url, **_: responses[url]):
                stocks = provider.load(Market.TW)
            self.assertEqual([s.symbol for s in stocks], ['2330.TW', '6488.TWO'])
            self.assertTrue(provider.coverage_complete[Market.TW])
            payload = json.loads((Path(temp) / 'universe_tw.json').read_text())
            self.assertEqual(payload['schema_version'], 2)
            self.assertEqual(payload['scope'], 'tw_twse_tpex_common')
            self.assertIn(provider.TW_OTC_URL, payload['source'])
            captured = provider.captured_at[Market.TW]
            with patch.object(provider, '_get_html', side_effect=AssertionError('no network')):
                self.assertEqual(provider.load(Market.TW, offline=True), stocks)
            self.assertEqual(provider.captured_at[Market.TW], captured)

    def test_tw_partial_failure_keeps_otc_suffix_and_false_complete(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            with patch.object(provider, '_get_html', side_effect=[DataSourceError('unit timeout'),
                    isin(('6488', '環球晶', '上櫃', 'ESVUFR', ''))]):
                stocks = provider.load(Market.TW)
            self.assertEqual([s.symbol for s in stocks], ['6488.TWO'])
            self.assertFalse(provider.coverage_complete[Market.TW])

    def test_legacy_sp500_cache_and_wrong_scope_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            path = Path(temp) / 'universe_us.json'
            for schema, scope in ((1, None), (2, 'us_sp500')):
                path.write_text(json.dumps({'schema_version': schema, 'market': 'us', 'scope': scope,
                    'captured_at': '2026-10-15T00:00:00Z', 'source': 'old SP500',
                    'stocks': [{'symbol': 'NVDA', 'name': 'NVIDIA'}]}))
                with self.assertRaises(CacheError):
                    provider._read_cache(Market.US)
                with self.assertRaises(DataSourceError):
                    provider.load(Market.US, offline=True)

    def test_all_sources_fail_has_no_synthetic_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp)
            with patch.object(provider, '_get_html', side_effect=DataSourceError('unit unavailable')):
                with self.assertRaises(DataSourceError):
                    provider.load(Market.TW)
            self.assertFalse((Path(temp) / 'universe_tw.json').exists())

    def test_each_request_timeout_is_capped_at_eight_seconds(self):
        with tempfile.TemporaryDirectory() as temp:
            provider = self.make_provider(temp, timeout=25)
            seen: list[float] = []
            response = SimpleNamespace(encoding=None, text='fixture', raise_for_status=lambda: None)
            provider.session.get = lambda url, timeout: (seen.append(timeout), response)[1]
            self.assertEqual(provider._get_html(provider.US_URL), 'fixture')
            self.assertEqual(seen, [8.0])


if __name__ == '__main__':
    unittest.main()
