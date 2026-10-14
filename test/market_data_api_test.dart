import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 14, 16);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Direct HTTPS requests parse USD and TWD prices without a backend', () async {
    final requests = <Uri>[];
    final api = MarketDataApi(now: () => now, client: MockClient((request) async {
      requests.add(request.url);
      final tw = request.url.path.endsWith('/2330.TW');
      return http.Response(jsonEncode(_document(tw ? StockMarket.tw : StockMarket.us)), 200);
    }));
    final taiwan = await api.fetchDaily('2330', StockMarket.tw);
    final usa = await api.fetchDaily('NVDA', StockMarket.us);
    expect(taiwan.symbol, '2330.TW');
    expect(taiwan.currency, 'TWD');
    expect(usa.currency, 'USD');
    expect(usa.latestPrice, 102);
    expect(usa.bars.length, 2);
    expect(taiwan.completedDailyBars.length, 2);
    expect(usa.completedDailyBars.length, 1); // today's US candle is partial
    expect(requests.every((uri) => uri.scheme == 'https'), isTrue);
    expect(requests.every((uri) => uri.host == 'query1.finance.yahoo.com'), isTrue);
    expect(requests.first.queryParameters['range'], '6mo');
    expect(requests.first.queryParameters['includePrePost'], 'true');
    expect(usa.isCached, isFalse);
    expect(usa.isStale, isFalse);
    api.close();
  });

  test('Daily bars do not become confirmed solely because HTTP finishes after close', () async {
    final data = _document(StockMarket.tw);
    _meta(data)['regularMarketTime'] = _unix(DateTime.utc(2026, 10, 14, 4));
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('2330.TW', StockMarket.tw);
    expect(chart.completedDailyBars.length, 1);
    api.close();
  });

  test('Null OHLCV rows are omitted, never filled with fictitious prices', () async {
    final data = _document(StockMarket.us);
    final row = _result(data);
    (row['timestamp'] as List).insert(1, _unix(DateTime.utc(2026, 10, 13, 14)));
    final values = _values(data);
    for (final key in ['open', 'high', 'low', 'close', 'volume']) {
      (values[key] as List).insert(1, null);
    }
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.bars.length, 2);
    expect(chart.bars.every((bar) => bar.close > 0), isTrue);
    api.close();
  });

  test('Wrong symbol or USD/TWD currency is rejected', () async {
    final data = _document(StockMarket.us);
    _meta(data)['currency'] = 'TWD';
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>()));
    api.close();
  });

  test('Daily memory cache prevents repeated HTTP; forced pull refresh bypasses it', () async {
    var requests = 0;
    final api = MarketDataApi(now: () => now, client: MockClient((_) async {
      requests++;
      return http.Response(jsonEncode(_document(StockMarket.us)), 200);
    }));
    await api.fetchDaily('NVDA', StockMarket.us);
    final cached = await api.fetchDaily('NVDA', StockMarket.us);
    expect(requests, 1);
    expect(cached.isCached, isTrue);
    expect(cached.isStale, isFalse);
    expect(cached.cacheWarning, isNull);
    await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(requests, 2);
    api.close();
  });

  test('Failed forced update preserves provider timestamp and marks real cache stale', () async {
    var requests = 0;
    final api = MarketDataApi(now: () => now, client: MockClient((_) async {
      requests++;
      return requests == 1
          ? http.Response(jsonEncode(_document(StockMarket.us)), 200)
          : http.Response('unavailable', 503);
    }));
    final first = await api.fetchDaily('NVDA', StockMarket.us);
    final fallback = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(fallback.isCached, isTrue);
    expect(fallback.isStale, isTrue);
    expect(fallback.cacheWarning, contains('更新失敗'));
    expect(fallback.quoteTimestamp, first.quoteTimestamp);
    expect(fallback.fetchedAt, first.fetchedAt);
    expect(fallback.latestPrice, first.latestPrice);
    expect(fallback.isQuoteFresh(now), isFalse);
    api.close();
  });

  test('Persistent real cache survives a new service instance', () async {
    final preferences = await SharedPreferences.getInstance();
    final first = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response(
            jsonEncode(_document(StockMarket.tw)), 200)));
    await first.fetchDaily('2330.TW', StockMarket.tw);
    first.close();
    final second = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response('offline', 500)));
    final cached = await second.fetchDaily('2330.TW', StockMarket.tw, forceRefresh: true);
    expect(cached.symbol, '2330.TW');
    expect(cached.isStale, isTrue);
    expect(cached.currency, 'TWD');
    second.close();
  });

  test('Concurrent same-symbol requests share one transport future', () async {
    var requests = 0;
    final response = Completer<http.Response>();
    final api = MarketDataApi(now: () => now, client: MockClient((_) {
      requests++;
      return response.future;
    }));
    final first = api.fetchDaily('NVDA', StockMarket.us);
    final second = api.fetchDaily('NVDA', StockMarket.us);
    // Yield until both preferences reads reach the shared pending request.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    response.complete(http.Response(jsonEncode(_document(StockMarket.us)), 200));
    final results = await Future.wait([first, second]);
    expect(requests, 1);
    expect(results.map((chart) => chart.symbol), ['NVDA', 'NVDA']);
    api.close();
  });

  test('HTTP failures without a real cache propagate, never select mock rows', () async {
    final api = MarketDataApi(client: MockClient((_) async => http.Response('denied', 403)));
    await expectLater(api.fetchDaily('2330.TW', StockMarket.tw),
        throwsA(isA<MarketDataException>().having((error) => error.statusCode, 'status', 403)));
    api.close();
  });

  test('429 uses bounded Retry-After then retries once', () async {
    var requests = 0;
    final delays = <Duration>[];
    final api = MarketDataApi(now: () => now, delay: (duration) async => delays.add(duration),
        client: MockClient((_) async {
      requests++;
      return requests == 1 ? http.Response('', 429, headers: {'retry-after': '2'})
          : http.Response(jsonEncode(_document(StockMarket.us)), 200);
    }));
    await api.fetchDaily('NVDA', StockMarket.us);
    expect(requests, 2);
    expect(delays, [const Duration(seconds: 2)]);
    api.close();
  });

  test('Long Retry-After does not block a foreground refresh', () async {
    var requests = 0;
    final api = MarketDataApi(delay: (_) async => fail('must not delay'),
        client: MockClient((_) async {
      requests++;
      return http.Response('', 429, headers: {'retry-after': '120'});
    }));
    await expectLater(api.fetchDaily('NVDA', StockMarket.us), throwsA(isA<MarketDataException>()));
    expect(requests, 1);
    api.close();
  });

  test('Timeout has a retry message and no fabricated fallback', () async {
    final never = Completer<http.Response>();
    final api = MarketDataApi(requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((_) => never.future));
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>().having((error) => error.message, 'message', contains('逾時'))));
    api.close();
  });

  test('Benchmarks and class-share IDs are normalized for Yahoo', () async {
    final paths = <String>[];
    final api = MarketDataApi(now: () => now, client: MockClient((request) async {
      paths.add(request.url.path);
      final tw = request.url.path.endsWith('^TWII');
      final data = _document(tw ? StockMarket.tw : StockMarket.us);
      _meta(data)['symbol'] = tw ? '^TWII' : '^GSPC';
      return http.Response(jsonEncode(data), 200);
    }));
    await api.fetchBenchmark(StockMarket.tw);
    await api.fetchBenchmark(StockMarket.us);
    expect(paths, contains('/v8/finance/chart/^TWII'));
    expect(paths, contains('/v8/finance/chart/^GSPC'));
    expect(canonicalSymbol('brk.b', StockMarket.us), 'BRK-B');
    expect(() => canonicalSymbol('2330.TW', StockMarket.us), throwsFormatException);
    api.close();
  });

  test('Regular-session filter excludes premarket from opening-range candles', () async {
    final data = _document(StockMarket.us);
    _result(data)['timestamp'] = [
      _unix(DateTime.utc(2026, 10, 14, 13, 25)),
      _unix(DateTime.utc(2026, 10, 14, 13, 30)),
    ];
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchIntraday('NVDA', StockMarket.us);
    expect(chart.regularSessionBars.length, 1);
    expect(chart.regularSessionBars.single.timestamp, DateTime.utc(2026, 10, 14, 13, 30));
    expect(chart.completedDailyBars, isEmpty);
    api.close();
  });

  test('Historical daily close uses correct New York DST offset', () {
    final winter = PriceBar(timestamp: DateTime.utc(2026, 1, 5, 14, 30),
        open: 100, high: 104, low: 97, close: 102, volume: 1000);
    final summer = PriceBar(timestamp: DateTime.utc(2026, 7, 6, 13, 30),
        open: 100, high: 104, low: 97, close: 102, volume: 1000);
    final chart = MarketChart(symbol: 'NVDA', market: StockMarket.us,
        currency: 'USD', exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
        bars: [winter, summer], latestPrice: 102, quoteTimestamp: now,
        fetchedAt: now, interval: '1d');
    expect(chart.dailyCloseTimestamp(winter), DateTime.utc(2026, 1, 5, 21));
    expect(chart.dailyCloseTimestamp(summer), DateTime.utc(2026, 7, 6, 20));
  });

  test('Intraday failure remains visible and cannot supply an invented opening range', () async {
    final api = MarketDataApi(now: () => now, client: MockClient((request) async =>
        request.url.queryParameters['interval'] == '1d'
          ? http.Response(jsonEncode(_document(StockMarket.us)), 200)
          : http.Response('throttled', 429, headers: {'retry-after': '120'})));
    final bundle = await api.fetchBundle('NVDA', StockMarket.us);
    expect(bundle.daily.latestPrice, 102);
    expect(bundle.intraday, isNull);
    expect(bundle.intradayError, contains('429'));
    api.close();
  });
}

Map<String, dynamic> _document(StockMarket market) {
  final tw = market == StockMarket.tw;
  final start = tw ? DateTime.utc(2026, 10, 14, 1)
      : DateTime.utc(2026, 10, 14, 13, 30);
  final end = tw ? DateTime.utc(2026, 10, 14, 5, 30)
      : DateTime.utc(2026, 10, 14, 20);
  return {'chart': {'error': null, 'result': [{
    'meta': {
      'symbol': tw ? '2330.TW' : 'NVDA', 'currency': tw ? 'TWD' : 'USD',
      'exchangeTimezoneName': tw ? 'Asia/Taipei' : 'America/New_York',
      'gmtoffset': tw ? 28800 : -14400,
      'regularMarketPrice': 102,
      'regularMarketTime': _unix(tw ? end : DateTime.utc(2026, 10, 14, 16)),
      'currentTradingPeriod': {'regular': {'start': _unix(start), 'end': _unix(end)}},
    },
    'timestamp': [_unix(start.subtract(const Duration(days: 1))), _unix(start)],
    'indicators': {'quote': [{
      'open': <Object?>[98, 100], 'high': <Object?>[103, 104],
      'low': <Object?>[97, 99], 'close': <Object?>[100, 102],
      'volume': <Object?>[1600, 1200],
    }]},
  }]}};
}

int _unix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
Map<String, dynamic> _result(Map<String, dynamic> data) =>
    ((data['chart'] as Map<String, dynamic>)['result'] as List).first as Map<String, dynamic>;
Map<String, dynamic> _meta(Map<String, dynamic> data) => _result(data)['meta'] as Map<String, dynamic>;
Map<String, dynamic> _values(Map<String, dynamic> data) =>
    (((_result(data)['indicators'] as Map<String, dynamic>)['quote'] as List).first as Map<String, dynamic>);
