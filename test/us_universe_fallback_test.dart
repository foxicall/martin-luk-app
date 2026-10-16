import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String directory(bool nasdaq, {String date = '10152026'}) => nasdaq
    ? 'Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares\n'
      'NVDA|NVIDIA Corporation - Common Stock|Q|N|N|100|N|N\n'
      'File Creation Time: ${date}07:00|||||||\n'
    : 'ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol\n'
      'BRK.B|Berkshire Hathaway Class B Common Stock|N|BRK.B|N|100|N|BRK.B\n'
      'File Creation Time: ${date}07:00||||||\n';

http.Response text(String body) => http.Response(body, 200,
    headers: {'content-type': 'text/plain; charset=utf-8'});
bool isNasdaq(Uri uri) => uri.path.endsWith('/nasdaqlisted.txt');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 15, 12);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('200 HTML challenge uses a dated public mirror without fabricating quotes', () async {
    final calls = <Uri>[];
    final service = StockUniverseService(now: () => now, client: MockClient((request) async {
      calls.add(request.url);
      expect(request.headers['accept'], startsWith('text/plain'));
      if (request.url.host == 'www.nasdaqtrader.com') {
        return http.Response('<!doctype html><html>Verify you are human</html>', 200,
            headers: {'content-type': 'text/html'});
      }
      return text(directory(isNasdaq(request.url)));
    }));
    addTearDown(service.close);
    final result = await service.load(StockMarket.us, forceRefresh: true);
    expect(result.stocks.map((stock) => stock.symbol), ['BRK-B', 'NVDA']);
    expect(calls.length, 4);
    expect(result.source, contains('mirror'));
    expect(result.isComplete, isFalse);
    expect(result.isCached, isFalse);
    expect(result.asOf, DateTime.utc(2026, 10, 15));
    expect(result.retrievedAt, now);
    expect(result.warnings.join(' '), contains('HTML'));
    expect(result.stocks.every((stock) => !stock.toJson().containsKey('price')), isTrue);
  });

  test('one failed official source preserves its healthy peer and only mirrors that source', () async {
    final calls = <Uri>[];
    final service = StockUniverseService(now: () => now, client: MockClient((request) async {
      calls.add(request.url);
      if (request.url == StockUniverseService.usOtherEndpoint) {
        return http.Response('Access denied', 403);
      }
      return text(directory(isNasdaq(request.url)));
    }));
    addTearDown(service.close);
    final result = await service.load(StockMarket.us);
    expect(result.totalCount, 2);
    expect(calls.length, 3);
    expect(calls, contains(StockUniverseService.usOtherMirrorEndpoint));
    expect(calls, isNot(contains(StockUniverseService.usMirrorEndpoint)));
    expect(result.warnings.join(' '), contains('HTTP 403'));
    expect(result.isComplete, isFalse);
  });

  test('stale mirror is refused and the successful official source remains available', () async {
    final service = StockUniverseService(now: () => now, client: MockClient((request) async {
      if (request.url == StockUniverseService.usOtherEndpoint) return http.Response('blocked', 429);
      return text(directory(isNasdaq(request.url),
          date: request.url.host == 'raw.githubusercontent.com' ? '10012026' : '10152026'));
    }));
    addTearDown(service.close);
    final result = await service.load(StockMarket.us);
    expect(result.stocks.single.symbol, 'NVDA');
    expect(result.warnings.join(' '), contains('超過 7 天'));
    expect(result.isComplete, isFalse);
  });

  test('official plus mirror share one deadline and a late original cannot overwrite a result', () async {
    final never = Completer<http.Response>();
    final service = StockUniverseService(now: () => now,
        requestTimeout: const Duration(milliseconds: 160),
        client: MockClient((request) async {
          if (request.url == StockUniverseService.usOtherEndpoint) return never.future;
          return text(directory(isNasdaq(request.url)));
        }));
    addTearDown(service.close);
    final watch = Stopwatch()..start();
    final result = await service.load(StockMarket.us, forceRefresh: true);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(result.totalCount, 2);
    expect(result.source, contains('mirror'));
    never.complete(text(directory(false, date: '10012026')));
    await Future<void>.delayed(Duration.zero);
    expect((await service.load(StockMarket.us)).totalCount, 2);
  });

  test('valid Latin1 names are decoded rather than dropping an exchange', () async {
    final body = directory(true).replaceAll('NVIDIA Corporation', 'Caf\u00e9 Corporation');
    final service = StockUniverseService(useUsMirrorFallback: false, now: () => now,
        client: MockClient((request) async => request.url == StockUniverseService.usEndpoint
            ? http.Response.bytes(latin1.encode(body), 200,
                headers: {'content-type': 'text/plain; charset=iso-8859-1'})
            : text(directory(false))));
    addTearDown(service.close);
    final result = await service.load(StockMarket.us);
    expect(result.totalCount, 2);
    expect(result.stocks.firstWhere((stock) => stock.symbol == 'NVDA').nameEn, contains('Caf\u00e9'));
  });

  test('new directory cache cannot reuse an old v2 error snapshot', () async {
    SharedPreferences.setMockInitialValues({
      'martin_luk.universe.v2.all_common.us': '{"version":2}',
    });
    var calls = 0;
    final service = StockUniverseService(useUsMirrorFallback: false, now: () => now,
        client: MockClient((request) async {
          calls++;
          return text(directory(isNasdaq(request.url)));
        }));
    addTearDown(service.close);
    expect((await service.load(StockMarket.us)).isCached, isFalse);
    expect(calls, 2);
  });

  test('closed service cannot publish a partial peer or overwrite the shared cache', () async {
    final preferences = await SharedPreferences.getInstance();
    final late = Completer<http.Response>();
    final bothStarted = Completer<void>();
    var calls = 0;
    final service = StockUniverseService(useUsMirrorFallback: false,
        preferences: preferences, now: () => now,
        client: MockClient((request) async {
          if (++calls == 2) bothStarted.complete();
          if (request.url == StockUniverseService.usOtherEndpoint) return late.future;
          return text(directory(true));
        }));
    final pending = service.load(StockMarket.us, forceRefresh: true);
    final rejected = expectLater(pending, throwsStateError);
    await bothStarted.future;
    service.close();
    await rejected;
    late.complete(text(directory(false)));
    await Future<void>.delayed(Duration.zero);
    expect(preferences.getString(StockUniverseService.cacheKey(StockMarket.us)), isNull);
    expect(calls, 2);
  });
}
