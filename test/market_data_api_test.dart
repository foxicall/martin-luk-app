import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

import 'support/controllable_http_client.dart';

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

  test('missing market metadata uses explicit market defaults without marking real quotes stale', () async {
    for (final market in StockMarket.values) {
      final data = _document(market);
      for (final field in ['symbol', 'currency', 'exchangeTimezoneName', 'gmtoffset']) {
        _meta(data).remove(field);
      }
      final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
          http.Response(jsonEncode(data), 200)));
      final chart = await api.fetchDaily(market == StockMarket.tw ? '2330.TW' : 'NVDA', market);
      expect(chart.currency, market.currency);
      expect(chart.exchangeTimezoneName,
          market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York');
      expect(chart.gmtoffset, market == StockMarket.tw ? 28800 : -14400);
      expect(chart.source, contains('供應商未提供交易所時區'));
      expect(chart.source, contains('供應商未提供幣別'));
      expect(chart.source, contains('供應商未提供 UTC 時差'));
      expect(chart.isCached, isFalse);
      expect(chart.isStale, isFalse);
      expect(chart.cacheWarning, isNull,
          reason: 'Metadata normalization is not a network failure or a stale-cache event.');
      if (market == StockMarket.us) expect(chart.isQuoteFresh(now), isTrue);
      api.close();
    }
  });

  test('missing New York offset follows winter DST rules rather than a fixed minus-four-hours value', () async {
    final winterNow = DateTime.utc(2026, 1, 6, 22);
    final data = _document(StockMarket.us);
    final start = DateTime.utc(2026, 1, 6, 14, 30);
    _meta(data).remove('gmtoffset');
    _meta(data)['regularMarketTime'] = _unix(DateTime.utc(2026, 1, 6, 21));
    _meta(data)['currentTradingPeriod'] = {'regular': {
      'start': _unix(start), 'end': _unix(DateTime.utc(2026, 1, 6, 21)),
    }};
    _result(data)['timestamp'] = [_unix(start.subtract(const Duration(days: 1))), _unix(start)];
    final api = MarketDataApi(now: () => winterNow, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.gmtoffset, -18000);
    expect(chart.completedDailyBars.length, 2);
    api.close();
  });

  test('an equivalent US/Eastern alias is normalized while contradictory metadata remains rejected', () async {
    final alias = _document(StockMarket.us);
    _meta(alias)['exchangeTimezoneName'] = 'US/Eastern';
    final accepted = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(alias), 200)));
    final chart = await accepted.fetchDaily('NVDA', StockMarket.us);
    expect(chart.exchangeTimezoneName, 'America/New_York');
    expect(chart.source, contains('已正規化'));
    accepted.close();
    for (final pair in [
      ('symbol', 'TSLA'), ('currency', 'TWD'),
      ('exchangeTimezoneName', 'Asia/Tokyo'), ('gmtoffset', 'invalid'),
    ]) {
      SharedPreferences.setMockInitialValues({});
      final invalid = _document(StockMarket.us);
      _meta(invalid)[pair.$1] = pair.$2;
      final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
          http.Response(jsonEncode(invalid), 200)));
      await expectLater(api.fetchDaily('NVDA', StockMarket.us),
          throwsA(isA<MarketDataException>()));
      api.close();
    }
  });

  test('a missing independent daily quote uses an actual candle price and its original timestamp', () async {
    final data = _document(StockMarket.us);
    _meta(data).remove('regularMarketPrice');
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.latestPrice, chart.bars.last.close);
    expect(chart.quoteTimestamp, chart.bars.last.timestamp);
    expect(chart.quoteTimestamp, isNot(chart.fetchedAt));
    expect(chart.source, contains('非獨立即時成交報價'));
    expect(chart.isQuoteFresh(now), isFalse,
        reason: 'A download time cannot make a historical candle quote fresh.');
    expect(chart.completedDailyBars.length, 1);
    api.close();
  });

  test('missing intraday session metadata never invents an opening range', () async {
    final data = _document(StockMarket.us);
    _meta(data).remove('currentTradingPeriod');
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchIntraday('NVDA', StockMarket.us);
    expect(chart.regularSessionBars, isEmpty);
    expect(chart.regularSessionStart, isNull);
    expect(chart.quoteIsInRegularSession, isFalse);
    expect(chart.source, contains('未提供當日常規交易時段'));
    api.close();
  });

  test('one malformed candle is isolated while the other observed candles remain usable', () async {
    final data = _document(StockMarket.us);
    (_result(data)['timestamp'] as List).insert(1, _unix(DateTime.utc(2026, 10, 13, 14)));
    for (final field in ['open', 'high', 'low', 'close', 'volume']) {
      (_values(data)[field] as List).insert(1, field == 'high' ? 'malformed' : 100);
    }
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.bars.length, 2);
    expect(chart.source, contains('已忽略 1 根'));
    expect(chart.bars.map((bar) => bar.close), [100, 102]);
    api.close();
  });

  test('finite numeric JSON strings are decoded but retain validated OHLCV and timing', () async {
    final data = _document(StockMarket.us);
    _result(data)['timestamp'] = (_result(data)['timestamp'] as List)
        .map((value) => value.toString()).toList();
    for (final field in ['open', 'high', 'low', 'close', 'volume']) {
      _values(data)[field] = (_values(data)[field] as List)
          .map((value) => value.toString()).toList();
    }
    for (final field in ['gmtoffset', 'regularMarketPrice', 'regularMarketTime']) {
      _meta(data)[field] = _meta(data)[field].toString();
    }
    final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
        http.Response(jsonEncode(data), 200)));
    final chart = await api.fetchDaily('NVDA', StockMarket.us);
    expect(chart.latestPrice, 102);
    expect(chart.bars.last.volume, 1200);
    expect(chart.gmtoffset, -14400);
    expect(chart.quoteTimestamp, now);
    api.close();
  });

  test('provider error descriptions and empty result failures are explicit', () async {
    for (final data in [
      {'chart': {'result': null, 'error': {
        'code': 'Not Found', 'description': 'No data found, symbol may be delisted',
      }}},
      {'chart': {'result': null, 'error': null}},
      {'chart': {'result': <Object>[], 'error': null}},
    ]) {
      final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
          http.Response(jsonEncode(data), 200)));
      final hasProviderError = (data['chart'] as Map)['error'] != null;
      await expectLater(api.fetchDaily('NVDA', StockMarket.us),
          throwsA(isA<MarketDataException>().having((error) => error.message,
            'message', contains(hasProviderError ? 'symbol may be delisted' : 'result 為空'))));
      api.close();
    }
  });

  test('chronology and missing unadjusted OHLC are not repaired with adjusted closes', () async {
    for (final adjustedOnly in [false, true]) {
      final data = _document(StockMarket.us);
      if (adjustedOnly) {
        _values(data)['close'] = <Object?>[null, null];
        (_result(data)['indicators'] as Map)['adjclose'] = [
          {'adjclose': [100, 102]},
        ];
      } else {
        final times = _result(data)['timestamp'] as List;
        times[1] = times[0];
      }
      final api = MarketDataApi(now: () => now, client: MockClient((_) async =>
          http.Response(jsonEncode(data), 200)));
      await expectLater(api.fetchDaily('NVDA', StockMarket.us),
          throwsA(isA<MarketDataException>()));
      api.close();
    }
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

  test('a stalled response body aborts and permits retry without closing a borrowed client', () async {
    final preferences = await SharedPreferences.getInstance();
    final blockedBody = Completer<List<int>>();
    var requests = 0, aborts = 0;
    final client = ControllableHttpClient((request) async {
      requests++;
      if (requests > 1) {
        return http.StreamedResponse(Stream.value(
            utf8.encode(jsonEncode(_document(StockMarket.us)))), 200);
      }
      expect(request, isA<http.AbortableRequest>());
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborts++;
        if (!blockedBody.isCompleted) blockedBody.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(blockedBody.future), 200);
    });
    final api = MarketDataApi(client: client, preferences: preferences,
        now: () => now, requestTimeout: const Duration(milliseconds: 30));
    addTearDown(api.close);
    await expectLater(api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true),
        throwsA(isA<MarketDataException>().having((error) => error.message,
          'message', contains('逾時'))));
    await Future<void>.delayed(Duration.zero);
    expect(aborts, 1, reason: 'The deadline cancels transport, even after HTTP headers arrive.');
    final retry = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(retry.latestPrice, 102);
    expect(retry.isStale, isFalse);
    expect(requests, 2);
    api.close();
    expect(client.closeCalls, 0, reason: 'An injected HTTP client retains caller ownership.');
  });

  test('US and TW API instances share five HTTP slots through the complete body', () async {
    final preferences = await SharedPreferences.getInstance();
    final bodies = <MapEntry<Completer<List<int>>, List<int>>>[];
    final waves = {for (final count in [5, 10, 12]) count: Completer<void>()};
    var sent = 0, active = 0, maximumActive = 0;
    Future<http.StreamedResponse> handle(http.BaseRequest request) async {
      final symbol = request.url.pathSegments.last;
      final market = symbol.endsWith('.TW') ? StockMarket.tw : StockMarket.us;
      final document = _document(market);
      _meta(document)['symbol'] = symbol;
      final body = Completer<List<int>>();
      bodies.add(MapEntry(body, utf8.encode(jsonEncode(document))));
      active++;
      if (active > maximumActive) maximumActive = active;
      sent++;
      waves[sent]?.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future.then((bytes) {
        active--;
        return bytes;
      })), 200);
    }

    final usClient = ControllableHttpClient(handle);
    final twClient = ControllableHttpClient(handle);
    final usApi = MarketDataApi(client: usClient, preferences: preferences, now: () => now);
    final twApi = MarketDataApi(client: twClient, preferences: preferences, now: () => now);
    addTearDown(usApi.close);
    addTearDown(twApi.close);
    const usSymbols = ['NVDA', 'TSLA', 'AAPL', 'AMD', 'META', 'MSFT'];
    const twSymbols = ['2330.TW', '2603.TW', '2454.TW', '2317.TW', '3017.TW', '1519.TW'];
    final requests = <Future<MarketChart>>[
      for (final symbol in usSymbols) usApi.fetchDaily(symbol, StockMarket.us, forceRefresh: true),
      for (final symbol in twSymbols) twApi.fetchDaily(symbol, StockMarket.tw, forceRefresh: true),
    ];
    for (final count in [5, 10, 12]) {
      await waves[count]!.future.timeout(const Duration(seconds: 2));
      expect(sent, count);
      expect(active, count == 12 ? 2 : 5,
          reason: 'Waiting for the response body must keep its global HTTP permit.');
      for (final entry in List<MapEntry<Completer<List<int>>, List<int>>>.of(bodies)) {
        if (!entry.key.isCompleted) entry.key.complete(entry.value);
      }
    }
    final charts = await Future.wait(requests).timeout(const Duration(seconds: 2));
    expect(charts.map((chart) => chart.symbol), [...usSymbols, ...twSymbols]);
    expect(charts.take(6).every((chart) => chart.currency == 'USD'), isTrue);
    expect(charts.skip(6).every((chart) => chart.currency == 'TWD'), isTrue);
    expect(charts.every((chart) => chart.latestPrice == 102 && !chart.isStale), isTrue);
    expect(maximumActive, 5);
    expect(active, 0);
    expect(usClient.closeCalls, 0);
    expect(twClient.closeCalls, 0);
  });

  test('timeout releases a shared request and a late reply cannot overwrite retry cache', () async {
    final preferences = await SharedPreferences.getInstance();
    final late = Completer<http.Response>();
    var requests = 0;
    final current = _document(StockMarket.us);
    _meta(current)['regularMarketPrice'] = 110;
    final api = MarketDataApi(preferences: preferences, now: () => now,
        requestTimeout: const Duration(milliseconds: 10),
        client: MockClient((_) => ++requests == 1 ? late.future
            : Future.value(http.Response(jsonEncode(current), 200))));
    await expectLater(Future.wait([
      api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true),
      api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true),
    ]), throwsA(isA<MarketDataException>()));
    expect(requests, 1);
    final retry = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(retry.latestPrice, 110);
    expect(retry.isStale, isFalse);
    late.complete(http.Response(jsonEncode(_document(StockMarket.us)), 200));
    await Future<void>.delayed(Duration.zero);
    final cached = await api.fetchDaily('NVDA', StockMarket.us);
    expect(cached.latestPrice, 110);
    expect(requests, 2);
    api.close();
  });

  test('SocketException retains a dated stale quote and does not block the next retry', () async {
    var requests = 0;
    final api = MarketDataApi(now: () => now,
        client: MockClient((_) async {
          if (++requests == 2) throw const SocketException('network disconnected');
          return http.Response(jsonEncode(_document(StockMarket.us)), 200);
        }));
    final first = await api.fetchDaily('NVDA', StockMarket.us);
    final stale = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(stale.isStale, isTrue);
    expect(stale.quoteTimestamp, first.quoteTimestamp);
    expect(stale.fetchedAt, first.fetchedAt);
    expect(stale.cacheWarning, contains('SocketException'));
    final next = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(next.isStale, isFalse);
    expect(requests, 3);
    api.close();
  });

  test('an unavailable preferences plugin cannot prevent HTTP or preserve a sync lock', () async {
    final unavailable = Completer<SharedPreferences>();
    var requests = 0;
    final api = MarketDataApi(now: () => now,
        preferencesLoader: () => unavailable.future,
        storageTimeout: const Duration(milliseconds: 5),
        client: MockClient((_) async {
          requests++;
          return http.Response(jsonEncode(_document(StockMarket.us)), 200);
        }));
    final first = await api.fetchDaily('NVDA', StockMarket.us);
    final next = await api.fetchDaily('NVDA', StockMarket.us, forceRefresh: true);
    expect(first.latestPrice, 102);
    expect(next.isStale, isFalse);
    expect(requests, 2);
    api.close();
  });

  test('a hanging rate-limit backoff shares the original request deadline', () async {
    final preferences = await SharedPreferences.getInstance();
    final never = Completer<void>();
    var requests = 0;
    final api = MarketDataApi(preferences: preferences, now: () => now,
        requestTimeout: const Duration(milliseconds: 10),
        delay: (_) => never.future,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 429, headers: {'retry-after': '1'});
        }));
    await expectLater(api.fetchDaily('NVDA', StockMarket.us),
        throwsA(isA<MarketDataException>().having((error) => error.message,
          'message', contains('逾時'))));
    expect(requests, 1);
    api.close();
  });

  test('Benchmarks and class-share IDs are normalized for Yahoo', () async {
    final requestedSymbols = <String>[];
    final api = MarketDataApi(now: () => now, client: MockClient((request) async {
      // Uri.path may contain %5E for '^'. pathSegments decodes the ticker,
      // so transport escaping cannot select the wrong market fixture.
      final symbol = request.url.pathSegments.last;
      requestedSymbols.add(symbol);
      final tw = symbol == '^TWII';
      final data = _document(tw ? StockMarket.tw : StockMarket.us);
      _meta(data)['symbol'] = symbol;
      return http.Response(jsonEncode(data), 200);
    }));
    addTearDown(api.close);
    final taiwan = await api.fetchBenchmark(StockMarket.tw);
    final usa = await api.fetchBenchmark(StockMarket.us);
    final classShare = await api.fetchDaily('brk.b', StockMarket.us);
    expect(requestedSymbols, ['^TWII', '^GSPC', 'BRK-B']);
    expect(taiwan.symbol, '^TWII');
    expect(taiwan.currency, 'TWD');
    expect(usa.symbol, '^GSPC');
    expect(usa.currency, 'USD');
    expect(classShare.symbol, 'BRK-B');
    expect(classShare.currency, 'USD');
    expect(canonicalSymbol('brk.b', StockMarket.us), 'BRK-B');
    expect(() => canonicalSymbol('2330.TW', StockMarket.us), throwsFormatException);
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
