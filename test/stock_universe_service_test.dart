import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 14, 1);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('S&P CSV parses quoted commas, escaped quotes, CRLF and Yahoo share classes', () async {
    final client = MockClient((request) async {
      expect(request.url, StockUniverseService.usEndpoint);
      return http.Response(
        '\ufeffSymbol,Name,Sector\r\n'
        'NVDA,"NVIDIA Corporation",Technology\r\n'
        'BRK.B,"Berkshire Hathaway, Inc.",Financials\r\n'
        'AAPL,"Apple ""Computer"", Inc.",Technology\r\n',
        200,
        headers: {'content-type': 'text/csv; charset=utf-8'},
      );
    });
    final service = StockUniverseService(client: client, now: () => now);
    final result = await service.load(StockMarket.us);
    expect(result.stocks.map((stock) => stock.symbol), ['AAPL', 'BRK-B', 'NVDA']);
    expect(result.stocks.first.nameEn, 'Apple "Computer", Inc.');
    expect(result.stocks.last.nameZh, '輝達');
    expect(result.stocks.last.abbrEn, 'Nvidia');
    expect(result.isComplete, isFalse, reason: 'A tiny successful reply is still partial.');
    expect(result.isCached, isFalse);
    expect(result.asOf, now);
    expect(result.warnings.join(' '), contains('覆蓋不足'));
    service.close();
  });

  test('quoted CSV preserves an embedded newline without splitting its issuer', () async {
    final service = StockUniverseService(
      client: MockClient((_) async => http.Response(
        'Symbol,Name,Sector\nAAPL,"Apple\nInc.",Technology\n', 200,
      )),
      now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(result.totalCount, 1);
    expect(result.stocks.single.nameEn, 'Apple\nInc.');
    service.close();
  });

  test('TWSE ordinary issuers retain names and exclude TDR, preferred shares and nonfour-digit codes', () async {
    final rows = [
      {'公司代號': '2330', '公司簡稱': '台積電', '公司名稱': '台灣積體電路製造股份有限公司',
        '英文全名': 'Taiwan Semiconductor Manufacturing Company Limited', '產業別': '24'},
      {'公司代號': 2603, '公司簡稱': '長榮', '公司名稱': '長榮海運股份有限公司', '產業別': '15'},
      {'公司代號': '9110', '公司簡稱': '越南控股', '公司名稱': '越南控股', '產業別': '91'},
      {'公司代號': '2330A', '公司簡稱': '特別股', '公司名稱': '特別股', '產業別': '24'},
      {'公司代號': '0050', '公司簡稱': '元大台灣50', '公司名稱': '元大台灣50'},
      {'公司代號': '9999', '公司簡稱': '範例', '公司名稱': '範例', '股票種類': '特別股'},
      {'公司代號': '9988', '公司簡稱': '範例TDR', '公司名稱': '範例TDR'},
    ];
    final service = StockUniverseService(
      client: MockClient((request) async {
        expect(request.url, StockUniverseService.twEndpoint);
        return http.Response(jsonEncode(rows), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
      }),
      now: () => now,
    );
    final result = await service.load(StockMarket.tw);
    expect(result.stocks.map((stock) => stock.symbol), ['2330.TW', '2603.TW']);
    expect(result.stocks.first.nameZh, '台積電');
    expect(result.stocks.first.nameFullZh, '台灣積體電路製造股份有限公司');
    expect(result.stocks.first.abbrEn, 'TSMC');
    expect(result.stocks.first.nameEn, 'Taiwan Semiconductor Manufacturing Company Limited');
    expect(result.isComplete, isFalse);
    service.close();
  });

  test('a substantial S&P provider list is complete and excludes unrelated bundled securities', () async {
    final symbols = List.generate(450, (index) => 'TEST$index');
    final body = ['Symbol,Name,Sector', for (final symbol in symbols) '$symbol,$symbol issuer,Test'].join('\n');
    final service = StockUniverseService(
      client: MockClient((_) async => http.Response(body, 200)),
      now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(result.totalCount, 450);
    expect(result.isComplete, isTrue);
    expect(result.stocks.any((stock) => stock.symbol == 'TSM'), isFalse,
      reason: 'A lookup dictionary is never appended to live index constituents.');
    service.close();
  });

  test('fresh cache survives a new instance without another HTTP request, force refresh bypasses it', () async {
    var requests = 0;
    final preferences = await SharedPreferences.getInstance();
    final client = MockClient((_) async {
      requests++;
      return http.Response('Symbol,Name,Sector\nNVDA,NVIDIA Corporation,Technology\n', 200);
    });
    final first = StockUniverseService(client: client, preferences: preferences, now: () => now);
    final live = await first.load(StockMarket.us);
    expect(live.isCached, isFalse);
    first.close();
    final second = StockUniverseService(client: client, preferences: preferences,
      now: () => now.add(const Duration(hours: 23)));
    final cached = await second.load(StockMarket.us);
    expect(cached.isCached, isTrue);
    expect(cached.asOf, now);
    expect(requests, 1);
    final forced = await second.load(StockMarket.us, forceRefresh: true);
    expect(forced.isCached, isFalse);
    expect(requests, 2);
    expect(forced.asOf, now.add(const Duration(hours: 23)));
    second.close();
  });

  test('failed refresh keeps a dated genuine cache for at most 30 days', () async {
    final preferences = await SharedPreferences.getInstance();
    final service = StockUniverseService(
      client: MockClient((_) async => http.Response('Symbol,Name,Sector\nNVDA,NVIDIA Corporation,Technology', 200)),
      preferences: preferences, now: () => now,
    );
    await service.load(StockMarket.us);
    service.close();
    final failing = StockUniverseService(
      client: MockClient((_) async => http.Response('Unavailable', 503)),
      preferences: preferences, now: () => now.add(const Duration(days: 5)),
    );
    final stale = await failing.load(StockMarket.us);
    expect(stale.isCached, isTrue);
    expect(stale.asOf, now);
    expect(stale.stocks.single.symbol, 'NVDA');
    expect(stale.warnings.join(' '), contains('HTTP 503'));
    expect(stale.warnings.join(' '), contains('成分可能已變更'));
    failing.close();

    final expired = StockUniverseService(
      client: MockClient((_) async => http.Response('Unavailable', 503)),
      preferences: preferences, now: () => now.add(const Duration(days: 31)),
    );
    final fallback = await expired.load(StockMarket.us);
    expect(fallback.source, contains('bundled'));
    expect(fallback.isComplete, isFalse);
    expect(fallback.totalCount, greaterThan(100));
    expect(fallback.warnings.join(' '), contains('超過 30 天'));
    expired.close();
  });

  test('bundle fallback clearly identifies a partial dictionary and never invents prices', () async {
    final service = StockUniverseService(
      client: MockClient((_) async => throw http.ClientException('offline')),
      now: () => now,
    );
    final fallback = await service.load(StockMarket.tw);
    expect(fallback.isCached, isTrue);
    expect(fallback.isComplete, isFalse);
    expect(fallback.asOf, DateTime.utc(2026, 10, 13));
    expect(fallback.source, contains('unverified membership'));
    expect(fallback.totalCount, greaterThanOrEqualTo(100));
    expect(fallback.stocks.any((stock) => stock.symbol == '2330.TW'), isTrue);
    expect(fallback.stocks.every((stock) => stock.market == StockMarket.tw), isTrue);
    expect(fallback.warnings.join(' '), contains('不是目前完整'));
    expect(fallback.stocks.first.toJson().containsKey('price'), isFalse);
    service.close();
  });

  test('malformed CSV produces a source failure, not a fake successful S&P universe', () async {
    for (final malformed in [
      '<html>Login required</html>',
      'Symbol,Name,Sector\nNVDA,"Unclosed,Technology',
      'Symbol,Name,Sector\nNVDA,NVIDIA,Technology\nNVDA,NVIDIA,Technology',
    ]) {
      SharedPreferences.setMockInitialValues({});
      final service = StockUniverseService(
        client: MockClient((_) async => http.Response(malformed, 200)), now: () => now,
      );
      final snapshot = await service.load(StockMarket.us, forceRefresh: true);
      expect(snapshot.isComplete, isFalse);
      expect(snapshot.source, contains('bundled'));
      expect(snapshot.warnings.join(' '), contains('資料格式無效'));
      service.close();
    }
  });

  test('corrupt, cross-market and future-date caches cannot override live retrieval', () async {
    final known = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
      nameZh: '輝達', nameFullZh: '', nameEn: 'NVIDIA Corporation', abbrEn: 'Nvidia');
    for (final value in [
      '{not json}',
      jsonEncode({'version': 1, 'market': 'us', 'source': 'test', 'is_complete': false,
        'as_of': now.add(const Duration(days: 1)).toIso8601String(),
        'stocks': [known.toJson()], 'warnings': <String>[]}),
      jsonEncode({'version': 1, 'market': 'tw', 'source': 'test', 'is_complete': false,
        'as_of': now.toIso8601String(), 'stocks': [known.toJson()], 'warnings': <String>[]}),
    ]) {
      SharedPreferences.setMockInitialValues({StockUniverseService.cacheKey(StockMarket.us): value});
      var requests = 0;
      final service = StockUniverseService(
        client: MockClient((_) async {
          requests++;
          return http.Response('Symbol,Name,Sector\nNVDA,NVIDIA Corporation,Technology', 200);
        }), now: () => now,
      );
      final snapshot = await service.load(StockMarket.us);
      expect(snapshot.isCached, isFalse);
      expect(snapshot.stocks.single.symbol, 'NVDA');
      expect(requests, 1);
      expect(snapshot.warnings, isNotEmpty);
      service.close();
    }
  });

  test('concurrent callers share one provider request; closed service rejects further work', () async {
    var requests = 0;
    final service = StockUniverseService(
      client: MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return http.Response('Symbol,Name,Sector\nNVDA,NVIDIA Corporation,Technology', 200);
      }), now: () => now,
    );
    final snapshots = await Future.wait([
      service.load(StockMarket.us), service.load(StockMarket.us),
    ]);
    expect(requests, 1);
    expect(snapshots[0], same(snapshots[1]));
    expect(() => snapshots[0].stocks.clear(), throwsUnsupportedError);
    service.close();
    service.close();
    await expectLater(service.load(StockMarket.us), throwsStateError);
  });
}
