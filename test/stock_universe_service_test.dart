import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';

const nasdaqHeader = 'Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares';
const otherHeader = 'ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol';
String nasdaq(List<String> rows) =>
    '$nasdaqHeader\n${rows.join('\n')}\nFile Creation Time: 1015202608:00|||||||\n';
String other(List<String> rows) =>
    '$otherHeader\n${rows.join('\n')}\nFile Creation Time: 1015202608:00|||||||\n';
String get usBody => nasdaq([
      'NVDA|NVIDIA Corporation - Common Stock|Q|N|N|100|N|N',
      'AAPL|Apple Inc. - Common Stock|Q|N|N|100|N|N',
    ]);
String get otherBody => other([
      'BRK.B|Berkshire Hathaway Inc. Class B Common Stock|N|BRK.B|N|100|N|BRK.B',
      'UAMY|United States Antimony Corporation Common Stock|A|UAMY|N|100|N|UAMY',
    ]);
http.Response text(String body) => http.Response(body, 200,
    headers: {'content-type': 'text/plain; charset=utf-8'});
http.Response twRows(List<Map<String, Object>> rows) => http.Response(
    jsonEncode(rows), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 15, 1);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('both US directories produce the three exchanges, Yahoo classes and real names', () async {
    final urls = <Uri>[];
    final service = StockUniverseService(useUsMirrorFallback: false, 
      client: MockClient((request) async {
        urls.add(request.url);
        return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
      }), now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(urls.toSet(), {StockUniverseService.usEndpoint, StockUniverseService.usOtherEndpoint});
    expect(result.stocks.map((stock) => stock.symbol), ['AAPL', 'BRK-B', 'NVDA', 'UAMY']);
    expect(result.stocks.first.nameEn, 'Apple Inc. - Common Stock');
    expect(result.stocks.firstWhere((stock) => stock.symbol == 'NVDA').nameZh, '輝達');
    expect(result.isComplete, isFalse, reason: 'Tiny real replies are still partial.');
    expect(result.source, contains('Nasdaq / NYSE / NYSE American'));
    expect(result.warnings.join(' '), contains('覆蓋不足'));
    expect(result.warnings.join(' '), contains('CFI'));
    service.close();
  });

  test('US rejects ETF, test, preferred, ADR, units, unknown class and out-of-scope exchanges', () async {
    final service = StockUniverseService(useUsMirrorFallback: false, 
      client: MockClient((request) async => text(request.url == StockUniverseService.usEndpoint
          ? nasdaq([
              'NVDA|NVIDIA Corporation - Common Stock|Q|N|N|100|N|N',
              'ETF|Some ETF - Common Stock|Q|N|N|100|Y|N',
              'TEST|Test Common Stock|Q|Y|N|100|N|N',
              'PREF|Example Preferred Stock|Q|N|N|100|N|N',
              'ADR|Example American Depositary Shares|Q|N|N|100|N|N',
              'UNIT|Example Units each including common stock|Q|N|N|100|N|N',
              'UNKNOWN|Example Security|Q|N|N|100|N|N',
              'FUNDS|Income Funds Inc. Common Stock|Q|N|N|100|N|N',
              'BEN|Income Trust Common Shares of Beneficial Interest|Q|N|N|100|N|N',
              'INV|Example Investment Trust Common Stock|Q|N|N|100|N|N',
              'REIT|Example Real Estate Investment Trust Common Stock|Q|N|N|100|N|N',
              'TRST|Corporate Trust Inc. Common Stock|Q|N|N|100|N|N',
            ])
          : other([
              'NYSE|NYSE Example Common Stock|N|NYSE|N|100|N|NYSE',
              'AMEX|American Example Ordinary Shares|A|AMEX|N|100|N|AMEX',
              'BATS|BATS Example Common Stock|Z|BATS|N|100|N|BATS',
              'ARCA|Arca Example Common Stock|P|ARCA|N|100|N|ARCA',
            ]))), now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(result.stocks.map((stock) => stock.symbol), ['AMEX', 'NVDA', 'NYSE', 'REIT', 'TRST']);
    expect(result.warnings.join(' '), contains('未能確認'));
    service.close();
  });

  test('TWSE and TPEx issuer feeds add TW and TWO and exclude funds/TDR/preferred', () async {
    final service = StockUniverseService(useUsMirrorFallback: false, 
      client: MockClient((request) async => request.url == StockUniverseService.twEndpoint
          ? twRows([
              {'公司代號': '2330', '公司簡稱': '台積電', '公司名稱': '台灣積體電路製造股份有限公司', '產業別': '24'},
              {'公司代號': '0050', '公司簡稱': '元大台灣50'},
              {'公司代號': '9110', '公司簡稱': '越南控股', '產業別': '91'},
              {'公司代號': '9103', '公司簡稱': '美德醫療', '產業別': '22'},
              {'公司代號': '1978', '公司簡稱': '創新板普通股', '產業別': '24'},
              {'公司代號': '2330A', '公司簡稱': '特別股'},
            ])
          : twRows([
              {'SecuritiesCompanyCode': '6488', 'CompanyAbbreviation': '環球晶', 'CompanyName': '環球晶圓股份有限公司', 'Symbol': 'GlobalWafers', 'SecuritiesIndustryCode': '24'},
              {'公司代號': '8358', '公司簡稱': '金居', '公司名稱': '金居開發股份有限公司', '產業別': '24'},
              {'SecuritiesCompanyCode': '9105', 'CompanyName': '存託憑證', 'Symbol': 'TDR', 'SecuritiesIndustryCode': '22'},
              {'公司代號': '9999', '公司簡稱': 'Example', '證券種類': '特別股'},
            ])), now: () => now,
    );
    final result = await service.load(StockMarket.tw);
    expect(result.stocks.map((stock) => stock.symbol), ['1978.TW', '2330.TW', '6488.TWO', '8358.TWO']);
    expect(result.stocks.firstWhere((stock) => stock.symbol == '2330.TW').abbrEn, 'TSMC');
    expect(result.stocks.firstWhere((stock) => stock.symbol == '6488.TWO').nameZh, '環球晶');
    expect(result.stocks.firstWhere((stock) => stock.symbol == '6488.TWO').abbrEn, 'GlobalWafers');
    expect(result.stocks.last.nameZh, '金居');
    service.close();
  });

  test('one broken exchange does not discard the successful exchange', () async {
    final service = StockUniverseService(useUsMirrorFallback: false, 
      client: MockClient((request) async => request.url == StockUniverseService.usEndpoint
          ? text(usBody) : http.Response('blocked', 403)), now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(result.stocks.map((stock) => stock.symbol), ['AAPL', 'NVDA']);
    expect(result.isCached, isFalse);
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('HTTP 403'));
    expect(result.warnings.join(' '), contains('1/2'));
    service.close();
  });

  test('a truncated directory is rejected rather than considered a complete list', () async {
    final service = StockUniverseService(useUsMirrorFallback: false, 
      client: MockClient((request) async => text(request.url == StockUniverseService.usEndpoint
          ? '$nasdaqHeader\nNVDA|NVIDIA Common Stock|Q|N|N|100|N|N'
          : otherBody)), now: () => now,
    );
    final result = await service.load(StockMarket.us);
    expect(result.stocks.map((stock) => stock.symbol), ['BRK-B', 'UAMY']);
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('資料格式無效'));
    service.close();
  });

  test('fresh v3 directory cache is reused and force refresh requests both feeds', () async {
    final preferences = await SharedPreferences.getInstance();
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
    });
    final first = StockUniverseService(useUsMirrorFallback: false, client: client, preferences: preferences, now: () => now);
    await first.load(StockMarket.us);
    first.close();
    final stored = jsonDecode(preferences.getString(StockUniverseService.cacheKey(StockMarket.us))!) as Map<String, dynamic>;
    expect(stored['version'], 3);
    expect(stored['scope'], 'all_common');
    final second = StockUniverseService(useUsMirrorFallback: false, client: client, preferences: preferences,
        now: () => now.add(const Duration(minutes: 4)));
    expect((await second.load(StockMarket.us)).isCached, isTrue);
    expect(requests, 2);
    expect((await second.load(StockMarket.us, forceRefresh: true)).isCached, isFalse);
    expect(requests, 4);
    second.close();
  });

  test('only both substantial exchange lists satisfy full-directory coverage', () async {
    final service = StockUniverseService(useUsMirrorFallback: false, client: MockClient((request) async => text(
        request.url == StockUniverseService.usEndpoint
            ? nasdaq(List.generate(2498, (index) =>
                'N$index|Issuer $index Common Stock|Q|N|N|100|N|N'))
            : otherBody)), now: () => now);
    final result = await service.load(StockMarket.us);
    expect(result.totalCount, 2500);
    expect(result.isComplete, isTrue);
    expect(result.warnings.join(' '), contains('非百分之百分類認證'));
    service.close();
  });

  test('partial provider caches retry in five minutes rather than waiting a day', () async {
    final preferences = await SharedPreferences.getInstance();
    var requests = 0;
    http.Client client() => MockClient((request) async {
      requests++;
      return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
    });
    final first = StockUniverseService(useUsMirrorFallback: false, client: client(), preferences: preferences, now: () => now);
    await first.load(StockMarket.us);
    first.close();
    final next = StockUniverseService(useUsMirrorFallback: false, client: client(), preferences: preferences,
        now: () => now.add(const Duration(minutes: 6)));
    expect((await next.load(StockMarket.us)).isCached, isFalse);
    expect(requests, 4);
    next.close();
  });

  test('old S&P-only cache key cannot masquerade as the expanded market', () async {
    SharedPreferences.setMockInitialValues({'martin_luk.universe.v1.us': '{"version":1}'});
    var requests = 0;
    final service = StockUniverseService(useUsMirrorFallback: false, client: MockClient((request) async {
      requests++;
      return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
    }), now: () => now);
    expect((await service.load(StockMarket.us)).isCached, isFalse);
    expect(requests, 2);
    service.close();
  });

  test('dated genuine cache lasts at most 30 days and does not invent market prices', () async {
    final preferences = await SharedPreferences.getInstance();
    final service = StockUniverseService(useUsMirrorFallback: false, preferences: preferences,
        client: MockClient((request) async => text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody)),
        now: () => now);
    await service.load(StockMarket.us);
    service.close();
    final failing = StockUniverseService(useUsMirrorFallback: false, preferences: preferences,
        client: MockClient((_) async => http.Response('unavailable', 503)),
        now: () => now.add(const Duration(days: 5)));
    final stale = await failing.load(StockMarket.us);
    expect(stale.isCached, isTrue);
    expect(stale.asOf, DateTime.utc(now.year, now.month, now.day));
    expect(stale.stocks.first.toJson().containsKey('price'), isFalse);
    expect(stale.warnings.join(' '), contains('成分可能已變更'));
    failing.close();
    final expired = StockUniverseService(useUsMirrorFallback: false, preferences: preferences,
        client: MockClient((_) async => http.Response('unavailable', 503)),
        now: () => now.add(const Duration(days: 31)));
    final fallback = await expired.load(StockMarket.us);
    expect(fallback.source, contains('bundled'));
    expect(fallback.isComplete, isFalse);
    expect(fallback.warnings.join(' '), contains('超過 30 天'));
    expired.close();
  });

  test('parallel callers share two source requests and close is idempotent', () async {
    var requests = 0;
    final service = StockUniverseService(useUsMirrorFallback: false, client: MockClient((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
    }), now: () => now);
    final results = await Future.wait([service.load(StockMarket.us), service.load(StockMarket.us)]);
    expect(requests, 2);
    expect(results[0], same(results[1]));
    expect(() => results[0].stocks.clear(), throwsUnsupportedError);
    service.close();
    service.close();
    await expectLater(service.load(StockMarket.us), throwsStateError);
  });

  test('hung exchange reaches its deadline and never blocks a successful peer or retry', () async {
    final late = Completer<http.Response>();
    var first = true;
    final service = StockUniverseService(useUsMirrorFallback: false, requestTimeout: const Duration(milliseconds: 20),
        client: MockClient((request) async {
          if (request.url == StockUniverseService.usOtherEndpoint && first) return late.future;
          return text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody);
        }), now: () => now);
    final stopwatch = Stopwatch()..start();
    final partial = await service.load(StockMarket.us, forceRefresh: true);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(partial.stocks.map((stock) => stock.symbol), ['AAPL', 'NVDA']);
    expect(partial.warnings.join(' '), contains('連線逾時'));
    first = false;
    final retry = await service.load(StockMarket.us, forceRefresh: true);
    expect(retry.totalCount, 4);
    late.complete(text(otherBody));
    await Future<void>.delayed(Duration.zero);
    expect((await service.load(StockMarket.us)).totalCount, 4);
    service.close();
  });

  test('a missing preferences plugin does not stop live exchange retrieval', () async {
    final never = Completer<SharedPreferences>();
    final service = StockUniverseService(useUsMirrorFallback: false, 
        preferencesLoader: () => never.future,
        storageTimeout: const Duration(milliseconds: 10), now: () => now,
        client: MockClient((request) async => text(request.url == StockUniverseService.usEndpoint ? usBody : otherBody)));
    final result = await service.load(StockMarket.us, forceRefresh: true);
    expect(result.totalCount, 4);
    expect(result.warnings.join(' '), contains('本機儲存不可用'));
    service.close();
  });
}
