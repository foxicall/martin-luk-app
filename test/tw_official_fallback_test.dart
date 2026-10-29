import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';

// Explicit issuer fixtures. These are not live quotes or live-test evidence.
final _now = DateTime.utc(2026, 10, 16, 5);
final _publicationInstant = DateTime.utc(2026, 10, 15, 16);

http.Response _jsonRows(List<String> codes) => http.Response(
      jsonEncode(codes.map((code) => {
        '公司代號': code,
        '公司名稱': '測試公司$code股份有限公司',
        '公司簡稱': '測試$code',
        '產業別': '24',
      }).toList()),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _csvRows(List<String> codes, {String date = '1151016'}) =>
    http.Response.bytes(
      utf8.encode('\uFEFF出表日期,公司代號,公司名稱,公司簡稱,產業別\r\n'
          '${codes.map((code) => '$date,$code,測試公司$code股份有限公司,測試$code,24').join('\r\n')}\r\n'),
      200,
      headers: {'content-type': 'text/csv; charset=utf-8'},
    );

Set<String> _symbols(UniverseSnapshot value) =>
    value.stocks.map((stock) => stock.symbol).toSet();

Map<String, dynamic> _storedSources(SharedPreferences preferences) {
  final stored = jsonDecode(preferences.getString(
      StockUniverseService.cacheKey(StockMarket.tw))!) as Map<String, dynamic>;
  return (stored['tw_exchange_sources'] as Map<String, dynamic>)['sources']
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('CSV backup is enabled by default and both official CSVs can complete coverage', () async {
    final requests = <Uri>[];
    final preferences = await SharedPreferences.getInstance();
    final client = MockClient((request) async {
      requests.add(request.url);
      expect(request.headers['user-agent'], contains('Mozilla/5.0'));
      expect(request.headers['accept'], contains('text/csv'));
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return _csvRows(List.generate(800, (index) => '${1000 + index}'));
      }
      if (request.url == StockUniverseService.twOtcCsvEndpoint) {
        return _csvRows(List.generate(800, (index) => '${4000 + index}'));
      }
      return http.Response('Explicit fixture HTTP 503', 503);
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);

    expect(service.useTwCsvFallback, isTrue);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(requests.toSet(), {
      StockUniverseService.twEndpoint, StockUniverseService.twOtcEndpoint,
      StockUniverseService.twCsvEndpoint, StockUniverseService.twOtcCsvEndpoint,
    });
    expect(requests.length, 4);
    expect(snapshot.totalCount, 1600);
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.isCached, isFalse);
    expect(snapshot.asOf, _publicationInstant);
    expect(snapshot.retrievedAt, _now);
    expect(snapshot.warnings.join(' '), contains('HTTP 503'));
    expect(snapshot.warnings.join(' '), contains('官方 CSV 備援'));
    expect(snapshot.warnings.join(' '), contains('2026-10-16（台北日期）'));
    final sources = _storedSources(preferences);
    for (final exchange in ['TWSE', 'TPEx']) {
      expect((sources[exchange] as Map)['as_of'],
          _publicationInstant.toIso8601String());
      expect((sources[exchange] as Map)['retrieved_at'],
          _now.toIso8601String());
    }
  });

  test('successful JSON feeds do not make an unnecessary CSV request', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return _jsonRows(request.url == StockUniverseService.twEndpoint
          ? ['2330'] : ['6488']);
    });
    final service = StockUniverseService(client: client, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(_symbols(snapshot), {'2330.TW', '6488.TWO'});
    expect(requests, hasLength(2));
    expect(snapshot.warnings.join(' '), isNot(contains('官方 CSV 備援')));
  });

  test('a primary timeout uses only the remaining budget for the CSV backup', () async {
    final late = Completer<http.Response>();
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url == StockUniverseService.twEndpoint) return late.future;
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return _csvRows(['2330']);
      }
      return _jsonRows(['6488']);
    });
    final service = StockUniverseService(client: client, now: () => _now,
        requestTimeout: const Duration(milliseconds: 120));
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(_symbols(snapshot), {'2330.TW', '6488.TWO'});
    expect(requests, contains(StockUniverseService.twCsvEndpoint));
    expect(snapshot.warnings.join(' '), contains('連線逾時'));
    expect(snapshot.warnings.join(' '), contains('官方 CSV 備援'));
    late.completeError(StateError('Explicit late primary failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test('both stalled sources share one deadline and late replies cannot write cache', () async {
    final preferences = await SharedPreferences.getInstance();
    final late = <Completer<http.Response>>[];
    final requests = <Uri>[];
    final started = Stopwatch();
    final client = MockClient((request) async {
      if (!started.isRunning) started.start();
      requests.add(request.url);
      final pending = Completer<http.Response>();
      late.add(pending);
      return pending.future;
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => _now,
        requestTimeout: const Duration(milliseconds: 80));
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    started.stop();
    expect(started.elapsed, lessThan(const Duration(milliseconds: 350)),
        reason: 'JSON and CSV must share 80 ms, not each get an 8s timeout.');
    expect(requests.toSet(), {
      StockUniverseService.twEndpoint, StockUniverseService.twOtcEndpoint,
      StockUniverseService.twCsvEndpoint, StockUniverseService.twOtcCsvEndpoint,
    });
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.isCached, isTrue);
    expect(snapshot.warnings.join(' '), contains('連線逾時'));
    final before = preferences.getString(
        StockUniverseService.cacheKey(StockMarket.tw));
    for (final pending in late) {
      pending.completeError(StateError('Explicit late fixture failure'));
    }
    await Future<void>.delayed(Duration.zero);
    expect(preferences.getString(
        StockUniverseService.cacheKey(StockMarket.tw)), before);
  });

  test('malformed CSV preserves old exchange membership and its original dates', () async {
    final preferences = await SharedPreferences.getInstance();
    var fail = false;
    var now = _now;
    final client = MockClient((request) async {
      if (request.url == StockUniverseService.twOtcEndpoint) {
        return _jsonRows(['6488']);
      }
      if (request.url == StockUniverseService.twEndpoint) {
        return fail ? http.Response('Explicit fixture 403', 403)
            : _jsonRows(['9998']);
      }
      return http.Response('<html>Explicit fixture blocked page</html>', 200,
          headers: {'content-type': 'text/html'});
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => now);
    addTearDown(service.close);
    addTearDown(client.close);
    await service.load(StockMarket.tw, forceRefresh: true);
    fail = true;
    now = _now.add(const Duration(days: 1));
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(_symbols(snapshot), {'9998.TW', '6488.TWO'});
    expect(snapshot.isCached, isTrue);
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.asOf, _now);
    expect(snapshot.warnings.join(' '), contains('HTTP 403'));
    expect(snapshot.warnings.join(' '), contains('資料格式無效'));
    expect(snapshot.warnings.join(' '), contains('沿用最後成功取得'));
    final source = _storedSources(preferences)['TWSE'] as Map;
    expect(source['as_of'], _now.toIso8601String());
    expect(source['retrieved_at'], _now.toIso8601String());
  });

  test('CSV identity parsing retains exchange suffixes and ordinary-stock exclusions', () async {
    final client = MockClient((request) async {
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return _csvRows(['2330', '0050', '9110', '2330A']);
      }
      if (request.url == StockUniverseService.twOtcCsvEndpoint) {
        return _csvRows(['6488', '9103']);
      }
      return http.Response('Explicit fixture 503', 503);
    });
    final service = StockUniverseService(client: client, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(_symbols(snapshot), {'2330.TW', '6488.TWO'});
    expect(snapshot.stocks.first.abbrEn, 'TSMC');
    expect(snapshot.isCached, isFalse);
    expect(snapshot.asOf, _publicationInstant);
  });

  test('CSV publication dates cannot be replaced with the current retrieval time', () async {
    final client = MockClient((request) async {
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return _csvRows(['2330'], date: '1151014');
      }
      if (request.url == StockUniverseService.twOtcCsvEndpoint) {
        return _csvRows(['6488'], date: '1151015');
      }
      return http.Response('Explicit fixture 503', 503);
    });
    final service = StockUniverseService(client: client, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(snapshot.asOf, DateTime.utc(2026, 10, 13, 16));
    expect(snapshot.retrievedAt, _now);
    final preferences = await SharedPreferences.getInstance();
    final sources = _storedSources(preferences);
    expect((sources['TWSE'] as Map)['as_of'],
        DateTime.utc(2026, 10, 13, 16).toIso8601String());
    expect((sources['TPEx'] as Map)['as_of'],
        DateTime.utc(2026, 10, 14, 16).toIso8601String());
  });

  test('monthly TWSE CSV retains its 40-day source date and expires after 45 days', () async {
    final preferences = await SharedPreferences.getInstance();
    var now = _now;
    var failCsv = false;
    final client = MockClient((request) async {
      if (request.url == StockUniverseService.twOtcEndpoint) {
        return _jsonRows(['6488']);
      }
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return failCsv ? http.Response('Explicit malformed CSV fixture', 200)
            : _csvRows(['9998'], date: '1150906');
      }
      return http.Response('Explicit fixture 503', 503);
    });
    StockUniverseService create() => StockUniverseService(client: client,
        preferences: preferences, now: () => now);
    var service = create();
    addTearDown(client.close);
    try {
      final originalDate = DateTime.utc(2026, 9, 5, 16);
      final first = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(first), {'9998.TW', '6488.TWO'});
      expect(first.asOf, originalDate);
      expect(first.isCached, isFalse);
      expect(first.warnings.join(' '), contains('每月更新'));
      expect(first.warnings.join(' '), contains('2026-09-06（台北日期）'));
      service.close();

      failCsv = true;
      now = DateTime.utc(2026, 10, 17, 5); // 41 publication calendar days.
      service = create();
      final preserved = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(preserved), {'9998.TW', '6488.TWO'});
      expect(preserved.asOf, originalDate);
      expect(preserved.isCached, isTrue);
      expect(preserved.isComplete, isFalse);
      final source = _storedSources(preferences)['TWSE'] as Map;
      expect(source['maximum_age_days'], 45);
      expect(source['as_of'], originalDate.toIso8601String());
      expect(source['retrieved_at'], _now.toIso8601String());

      now = DateTime.utc(2026, 10, 22, 5); // 46 days: never renew from its peer.
      final expired = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(expired), isNot(contains('9998.TW')));
      expect(expired.isComplete, isFalse);
      expect(_storedSources(preferences).containsKey('TWSE'), isFalse);
    } finally {
      service.close();
    }
  });

  test('validated monthly aggregate cache keeps its 24h TTL without extra HTTP', () async {
    var now = _now;
    var requests = 0;
    final preferences = await SharedPreferences.getInstance();
    final client = MockClient((request) async {
      requests++;
      if (request.url == StockUniverseService.twCsvEndpoint) {
        return _csvRows(List.generate(800, (index) => '${1000 + index}'),
            date: '1150906');
      }
      if (request.url == StockUniverseService.twOtcCsvEndpoint) {
        return _csvRows(List.generate(800, (index) => '${4000 + index}'));
      }
      return http.Response('Explicit fixture 503', 503);
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => now);
    addTearDown(service.close);
    addTearDown(client.close);
    final first = await service.load(StockMarket.tw, forceRefresh: true);
    expect(first.isComplete, isTrue);
    expect(first.asOf, DateTime.utc(2026, 9, 5, 16));
    expect(requests, 4);
    now = now.add(const Duration(hours: 1));
    final cached = await service.load(StockMarket.tw);
    expect(requests, 4);
    expect(cached.isCached, isTrue);
    expect(cached.isComplete, isTrue);
    expect(cached.asOf, first.asOf);
    expect(cached.retrievedAt, first.retrievedAt);
    expect(cached.warnings.join(' '), isNot(contains('已超過 30 天')));
  });

  test('expired TPEx CSV invalidates even an aggregate cache retrieved two minutes ago', () async {
    var now = DateTime.utc(2026, 10, 16, 15, 59); // Taiwan 23:59.
    var recovered = false;
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      if (request.url == StockUniverseService.twEndpoint) {
        return _jsonRows(['2330']);
      }
      if (request.url == StockUniverseService.twOtcEndpoint) {
        return recovered ? _jsonRows(['8358'])
            : http.Response('Explicit fixture 503', 503);
      }
      return _csvRows(['6488'], date: '1151009');
    });
    final service = StockUniverseService(client: client, now: () => now);
    addTearDown(service.close);
    addTearDown(client.close);
    final first = await service.load(StockMarket.tw, forceRefresh: true);
    expect(_symbols(first), {'2330.TW', '6488.TWO'});
    expect(requests, 3);
    now = now.add(const Duration(minutes: 2)); // CSV now eight calendar days old.
    recovered = true;
    final next = await service.load(StockMarket.tw);
    expect(requests, 5, reason: 'A valid aggregate TTL cannot renew an expired peer.');
    expect(_symbols(next), {'2330.TW', '8358.TWO'});
    expect(next.isCached, isFalse);
    expect(next.warnings.join(' '), contains('超過 7 天'));
  });

  test('aggregate cache requires an exact source union and cannot give JSON a CSV age policy', () async {
    var requests = 0;
    final preferences = await SharedPreferences.getInstance();
    final client = MockClient((request) async {
      requests++;
      return _jsonRows(List.generate(800,
          (index) => '${(request.url == StockUniverseService.twEndpoint ? 1000 : 4000) + index}'));
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);
    await service.load(StockMarket.tw, forceRefresh: true);
    final key = StockUniverseService.cacheKey(StockMarket.tw);
    var stored = jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    var sources = (stored['tw_exchange_sources'] as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;
    ((sources['TWSE'] as Map)['stocks'] as List).removeLast();
    await preferences.setString(key, jsonEncode(stored));
    final repaired = await service.load(StockMarket.tw);
    expect(repaired.totalCount, 1600);
    expect(repaired.isCached, isFalse);
    expect(requests, 4);

    stored = jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    sources = (stored['tw_exchange_sources'] as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;
    (sources['TWSE'] as Map)['maximum_age_days'] = 45;
    await preferences.setString(key, jsonEncode(stored));
    final checked = await service.load(StockMarket.tw);
    expect(checked.totalCount, 1600);
    expect(checked.isCached, isFalse);
    expect(requests, 6);
    expect((_storedSources(preferences)['TWSE'] as Map)['maximum_age_days'], 30);
    expect((_storedSources(preferences)['TWSE'] as Map)['metadata_format'],
        'official_json');
  });

  test('closing a pending CSV attempt rejects late completion without cache writes', () async {
    final preferences = await SharedPreferences.getInstance();
    final csvStarted = Completer<void>();
    final late = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url == StockUniverseService.twCsvEndpoint) {
        csvStarted.complete();
        return late.future;
      }
      if (request.url == StockUniverseService.twOtcEndpoint) {
        return _jsonRows(['6488']);
      }
      return http.Response('Explicit fixture 503', 503);
    });
    final service = StockUniverseService(client: client,
        preferences: preferences, now: () => _now);
    addTearDown(service.close);
    addTearDown(client.close);
    final operation = service.load(StockMarket.tw, forceRefresh: true);
    final rejected = expectLater(operation, throwsStateError);
    await csvStarted.future.timeout(const Duration(seconds: 1));
    service.close();
    await rejected;
    late.complete(_csvRows(['9998']));
    await Future<void>.delayed(Duration.zero);
    expect(preferences.getString(
        StockUniverseService.cacheKey(StockMarket.tw)), isNull);
    await expectLater(service.load(StockMarket.tw), throwsStateError);
  });

  test('disabled CSV fallback keeps cache-only diagnostics to the two JSON feeds', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response('Explicit fixture 503', 503);
    });
    final service = StockUniverseService(client: client, now: () => _now,
        useTwCsvFallback: false);
    addTearDown(service.close);
    addTearDown(client.close);
    final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
    expect(requests, hasLength(2));
    expect(snapshot.isCached, isTrue);
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.warnings.join(' '), isNot(contains('官方 CSV 備援')));
  });
}
