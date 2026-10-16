import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';

http.Response _rows(List<String> codes) => http.Response(
  jsonEncode(codes.map((code) => {
    '公司代號': code, '公司簡稱': '測試公司$code', '產業別': '24',
  }).toList()), 200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Set<String> _symbols(UniverseSnapshot snapshot) =>
    snapshot.stocks.map((stock) => stock.symbol).toSet();

Map<String, dynamic> _sources(SharedPreferences preferences) {
  final cache = jsonDecode(preferences.getString(
      StockUniverseService.cacheKey(StockMarket.tw))!) as Map<String, dynamic>;
  return (cache['tw_exchange_sources'] as Map<String, dynamic>)['sources']
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalTime = DateTime.utc(2026, 10, 16, 1);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('alternating failed exchanges retain only that exchange and survive restart', () async {
    final preferences = await SharedPreferences.getInstance();
    var time = originalTime;
    var twseFails = false;
    var tpexFails = false;
    var twse = ['2330', '2603'];
    var tpex = ['6488', '8358'];
    StockUniverseService service() => StockUniverseService(useTwCsvFallback: false,
      preferences: preferences, now: () => time,
      client: MockClient((request) async {
        final listed = request.url == StockUniverseService.twEndpoint;
        return (listed ? twseFails : tpexFails)
            ? http.Response('temporarily unavailable', 503)
            : _rows(listed ? twse : tpex);
      }),
    );
    var current = service();
    try {
      final first = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(first), {'2330.TW', '2603.TW', '6488.TWO', '8358.TWO'});
      twseFails = true;
      tpex = ['6488']; // A successful exchange must actually remove 8358.
      time = originalTime.add(const Duration(minutes: 10));
      final partial = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(partial), {'2330.TW', '2603.TW', '6488.TWO'});
      expect(partial.isComplete, isFalse);
      expect(partial.isCached, isTrue);
      expect(partial.asOf, originalTime);
      expect(partial.warnings.join(' '), contains('TWSE 更新失敗'));
      expect((_sources(preferences)['TWSE'] as Map)['retrieved_at'],
          originalTime.toIso8601String());
      current.close();

      // A new instance must retain the TPEx date, not use the new composite
      // retrieval time to make failed TPEx membership appear freshly fetched.
      current = service();
      twseFails = false;
      tpexFails = true;
      twse = ['2330'];
      time = originalTime.add(const Duration(minutes: 20));
      final reverse = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(reverse), {'2330.TW', '6488.TWO'});
      expect(reverse.asOf, originalTime.add(const Duration(minutes: 10)));
      expect(reverse.isComplete, isFalse);
      expect(reverse.warnings.join(' '), contains('TPEx 更新失敗'));
      expect((_sources(preferences)['TPEx'] as Map)['retrieved_at'],
          originalTime.add(const Duration(minutes: 10)).toIso8601String());

      tpexFails = false;
      time = originalTime.add(const Duration(minutes: 30));
      final recovered = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(recovered), {'2330.TW', '6488.TWO'});
      expect(recovered.asOf, time);
      expect(recovered.isCached, isFalse);
      expect(recovered.warnings.join(' '), isNot(contains('沿用最後成功')));
      expect(recovered.stocks.every((stock) =>
          !stock.toJson().containsKey('price')), isTrue);
    } finally {
      current.close();
    }
  });

  test('a mixed cached full-sized list never claims current complete coverage', () async {
    var failTwse = false;
    final service = StockUniverseService(useTwCsvFallback: false, now: () => originalTime,
      client: MockClient((request) async {
        if (request.url == StockUniverseService.twEndpoint) {
          return failTwse ? http.Response('blocked', 403)
              : _rows(List.generate(800, (index) => '${1000 + index}'));
        }
        return _rows(List.generate(800, (index) => '${4000 + index}'));
      }),
    );
    try {
      final full = await service.load(StockMarket.tw, forceRefresh: true);
      expect(full.totalCount, 1600);
      expect(full.isComplete, isTrue);
      failTwse = true;
      final mixed = await service.load(StockMarket.tw, forceRefresh: true);
      expect(mixed.totalCount, 1600);
      expect(mixed.isComplete, isFalse);
      expect(mixed.warnings.join(' '), contains('1/2'));
      expect(mixed.warnings.join(' '), contains('HTTP 403'));
    } finally {
      service.close();
    }
  });

  test('cold partial TW load uses only failed exchange bundled identities with original date', () async {
    final preferences = await SharedPreferences.getInstance();
    var tpex = ['6488'];
    StockUniverseService service() => StockUniverseService(useTwCsvFallback: false,
      preferences: preferences, now: () => originalTime,
      client: MockClient((request) async =>
        request.url == StockUniverseService.twEndpoint
            ? http.Response('unavailable', 503) : _rows(tpex)),
    );
    var current = service();
    try {
      final first = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(first), contains('2330.TW'));
      expect(first.stocks.where((stock) => stock.symbol.endsWith('.TWO'))
          .map((stock) => stock.symbol), ['6488.TWO']);
      expect(first.isComplete, isFalse);
      expect(first.isCached, isTrue);
      expect(first.asOf, DateTime.utc(2026, 10, 6));
      expect(first.warnings.join(' '), contains('成分日期未驗證'));
      expect(_sources(preferences).containsKey('TWSE'), isFalse,
          reason: 'Bundled identities are not a successfully observed TWSE feed.');
      current.close();
      current = service();
      tpex = ['8358'];
      final next = await current.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(next), contains('2330.TW'));
      expect(_symbols(next), isNot(contains('6488.TWO')));
      expect(_symbols(next), contains('8358.TWO'));
      expect(next.asOf, DateTime.utc(2026, 10, 6));
      expect(next.warnings.join(' '), contains('成分日期未驗證'));
      expect(_sources(preferences).containsKey('TWSE'), isFalse);
    } finally {
      current.close();
    }
  });

  test('cold TPEx failure cannot replace successful TWSE membership with bundled extras', () async {
    final service = StockUniverseService(useTwCsvFallback: false, now: () => originalTime,
      client: MockClient((request) async =>
        request.url == StockUniverseService.twEndpoint
            ? _rows(['2330']) : http.Response('blocked', 403)),
    );
    try {
      final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
      expect(snapshot.stocks.where((stock) => stock.symbol.endsWith('.TW'))
          .map((stock) => stock.symbol), ['2330.TW']);
      expect(_symbols(snapshot), contains('6488.TWO'));
      expect(snapshot.asOf, DateTime.utc(2026, 10, 6));
      expect(snapshot.isComplete, isFalse);
      expect(snapshot.warnings.join(' '), contains('TPEx 無可用的官方名單快取'));
    } finally {
      service.close();
    }
  });

  test('legacy official v3 TW cache is split without renewing source timestamps', () async {
    final preferences = await SharedPreferences.getInstance();
    final first = StockUniverseService(useTwCsvFallback: false, preferences: preferences,
      now: () => originalTime, client: MockClient((request) async =>
        _rows(request.url == StockUniverseService.twEndpoint ? ['2330'] : ['6488'])),
    );
    await first.load(StockMarket.tw, forceRefresh: true);
    first.close();
    final key = StockUniverseService.cacheKey(StockMarket.tw);
    final legacy = jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    legacy.remove('tw_exchange_sources');
    await preferences.setString(key, jsonEncode(legacy));
    final next = StockUniverseService(useTwCsvFallback: false, preferences: preferences,
      now: () => originalTime.add(const Duration(days: 1)),
      client: MockClient((request) async => request.url == StockUniverseService.twEndpoint
          ? http.Response('blocked', 403) : _rows(['8358'])),
    );
    try {
      final snapshot = await next.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(snapshot), {'2330.TW', '8358.TWO'});
      expect(snapshot.asOf, originalTime);
      expect((_sources(preferences)['TWSE'] as Map)['retrieved_at'],
          originalTime.toIso8601String());
    } finally {
      next.close();
    }
  });

  test('hung failed exchange times out and late response never rewrites membership', () async {
    final preferences = await SharedPreferences.getInstance();
    final late = Completer<http.Response>();
    var hang = false;
    final service = StockUniverseService(useTwCsvFallback: false, preferences: preferences,
      now: () => originalTime, requestTimeout: const Duration(milliseconds: 25),
      client: MockClient((request) async {
        if (request.url == StockUniverseService.twEndpoint) {
          return hang ? late.future : _rows(['2330']);
        }
        return _rows(['6488']);
      }),
    );
    try {
      await service.load(StockMarket.tw, forceRefresh: true);
      hang = true;
      final snapshot = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(snapshot), {'2330.TW', '6488.TWO'});
      expect(snapshot.warnings.join(' '), contains('連線逾時'));
      late.complete(_rows(['9998']));
      await Future<void>.delayed(Duration.zero);
      final stored = preferences.getString(StockUniverseService.cacheKey(StockMarket.tw));
      expect(stored, isNot(contains('9998.TW')));
    } finally {
      service.close();
    }
  });

  test('refreshing a peer cannot keep an exchange cache alive past thirty days', () async {
    final preferences = await SharedPreferences.getInstance();
    var time = originalTime;
    var failTwse = false;
    final service = StockUniverseService(useTwCsvFallback: false, preferences: preferences,
      now: () => time, client: MockClient((request) async =>
        request.url == StockUniverseService.twEndpoint
            ? (failTwse ? http.Response('blocked', 403) : _rows(['9998']))
            : _rows(['6488'])),
    );
    try {
      await service.load(StockMarket.tw, forceRefresh: true);
      failTwse = true;
      time = originalTime.add(const Duration(days: 20));
      final beforeExpiry = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(beforeExpiry), contains('9998.TW'));
      expect(beforeExpiry.asOf, originalTime);
      time = originalTime.add(const Duration(days: 31));
      final expired = await service.load(StockMarket.tw, forceRefresh: true);
      expect(_symbols(expired), isNot(contains('9998.TW')));
      expect(_symbols(expired), contains('2330.TW'));
      expect(expired.isComplete, isFalse);
      expect(expired.asOf, DateTime.utc(2026, 10, 6));
      expect(expired.warnings.join(' '), contains('超過 30 天'));
      expect(expired.warnings.join(' '), contains('成分日期未驗證'));
      expect(_sources(preferences).containsKey('TWSE'), isFalse);
    } finally {
      service.close();
    }
  });

  test('closing an active refresh rejects late replies and cannot rewrite storage', () async {
    final preferences = await SharedPreferences.getInstance();
    var waitForTwse = false;
    final started = Completer<void>();
    final late = Completer<http.Response>();
    final service = StockUniverseService(useTwCsvFallback: false, preferences: preferences,
      now: () => originalTime,
      client: MockClient((request) async {
        if (request.url == StockUniverseService.twEndpoint) {
          if (waitForTwse) {
            started.complete();
            return late.future;
          }
          return _rows(['2330']);
        }
        return _rows(['6488']);
      }),
    );
    try {
      await service.load(StockMarket.tw, forceRefresh: true);
      final key = StockUniverseService.cacheKey(StockMarket.tw);
      final beforeClose = preferences.getString(key);
      waitForTwse = true;
      final operation = service.load(StockMarket.tw, forceRefresh: true);
      final rejected = expectLater(operation, throwsStateError);
      await started.future.timeout(const Duration(seconds: 1));
      service.close();
      await rejected;
      late.complete(_rows(['9998']));
      await Future<void>.delayed(Duration.zero);
      expect(preferences.getString(key), beforeClose);
      await expectLater(service.load(StockMarket.tw), throwsStateError);
    } finally {
      service.close();
    }
  });
}
