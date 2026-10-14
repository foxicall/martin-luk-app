import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';

void main() {
  test('51 requested holdings use batches of 50 and 1 with full quote coverage', () async {
    final sizes = <int>[];
    final client = MockClient((request) async {
      final symbols = request.url.queryParameters['symbols']!.split(',');
      sizes.add(symbols.length);
      expect(request.url.queryParameters['demo'], 'false');
      return http.Response(jsonEncode({
        'market': 'us', 'source': 'test API', 'generated_at': '2026-10-13T15:00:00Z',
        'errors': <String, String>{},
        'quotes': symbols.map((symbol) => {
          'symbol': symbol, 'name': symbol, 'market': 'us', 'current_price': 104,
          'ema9': 100, 'ema21': 98, 'ema50': 95, 'last_close': 100,
          'close_confirmed': true, 'quote_timestamp': '2026-10-13T15:00:00Z',
          'close_timestamp': '2026-10-12T20:00:00Z',
          'source': 'test API', 'is_large_liquid': false,
        }).toList(),
      }), 200);
    });
    addTearDown(client.close);
    final repository = RealPortfolioRepository(baseUrl: 'https://example.test', client: client);
    addTearDown(repository.close);
    final snapshot = await repository.fetch(StockMarket.us,
      List.generate(51, (index) => 'TEST$index'));
    expect(sizes, [50, 1]);
    expect(snapshot.quotes.length, 51);
    expect(snapshot.errors, isEmpty);
  });

  test('a failing batch retains other batches and returns per-symbol errors', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('unavailable', 503);
      return http.Response(jsonEncode({
        'market': 'us', 'source': 'test API', 'generated_at': '2026-10-13T15:00:00Z',
        'errors': {'TEST50': '查無有效行情'}, 'quotes': <Object>[],
      }), 200);
    });
    addTearDown(client.close);
    final repository = RealPortfolioRepository(baseUrl: 'https://example.test', client: client);
    addTearDown(repository.close);
    final snapshot = await repository.fetch(StockMarket.us,
      List.generate(51, (index) => 'TEST$index'));
    expect(calls, 2);
    expect(snapshot.quotes, isEmpty);
    expect(snapshot.errors.length, 51);
    expect(snapshot.errors['TEST0'], contains('HTTP 503'));
    expect(snapshot.errors['TEST50'], '查無有效行情');
  });

  test('live loader rejects a disguised demo response or contradictory quote errors', () async {
    final row = {
      'symbol': 'NVDA', 'name': 'NVIDIA', 'market': 'us', 'current_price': 104,
      'ema9': 100, 'ema21': 98, 'ema50': 95, 'last_close': 100,
      'close_confirmed': true, 'quote_timestamp': '2026-10-13T15:00:00Z',
      'close_timestamp': '2026-10-12T20:00:00Z', 'source': 'Yahoo Finance',
      'is_large_liquid': true,
    };
    final payloads = [
      {'source': 'offline mock', 'quotes': [row], 'errors': <String, String>{}},
      {'source': 'Yahoo Finance', 'quotes': [row], 'errors': {'NVDA': '查無行情'}},
      {'source': 'Yahoo Finance', 'quotes': [row], 'errors': {'TSLA': '未要求的股票'}},
      {'source': 'Yahoo Finance', 'quotes': <Object>[], 'errors': {'NVDA': ''}},
      {'source': 'Yahoo Finance', 'quotes': [{...row, 'source': 'fictitious demo'}], 'errors': <String, String>{}},
    ];
    for (final payload in payloads) {
      final client = MockClient((request) async => http.Response(jsonEncode({
        'market': 'us', 'generated_at': '2026-10-13T15:00:00Z', ...payload,
      }), 200));
      final repository = RealPortfolioRepository(baseUrl: 'https://example.test', client: client);
      try {
        final snapshot = await repository.fetch(StockMarket.us, ['NVDA']);
        expect(snapshot.quotes, isEmpty);
        expect(snapshot.errors.keys, ['NVDA']);
        expect(snapshot.errors['NVDA'], contains('批次取得失敗'));
      } finally { repository.close(); client.close(); }
    }
  });
}
