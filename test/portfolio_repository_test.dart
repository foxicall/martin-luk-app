import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';

// Explicit production-parser HTTP fixtures, not real latest quotes.
Map<String, dynamic> _quote(String symbol) => {
  'symbol': symbol, 'name': symbol, 'market': 'us', 'current_price': 104,
  'ema9': 100, 'ema21': 98, 'ema50': 95, 'last_close': 100,
  'close_confirmed': true, 'quote_timestamp': '2026-10-13T15:00:00Z',
  'close_timestamp': '2026-10-12T20:00:00Z',
  'source': 'Yahoo Finance HTTP fixture', 'is_large_liquid': true,
};

Map<String, dynamic> _response(List<Object?> rows,
    {Map<String, Object?> errors = const {}}) => {
  'market': 'us', 'source': 'Yahoo Finance HTTP fixture',
  'generated_at': '2026-10-13T15:00:00Z', 'quotes': rows, 'errors': errors,
};

Future<PortfolioQuoteSnapshot> _fetch(Map<String, dynamic> payload,
    List<String> symbols) async {
  final client = MockClient((_) async => http.Response(jsonEncode(payload), 200,
      headers: {'content-type': 'application/json; charset=utf-8'}));
  final repository = RealPortfolioRepository(baseUrl: 'https://example.test', client: client);
  try {
    return await repository.fetch(StockMarket.us, symbols);
  } finally {
    repository.close();
    client.close();
  }
}

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

  test('live loader rejects a disguised demo response or all-invalid contradictory quotes', () async {
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

  test('one malformed quote retains good quotes in the same HTTP batch', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA'), _quote('TSLA')..['ema9'] = 'not a number', null,
    ]), ['NVDA', 'TSLA', 'AAPL']);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.quotes['NVDA']!.isCached, isFalse);
    expect(snapshot.quotes['NVDA']!.isStale, isFalse);
    expect(snapshot.errors['TSLA'], contains('ema9'));
    expect(snapshot.errors['AAPL'], contains('未提供'));
    expect(snapshot.warnings.join(), contains('第 3 筆行情'));
    expect(snapshot.errors.containsKey('NVDA'), isFalse);
    expect(() => snapshot.quotes.clear(), throwsUnsupportedError);
    expect(() => snapshot.warnings.clear(), throwsUnsupportedError);
  });

  test('duplicate or mixed-market rows affect only the implicated stock', () async {
    final duplicates = await _fetch(_response([
      _quote('NVDA'), _quote('TSLA'), _quote('TSLA'),
    ]), ['NVDA', 'TSLA']);
    expect(duplicates.quotes.keys, ['NVDA']);
    expect(duplicates.errors['TSLA'], contains('重複'));
    final mixed = await _fetch(_response([
      _quote('NVDA'), _quote('TSLA')..['market'] = 'tw', _quote('MSFT'),
    ]), ['NVDA', 'TSLA']);
    expect(mixed.quotes.keys, ['NVDA']);
    expect(mixed.errors.keys, ['TSLA']);
    expect(mixed.warnings, isNotEmpty);
    expect(mixed.quotes.containsKey('MSFT'), isFalse);
  });

  test('contradictory and malformed errors affect their symbol, unknown errors become warnings', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA'), _quote('TSLA'), _quote('AAPL'),
    ], errors: {
      'TSLA': 'quote unavailable', 'AAPL': '', 'UNREQUESTED': 'unknown stock',
    }), ['NVDA', 'TSLA', 'AAPL']);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors['TSLA'], contains('同一股票'));
    expect(snapshot.errors['AAPL'], contains('錯誤訊息格式無效'));
    expect(snapshot.errors.containsKey('UNREQUESTED'), isFalse);
    expect(snapshot.warnings.join(), contains('未要求股票'));
    final unknownOnly = await _fetch(_response([_quote('NVDA')],
        errors: {'TSLA': 'unrequested'}), ['NVDA']);
    expect(unknownOnly.quotes.keys, ['NVDA']);
    expect(unknownOnly.errors, isEmpty);
    expect(unknownOnly.warnings, isNotEmpty);
  });

  test('nonempty all-invalid quote responses give explicit failures for the requested holdings', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA')..['current_price'] = 0,
      _quote('TSLA')..['source'] = 'demo quotes',
    ]), ['NVDA', 'TSLA']);
    expect(snapshot.quotes, isEmpty);
    expect(snapshot.errors.keys, ['NVDA', 'TSLA']);
    expect(snapshot.errors.values, everyElement(contains('全部無法驗證')));
    expect(snapshot.source, 'API 行情尚不可用');
  });

  test('successful empty quotes produce per-symbol absence instead of fabricated quotes', () async {
    final snapshot = await _fetch(_response([]), ['NVDA']);
    expect(snapshot.quotes, isEmpty);
    expect(snapshot.errors['NVDA'], 'API 未提供可驗證行情');
    expect(snapshot.source, 'Yahoo Finance HTTP fixture');
    final malformedError = await _fetch(_response([], errors: {'NVDA': ''}), ['NVDA']);
    expect(malformedError.errors['NVDA'], contains('錯誤訊息格式無效'));
  });

  test('invalid envelope metadata remains an explicit whole-batch failure', () async {
    final payloads = [
      _response([_quote('NVDA')])..['generated_at'] = '2026-10-13T15:00:00',
      _response([_quote('NVDA')])..['market'] = 'tw',
      _response([_quote('NVDA')])..['source'] = '',
      _response([_quote('NVDA')])..['errors'] = <Object>[],
      _response([_quote('NVDA')])..['quotes'] = 'invalid container',
      _response([_quote('NVDA')])..['stale'] = 'false',
    ];
    for (final payload in payloads) {
      final snapshot = await _fetch(payload, ['NVDA']);
      expect(snapshot.quotes, isEmpty);
      expect(snapshot.errors['NVDA'], contains('批次取得失敗'));
    }
  });

  test('a future quote is excluded while another valid holding is available', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA'),
      _quote('TSLA')..['quote_timestamp'] = '2030-10-13T15:00:00Z',
    ]), ['NVDA', 'TSLA']);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors['TSLA'], contains('時間'));
  });

  test('cache warnings and envelope stale flags freeze observations without altering source timestamps', () async {
    final warned = await _fetch(_response([
      _quote('NVDA')..['cache_warning'] = 'Provider returned cached data',
    ]), ['NVDA']);
    expect(warned.quotes['NVDA']!.isCached, isTrue);
    expect(warned.quotes['NVDA']!.quoteTimestamp, DateTime.utc(2026, 10, 13, 15));
    final stale = await _fetch(_response([_quote('NVDA')])..['stale'] = true, ['NVDA']);
    final quote = stale.quotes['NVDA']!;
    expect(quote.isCached, isTrue);
    expect(quote.isStale, isTrue);
    expect(quote.closeTimestamp, DateTime.utc(2026, 10, 12, 20));
    expect(quote.cacheWarning, contains('最高 R'));
  });

  test('invalid row cache flags cannot be silently converted into fresh quotes', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA'), _quote('TSLA')..['is_cached'] = 'true',
    ]), ['NVDA', 'TSLA']);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors['TSLA'], contains('is_cached'));
  });

  test('unrequested malformed data has bounded warnings and cannot poison a valid requested quote', () async {
    final snapshot = await _fetch(_response([
      _quote('NVDA'), ...List.filled(100, null),
    ]), ['NVDA']);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors, isEmpty);
    expect(snapshot.warnings.length, 20);
    expect(snapshot.warnings.every((message) => message.length <= 241), isTrue);
  });

  test('a stalled batch becomes per-symbol errors and another refresh can complete', () async {
    var calls = 0;
    final never = Completer<http.Response>();
    final client = MockClient((_) => ++calls == 1 ? never.future
        : Future.value(http.Response(jsonEncode({
          'market': 'us', 'source': 'Yahoo Finance',
          'generated_at': '2026-10-13T15:00:00Z',
          'errors': {'NVDA': 'No fresh quote'}, 'quotes': <Object>[],
        }), 200)));
    final repository = RealPortfolioRepository(baseUrl: 'https://example.test',
        client: client, requestTimeout: const Duration(milliseconds: 10));
    final failed = await repository.fetch(StockMarket.us, ['NVDA']);
    expect(failed.quotes, isEmpty);
    expect(failed.errors['NVDA'], contains('逾時'));
    final retry = await repository.fetch(StockMarket.us, ['NVDA']);
    expect(retry.errors['NVDA'], 'No fresh quote');
    expect(calls, 2);
    repository.close();
    client.close();
  });
}
