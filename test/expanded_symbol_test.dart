import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

StockItem _item(String symbol) => StockItem(
  market: StockMarket.tw, symbol: symbol, code: symbol.split('.').first,
  nameZh: '測試公司', nameFullZh: '測試公司股份有限公司',
  nameEn: 'Test Company', abbrEn: 'Test',
);

PortfolioPosition _position(String symbol) => PortfolioPosition(
  id: symbol, symbol: symbol, market: StockMarket.tw,
  entryPrice: 100, initialStop: 98, shares: 10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TWSE and TPEx retain distinct canonical Yahoo suffixes', () {
    expect(canonicalSymbol(' 6488.two ', StockMarket.tw), '6488.TWO');
    expect(canonicalSymbol('2330.tw', StockMarket.tw), '2330.TW');
    // A raw code has no exchange information. Use the existing TWSE default;
    // autocomplete supplies the explicit .TWO code for known TPEx securities.
    expect(canonicalSymbol('6488', StockMarket.tw), '6488.TW');
    expect(canonicalSymbol('brk.b', StockMarket.us), 'BRK-B');
    expect(canonicalSymbol('BRK-B', StockMarket.us), 'BRK-B');
    expect(canonicalSymbol('^TWII', StockMarket.tw), '^TWII');
    expect(canonicalSymbol('^GSPC', StockMarket.us), '^GSPC');
  });

  test('suffix expansion does not permit paths, queries or market mixing', () {
    for (final value in [
      '6488.TWO.TW', '6488.TWO?x=1', '../6488.TWO', '6488.OTC',
      '6488.TW/secret', '12345.TWO', '6488TWO', '^GSPC',
    ]) {
      expect(() => canonicalSymbol(value, StockMarket.tw),
        throwsFormatException, reason: value);
    }
    for (final value in ['6488.TWO', 'NVDA.TWO', 'NVDA.TW', '^TWII']) {
      expect(() => canonicalSymbol(value, StockMarket.us),
        throwsFormatException, reason: value);
    }
  });

  test('TPEx metadata, holding and quote JSON round-trip without suffix loss', () {
    for (final symbol in ['2330.TW', '6488.TWO']) {
      final item = _item(symbol);
      expect(StockItem.fromJson(item.toJson()).symbol, symbol);
      expect(item.code, symbol.split('.').first);
      final holding = _position(symbol);
      expect(PortfolioPosition.fromJson(holding.toJson()).symbol, symbol);
      final quote = PortfolioQuote(
        symbol: symbol, name: '測試行情', market: StockMarket.tw,
        currentPrice: 106, ema9: 103, ema21: 101, ema50: 99,
        lastClose: 105, closeConfirmed: true,
        quoteTimestamp: DateTime.utc(2026, 10, 15, 5, 31),
        closeTimestamp: DateTime.utc(2026, 10, 15, 5, 30),
        source: 'injected unit test quote', isLargeLiquid: false,
      );
      expect(PortfolioQuote.fromJson(quote.toJson()).symbol, symbol);
    }
    for (final symbol in ['6488.TWO.TW', '6488.OTC', 'NVDA']) {
      expect(() => _item(symbol), throwsFormatException);
      expect(() => _position(symbol), throwsFormatException);
    }
  });

  test('Python snapshot parser accepts a TPEx row and isolates a bad suffix', () async {
    Map<String, dynamic> row(String symbol) => {
      'market': 'tw', 'symbol': symbol, 'name': '測試普通股', 'sector': '半導體',
      'adr_percent': 4.2, 'rs_score': 90, 'rs_rank': 1,
      'patterns': ['均線收斂'], 'entry_price': 100, 'stop_price': null,
      'is_large_liquid': false, 'status': 'watchlist',
      'data_timestamp': '2026-10-15T05:30:00Z', 'notes': <String>[],
    };
    final client = MockClient((_) async => http.Response(jsonEncode({
      'market': 'tw', 'generated_at': '2026-10-15T05:31:00Z',
      'source': 'Yahoo Finance HTTPS chart via Python API',
      'universe_count': 2, 'evaluated_count': 2, 'stale': false,
      'warnings': <String>[],
      'candidates': [row('6488.TWO'), row('6488.INVALID')],
    }), 200, headers: {'content-type': 'application/json; charset=utf-8'}));
    addTearDown(client.close);
    final snapshot = await RealCandidateRepository(
      baseUrl: 'https://example.test', client: client,
    ).fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(snapshot.candidates.single.symbol, '6488.TWO');
    expect(snapshot.missingSymbols, contains('6488.INVALID'));
  });
}
