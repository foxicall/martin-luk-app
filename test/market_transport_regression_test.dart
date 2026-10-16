import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 14, 16);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every TW/US chart request carries the required browser headers', () async {
    final seen = <http.Request>[];
    final api = MarketDataApi(now: () => now, client: MockClient((request) async {
      seen.add(request);
      final tw = request.url.path.endsWith('2330.TW');
      return http.Response(jsonEncode(_chart(tw ? '2330.TW' : 'NVDA', tw)), 200);
    }));
    addTearDown(api.close);
    await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    await api.fetchDaily('2330.TW', StockMarket.tw, forceRefresh: true);
    expect(seen.length, 2);
    for (final request in seen) {
      expect(request.headers['user-agent'], MarketDataApi.requestHeaders['User-Agent']);
      expect(request.headers['accept'], 'application/json');
      expect(request.headers['accept-language'], 'en-US,en;q=0.9');
    }
  });

  test('403 uses one official alternate endpoint and preserves its provenance', () async {
    final hosts = <String>[];
    final api = MarketDataApi(now: () => now, client: MockClient((request) async {
      hosts.add(request.url.host);
      expect(request.headers['user-agent'], MarketDataApi.requestHeaders['User-Agent']);
      return hosts.length == 1 ? http.Response('<html>denied</html>', 403) :
          http.Response(jsonEncode(_chart('NVDA', false)), 200);
    }));
    addTearDown(api.close);
    final chart = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(hosts, ['query1.finance.yahoo.com', 'query2.finance.yahoo.com']);
    expect(chart.source, contains('query2.finance.yahoo.com'));
    expect(chart.latestPrice, 102);
    expect(chart.isCached, isFalse);
    expect(chart.isStale, isFalse);
  });

  test('HTTP 200 HTML cannot become a price or a successful JSON snapshot', () async {
    var calls = 0;
    final api = MarketDataApi(now: () => now, client: MockClient((_) async {
      calls++;
      return http.Response('<!doctype html><html>verification</html>', 200,
          headers: {'content-type': 'text/html'});
    }));
    addTearDown(api.close);
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>().having((e) => e.stage, 'stage', 'json')
          .having((e) => e.symbol, 'symbol', 'NVDA')
          .having((e) => e.endpointHost, 'endpoint', 'query2.finance.yahoo.com')
          .having((e) => e.message, 'message', contains('HTML'))));
    expect(calls, 2);
  });

  test('429 backoff retries the same host instead of evading the rate limit', () async {
    final hosts = <String>[];
    final delays = <Duration>[];
    final api = MarketDataApi(now: () => now,
      delay: (duration) async { delays.add(duration); },
      client: MockClient((request) async {
        hosts.add(request.url.host);
        return hosts.length == 1 ? http.Response('limited', 429,
            headers: {'retry-after': '1'}) :
            http.Response(jsonEncode(_chart('NVDA', false)), 200);
      }));
    addTearDown(api.close);
    await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(hosts, ['query1.finance.yahoo.com', 'query1.finance.yahoo.com']);
    expect(delays, [const Duration(seconds: 1)]);
  });

  test('JSON syntax failure clears the request slot and a later retry succeeds', () async {
    var calls = 0;
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        ++calls == 1 ? http.Response('{broken', 200) :
        http.Response(jsonEncode(_chart('NVDA', false)), 200)));
    addTearDown(api.close);
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>().having((e) => e.stage, 'stage', 'json')));
    final chart = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(calls, 2);
    expect(chart.latestPrice, 102);
    expect(chart.isStale, isFalse);
  });

  test('persistent 403 remains a scoped actionable error with no mock fallback', () async {
    var calls = 0;
    final api = MarketDataApi(now: () => now, client: MockClient((_) async {
      calls++;
      return http.Response('denied', 403);
    }));
    addTearDown(api.close);
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>().having((e) => e.statusCode, 'status', 403)
          .having((e) => e.symbol, 'symbol', 'NVDA')
          .having((e) => e.stage, 'stage', 'http')
          .having((e) => e.endpointHost, 'endpoint', 'query2.finance.yahoo.com')));
    expect(calls, 2);
  });


}

/// Explicit HTTP fixture for regression tests, never used by the live gate.
Map<String, dynamic> _chart(String symbol, bool tw) {
  int unix(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
  final start = DateTime.utc(2026, 10, 14, tw ? 1 : 13, tw ? 0 : 30);
  final end = DateTime.utc(2026, 10, 14, tw ? 5 : 20, tw ? 30 : 0);
  return {'chart': {'error': null, 'result': [{
    'meta': {'symbol': symbol, 'currency': tw ? 'TWD' : 'USD',
      'exchangeTimezoneName': tw ? 'Asia/Taipei' : 'America/New_York',
      'gmtoffset': tw ? 28800 : -14400, 'regularMarketPrice': 102,
      'regularMarketTime': unix(tw ? end : DateTime.utc(2026, 10, 14, 15)),
      'currentTradingPeriod': {'regular': {'start': unix(start), 'end': unix(end)}}},
    'timestamp': [unix(start.subtract(const Duration(days: 1))), unix(start)],
    'indicators': {'quote': [{
      'open': [100, 101], 'high': [103, 104], 'low': [98, 99],
      'close': [101, 102], 'volume': [1000000, 1200000],
    }]},
  }]}};
}
