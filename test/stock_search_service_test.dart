import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/stock_search_service.dart';

/// Small deterministic fixtures isolate ranking from membership updates.
List<StockItem> searchFixtures() => [
  StockItem(market: StockMarket.tw, symbol: '2330.TW', code: '2330',
    nameZh: '台積電', nameFullZh: '台灣積體電路製造股份有限公司',
    nameEn: 'Taiwan Semiconductor Manufacturing Co.', abbrEn: 'TSMC',
    aliases: ['臺積電', 'Taiwan Semiconductor'], shortCodes: ['TJD']),
  StockItem(market: StockMarket.tw, symbol: '2454.TW', code: '2454',
    nameZh: '聯發科', nameFullZh: '聯發科技股份有限公司',
    nameEn: 'MediaTek Inc.', abbrEn: 'MediaTek', shortCodes: ['LFK']),
  StockItem(market: StockMarket.tw, symbol: '2603.TW', code: '2603',
    nameZh: '長榮', nameFullZh: '長榮海運股份有限公司',
    nameEn: 'Evergreen Marine Corporation', abbrEn: 'Evergreen',
    aliases: ['長榮海運']),
  StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
    nameZh: '輝達', nameFullZh: '輝達公司',
    nameEn: 'NVIDIA Corporation', abbrEn: 'Nvidia', aliases: ['輝達半導體']),
  StockItem(market: StockMarket.us, symbol: 'AAPL', code: 'AAPL',
    nameZh: '蘋果', nameFullZh: '蘋果公司', nameEn: 'Apple Inc.', abbrEn: 'Apple'),
  StockItem(market: StockMarket.us, symbol: 'TSLA', code: 'TSLA',
    nameZh: '特斯拉', nameFullZh: '特斯拉公司', nameEn: 'Tesla, Inc.', abbrEn: 'Tesla'),
  StockItem(market: StockMarket.us, symbol: 'BRK-B', code: 'BRK-B',
    nameZh: '波克夏', nameFullZh: '波克夏海瑟威公司',
    nameEn: 'Berkshire Hathaway Inc.', abbrEn: 'Berkshire', aliases: ['BRK.B']),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('required bilingual queries resolve to a canonical market and symbol', () {
    final service = StockSearchService(searchFixtures());
    for (final expected in {
      '台積電': '2330.TW', '臺積電': '2330.TW', '2330': '2330.TW',
      '2330.TW': '2330.TW', ' tsmc ': '2330.TW', 'ＴＳＭＣ': '2330.TW',
      'TJD': '2330.TW', 'LFK': '2454.TW', 'MediaTek': '2454.TW',
      '长榮不存在': null,
      'NVDA': 'NVDA', 'nvidia': 'NVDA', '輝達': 'NVDA',
      '輝達半導體': 'NVDA', '特斯拉': 'TSLA', 'Tesla, Inc.': 'TSLA',
      '蘋果': 'AAPL', 'Apple Inc.': 'AAPL', 'BRK.B': 'BRK-B',
      'brk-b': 'BRK-B', 'Berkshire Hathaway': 'BRK-B',
      'Evergreen Marine': '2603.TW', '長榮海運': '2603.TW',
    }.entries) {
      final result = service.searchStock(expected.key);
      if (expected.value == null) {
        expect(result, isEmpty, reason: expected.key);
      } else {
        expect(result.first.symbol, expected.value, reason: expected.key);
      }
    }
  });

  test('normalization folds punctuation and full-width code consistently', () {
    expect(StockSearchService.normalize(' ２３３０．ＴＷ '), '2330tw');
    expect(StockSearchService.normalize('BRK.B / brk-b'), 'brkbbrkb');
    expect(StockSearchService.normalize('台 灣：積體-電路'), '台灣積體電路');
  });

  test('exact code beats an exact alias, prefixes beat substrings, ties are stable', () {
    final source = searchFixtures();
    final distracting = StockItem(market: StockMarket.us, symbol: 'MSFT', code: 'MSFT',
      nameZh: '微軟', nameFullZh: '微軟公司', nameEn: 'Microsoft Corporation',
      abbrEn: 'Microsoft', aliases: ['NVDA', 'Apple tools']);
    final service = StockSearchService([...source, distracting]);
    expect(service.searchStock('NVDA').map((row) => row.symbol).take(2), ['NVDA', 'MSFT']);
    expect(service.searchStock('Apple').first.symbol, 'AAPL');
    final reversed = StockSearchService([...source.reversed, distracting]);
    expect(reversed.searchStock('Corp').map((row) => row.symbol),
        service.searchStock('Corp').map((row) => row.symbol));
  });

  test('bounded typo matching and reverse substring do not match arbitrary text', () {
    final service = StockSearchService(searchFixtures());
    expect(service.searchStock('nvida').first.symbol, 'NVDA');
    expect(service.searchStock('mediatk').first.symbol, '2454.TW');
    expect(service.searchStock('分析台積電持股').first.symbol, '2330.TW');
    expect(service.searchStock('xxxxxxxxxxxxxx'), isEmpty);
    expect(service.searchStock('---  '), isEmpty);
    expect(service.searchStock(List.filled(129, 'x').join()), isEmpty);
  });

  test('market filtering, result limit and cached results retain their identities', () {
    final service = StockSearchService(searchFixtures());
    expect(service.searchStock('NVDA', market: StockMarket.tw), isEmpty);
    expect(service.searchStock('2330', market: StockMarket.us), isEmpty);
    final first = service.searchStock('a', limit: 2);
    expect(first.length, 2);
    expect(service.searchStock('a', limit: 2), same(first));
    expect(() => first.clear(), throwsUnsupportedError);
    expect(service.searchStock('a', limit: 0), isEmpty);
    expect(() => service.searchStock('a', limit: -1), throwsRangeError);
    expect(() => service.searchStock('a', limit: 51), throwsRangeError);
  });

  test('metadata validates canonical code, required types and duplicate records', () {
    final json = searchFixtures().first.toJson();
    expect(StockItem.fromJson(json).symbol, '2330.TW');
    expect(() => StockItem.fromJson({...json, 'code': '9999'}), throwsFormatException);
    expect(() => StockItem.fromJson({...json, 'aliases': null}), throwsFormatException);
    expect(() => StockItem.fromJson({...json, 'short_codes': [123]}), throwsFormatException);
    expect(() => StockItem.fromJson({...json, 'market': 'OTC'}), throwsFormatException);
    expect(() => StockSearchService([searchFixtures().first, searchFixtures().first]), throwsFormatException);
  });

  test('bundled master asset loads once and covers required demo identifiers', () async {
    final first = await StockSearchService.load();
    final second = await StockSearchService.load();
    expect(second, same(first));
    expect(first.length, greaterThanOrEqualTo(200));
    for (final symbol in ['AAPL', 'NVDA', 'TSLA', 'MSFT', '2330.TW', '2603.TW', '2454.TW']) {
      expect(first.searchStock(symbol).first.symbol, symbol);
    }
  });

  test('every bundled record resolves by canonical code and belongs to its declared market', () async {
    final service = await StockSearchService.load();
    final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json')) as List;
    final seen = <String>{};
    for (final row in decoded) {
      final stock = StockItem.fromJson(row as Map<String, dynamic>);
      expect(seen.add(stock.key), isTrue, reason: stock.key);
      final result = service.searchStock(stock.symbol);
      expect(result.first.symbol, stock.symbol, reason: stock.key);
      expect(result.first.market, stock.market, reason: stock.key);
      if (stock.market == StockMarket.tw) {
        expect(service.searchStock(stock.code, market: StockMarket.tw).first.symbol,
            stock.symbol, reason: stock.code);
      }
    }
    expect(seen.length, service.length);
  });
}
