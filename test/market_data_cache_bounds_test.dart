import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

/// Explicit transport fixtures test resource bounds. They never replace the
/// independent real-network verification gate or create a live recommendation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 16, 16);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a complete rotating universe keeps memory and disk at 96 entries', () async {
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((request) async => http.Response(
            jsonEncode(_chart(request.url.pathSegments.last)), 200)));
    addTearDown(api.close);
    for (var index = 0; index < 150; index++) {
      final result = await api.fetchDaily(_symbol(index), StockMarket.us);
      expect(result.symbol, _symbol(index));
      expect(result.isCached, isFalse);
      _expectBounds(api, preferences);
    }
    expect(_keys(preferences), hasLength(MarketDataApi.maximumCacheEntries));
    expect(preferences.containsKey(_key(_symbol(0))), isFalse);
    expect(preferences.containsKey(_key(_symbol(149))), isTrue);
  });

  test('disk reads and offline fallback obey the same memory eviction budget', () async {
    SharedPreferences.setMockInitialValues({
      for (var index = 0; index < 120; index++)
        _key(_symbol(index)): _envelope(_symbol(index),
            now.subtract(Duration(seconds: 120 - index))),
    });
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response('offline', 503)));
    addTearDown(api.close);
    var cachedCount = 0;
    for (var index = 0; index < 120; index++) {
      try {
        final chart = await api.fetchDaily(_symbol(index), StockMarket.us,
            forceRefresh: true);
        cachedCount++;
        expect(chart.isCached, isTrue);
        expect(chart.isStale, isTrue);
        expect(chart.fetchedAt, now.subtract(Duration(seconds: 120 - index)));
        // A cached provider quote cannot come from after its original fetch.
        expect(chart.quoteTimestamp, now.subtract(Duration(seconds: 120 - index)));
        expect(chart.quoteTimestamp.isAfter(chart.fetchedAt), isFalse);
      } on MarketDataException {
        // Entries evicted from the old unbounded cache are an honest error,
        // never a fabricated quote or a reason to abort a rolling market scan.
      }
      _expectBounds(api, preferences);
    }
    expect(cachedCount, MarketDataApi.maximumCacheEntries);
    expect(api.debugMemoryCacheEntries, MarketDataApi.maximumCacheEntries);
  });

  test('offline fallback still rejects an impossible future quote timestamp', () async {
    final fetchedAt = now.subtract(const Duration(minutes: 2));
    SharedPreferences.setMockInitialValues({
      _key('NVDA'): jsonEncode({
        'fetched_at': fetchedAt.toIso8601String(),
        // Deliberately invalid: the provider quote is later than the fetch.
        'document': _chart('NVDA', quoteAt: now),
      }),
    });
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response('offline', 503)));
    addTearDown(api.close);
    await expectLater(api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true),
        throwsA(isA<MarketDataException>()));
    expect(preferences.containsKey(_key('NVDA')), isFalse);
    expect(api.debugMemoryCacheEntries, 0);
    _expectBounds(api, preferences);
  });

  test('the byte budget evicts payloads even before the entry limit', () async {
    final preferences = await SharedPreferences.getInstance();
    final padding = String.fromCharCodes(List<int>.filled(400 * 1024, 120));
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((request) async => http.Response(jsonEncode({
          ..._chart(request.url.pathSegments.last), 'fixture_padding': padding,
        }), 200)));
    addTearDown(api.close);
    for (var index = 0; index < 30; index++) {
      await api.fetchDaily(_symbol(index), StockMarket.us);
      _expectBounds(api, preferences);
    }
    expect(api.debugMemoryCacheEntries, lessThan(30));
    expect(_keys(preferences).length, lessThan(30));
    expect(api.debugMemoryCacheEntries, greaterThan(0));
  });

  test('a cache hit protects the recently used entry from the next eviction', () async {
    final preferences = await SharedPreferences.getInstance();
    var requests = 0;
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((request) async {
          requests++;
          return http.Response(jsonEncode(_chart(request.url.pathSegments.last)), 200);
        }));
    addTearDown(api.close);
    for (var index = 0; index < MarketDataApi.maximumCacheEntries; index++) {
      await api.fetchDaily(_symbol(index), StockMarket.us);
    }
    final touched = await api.fetchDaily(_symbol(0), StockMarket.us);
    expect(touched.isCached, isTrue);
    expect(requests, MarketDataApi.maximumCacheEntries);
    await api.fetchDaily('EXTRA', StockMarket.us);
    expect(preferences.containsKey(_key(_symbol(0))), isTrue);
    expect(preferences.containsKey(_key('EXTRA')), isTrue);
    _expectBounds(api, preferences);
  });

  test('two API instances share one bounded disk writer and metadata index', () async {
    final preferences = await SharedPreferences.getInstance();
    final client = MockClient((request) async => http.Response(
        jsonEncode(_chart(request.url.pathSegments.last)), 200));
    final first = MarketDataApi(preferences: preferences, now: () => now, client: client);
    final second = MarketDataApi(preferences: preferences, now: () => now, client: client);
    addTearDown(first.close);
    addTearDown(second.close);
    for (var offset = 0; offset < 110; offset += 5) {
      await Future.wait([
        for (var index = offset; index < offset + 5; index++)
          (index.isEven ? first : second).fetchDaily(_symbol(index), StockMarket.us),
      ]);
      _expectBounds(first, preferences);
      _expectBounds(second, preferences);
    }
    expect(_keys(preferences), hasLength(MarketDataApi.maximumCacheEntries));
  });

  test('cleanup removes only expired oversized and excess Yahoo cache keys', () async {
    final protected = <String, Object>{
      'martin_luk_app.settings': '{"usCapital":50000,"twCapital":1000000}',
      'martin_luk_app.portfolio': '[{"symbol":"NVDA","shares":20}]',
      'martin-mobile-us-rolling-v1-5.0': '{"attempted":["A","AA"]}',
      'martin-mobile-tw-rolling-v1-3.5': '{"attempted":["1101.TW"]}',
      'martin-stock-universe-v3-us': '{"stocks":["NVDA"]}',
    };
    SharedPreferences.setMockInitialValues({
      ...protected,
      _key('OLD'): _envelope('OLD', now.subtract(const Duration(days: 8))),
      _key('FUTURE'): _envelope('FUTURE', now.add(const Duration(days: 1))),
      _key('LARGE'): String.fromCharCodes(
          List<int>.filled(MarketDataApi.maximumCacheEntryBytes + 1, 120)),
      _key('NVDA'): _envelope('NVDA', now),
    });
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response('offline', 503)));
    addTearDown(api.close);
    final cached = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(cached.isStale, isTrue);
    expect(cached.fetchedAt, now);
    expect(_keys(preferences), [_key('NVDA')]);
    for (final entry in protected.entries) {
      expect(preferences.get(entry.key), entry.value, reason: entry.key);
    }
    _expectBounds(api, preferences);
  });

  test('a valid oversized live response is usable but is never cached', () async {
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((_) async => http.Response(jsonEncode({
          ..._chart('NVDA'),
          'fixture_padding': String.fromCharCodes(
              List<int>.filled(MarketDataApi.maximumCacheEntryBytes, 120)),
        }), 200)));
    addTearDown(api.close);
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.latestPrice, 102);
    expect(chart.isCached, isFalse);
    expect(api.debugMemoryCacheEntries, 0);
    expect(_keys(preferences), isEmpty);
  });

  test('close clears retained payloads and rejects a late HTTP cache write', () async {
    final preferences = await SharedPreferences.getInstance();
    final started = Completer<void>();
    final late = Completer<http.Response>();
    var requests = 0;
    final api = MarketDataApi(preferences: preferences, now: () => now,
        client: MockClient((request) async {
          if (++requests == 1) return http.Response(jsonEncode(_chart('NVDA')), 200);
          started.complete();
          return late.future;
        }));
    addTearDown(api.close);
    await api.fetchDaily('NVDA', StockMarket.us);
    expect(api.debugMemoryCacheEntries, 1);
    final before = preferences.getString(_key('NVDA'));
    final pending = api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    final rejected = expectLater(pending, throwsA(isA<StateError>()));
    await started.future;
    api.close();
    await rejected;
    late.complete(http.Response(jsonEncode(_chart('NVDA', price: 999)), 200));
    await Future<void>.delayed(Duration.zero);
    expect(api.debugMemoryCacheEntries, 0);
    expect(api.debugMemoryCacheBytes, 0);
    expect(preferences.getString(_key('NVDA')), before);
  });

  test('closing before preferences initialization cannot admit a late write', () async {
    final preferences = await SharedPreferences.getInstance();
    final latePreferences = Completer<SharedPreferences>();
    final loaderStarted = Completer<void>();
    var httpCalls = 0;
    final api = MarketDataApi(now: () => now, preferencesLoader: () {
      loaderStarted.complete();
      return latePreferences.future;
    }, client: MockClient((_) async {
      httpCalls++;
      return http.Response(jsonEncode(_chart('NVDA')), 200);
    }));
    addTearDown(api.close);
    final pending = api.fetchDaily('NVDA', StockMarket.us);
    final rejected = expectLater(pending, throwsA(isA<StateError>()));
    await loaderStarted.future;
    api.close();
    latePreferences.complete(preferences);
    await rejected;
    expect(httpCalls, 0);
    expect(_keys(preferences), isEmpty);
    expect(api.debugMemoryCacheBytes, 0);
  });

  test('a stalled cache writer is quarantined without blocking subsequent live quotes', () async {
    final preferences = await SharedPreferences.getInstance();
    final stalled = Completer<bool>();
    var writes = 0;
    final api = MarketDataApi(preferences: preferences, now: () => now,
        storageTimeout: const Duration(milliseconds: 100),
        cacheWriter: (_, _, _) {
          writes++;
          return stalled.future;
        }, client: MockClient((request) async => http.Response(
            jsonEncode(_chart(request.url.pathSegments.last)), 200)));
    addTearDown(api.close);
    final first = await Future.wait([
      for (var index = 0; index < 5; index++)
        api.fetchDaily(_symbol(index), StockMarket.us),
    ]).timeout(const Duration(seconds: 2));
    expect(first.every((chart) => !chart.isCached && chart.latestPrice == 102), isTrue);
    expect(writes, 1, reason: 'An unresolved native write must disable this cache lane.');
    final second = await Future.wait([
      for (var index = 5; index < 10; index++)
        api.fetchDaily(_symbol(index), StockMarket.us),
    ]).timeout(const Duration(seconds: 2));
    expect(second.every((chart) => !chart.isStale && chart.latestPrice == 102), isTrue);
    expect(writes, 1, reason: 'Repeated scans must not add more hanging native writes.');
    api.close();
    stalled.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(api.debugMemoryCacheEntries, 0);
    expect(_keys(preferences), isEmpty);
  });
}

String _symbol(int index) => 'CACHE${index.toString().padLeft(3, '0')}';
String _key(String symbol) => '${MarketDataApi.cachePrefix}us:$symbol:1d:6mo';
List<String> _keys(SharedPreferences preferences) => preferences.getKeys()
    .where((key) => key.startsWith(MarketDataApi.cachePrefix)).toList()..sort();

void _expectBounds(MarketDataApi api, SharedPreferences preferences) {
  expect(api.debugMemoryCacheEntries, lessThanOrEqualTo(MarketDataApi.maximumCacheEntries));
  expect(api.debugMemoryCacheBytes, lessThanOrEqualTo(MarketDataApi.maximumCacheBytes));
  final keys = _keys(preferences);
  expect(keys.length, lessThanOrEqualTo(MarketDataApi.maximumCacheEntries));
  var bytes = 0;
  for (final key in keys) {
    final size = utf8.encode(preferences.getString(key)!).length;
    expect(size, lessThanOrEqualTo(MarketDataApi.maximumCacheEntryBytes));
    bytes += size;
  }
  expect(bytes, lessThanOrEqualTo(MarketDataApi.maximumCacheBytes));
}

String _envelope(String symbol, DateTime fetchedAt) => jsonEncode({
  'fetched_at': fetchedAt.toIso8601String(),
  'document': _chart(symbol, quoteAt: fetchedAt),
});

Map<String, dynamic> _chart(String symbol, {double price = 102, DateTime? quoteAt}) {
  int unix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
  final start = DateTime.utc(2026, 10, 16, 13, 30);
  return {'chart': {'error': null, 'result': [{
    'meta': {'symbol': symbol, 'currency': 'USD',
      'exchangeTimezoneName': 'America/New_York', 'gmtoffset': -14400,
      'regularMarketPrice': price,
      'regularMarketTime': unix(quoteAt ?? DateTime.utc(2026, 10, 16, 16)),
      'currentTradingPeriod': {'regular': {
        'start': unix(start), 'end': unix(DateTime.utc(2026, 10, 16, 20)),
      }}},
    'timestamp': [unix(start.subtract(const Duration(days: 1))), unix(start)],
    'indicators': {'quote': [{
      'open': [98, 100], 'high': [103, 104], 'low': [97, 99],
      'close': [100, 102], 'volume': [1600, 1200],
    }]},
  }]}};
}
