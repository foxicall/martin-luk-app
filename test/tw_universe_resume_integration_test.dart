import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/mobile_scan_checkpoint.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Cross-layer regression fixtures, not live market evidence. The real
// directory parser/cache and rolling repository run together; only exchange
// HTTP bodies and quotes are explicitly injected test data.
final _initialNow = DateTime.utc(2026, 10, 16, 2);

http.Response _exchangeRows({required bool otc}) => http.Response(
      jsonEncode(List.generate(otc ? 894 : 1085, (index) {
        final code = '${(otc ? 3000 : 1000) + index}';
        return <String, Object>{
          '公司代號': code,
          '公司簡稱': '測試${otc ? '上櫃' : '上市'}$code',
          '公司名稱': '明確測試資料 $code 股份有限公司',
          '產業別': '24',
        };
      })),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

MarketChart _daily(String symbol, DateTime now) => MarketChart(
      symbol: symbol,
      market: StockMarket.tw,
      currency: 'TWD',
      exchangeTimezoneName: 'Asia/Taipei',
      gmtoffset: 28800,
      bars: List.generate(
        80,
        (index) => PriceBar(
          timestamp: DateTime.utc(2026, 10, 15, 1)
              .subtract(Duration(days: 79 - index)),
          open: 100,
          high: 101,
          low: 99,
          close: 100,
          volume: 10000,
        ),
      ),
      latestPrice: 100,
      quoteTimestamp: now,
      fetchedAt: now,
      interval: '1d',
      regularSessionStart: DateTime.utc(2026, 10, 16, 1),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 5, 30),
    );

class _QuoteFixture extends MarketDataApi {
  _QuoteFixture(SharedPreferences preferences, this.clock)
      : super(preferences: preferences, now: clock);

  final DateTime Function() clock;
  final dailySymbols = <String>[];
  int active = 0;
  int maximumActive = 0;

  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async {
    return _daily('^TWII', clock());
  }

  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    dailySymbols.add(symbol);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await Future<void>.delayed(Duration.zero);
      return _daily(symbol, clock());
    } finally {
      active--;
    }
  }

  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    throw StateError('Low-ADR fixture must not request intraday prices.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('TWSE failure preserves all 1979 members and resumes pages 30, 60, 90',
      () async {
    final preferences = await SharedPreferences.getInstance();
    var now = _initialNow;
    var listedBlocked = false;
    final directoryRequests = <Uri>[];
    final client = MockClient((request) async {
      directoryRequests.add(request.url);
      if (request.url == StockUniverseService.twEndpoint) {
        if (listedBlocked) return http.Response('Explicit fixture HTTP 403', 403);
        return _exchangeRows(otc: false);
      }
      if (request.url == StockUniverseService.twOtcEndpoint) {
        return _exchangeRows(otc: true);
      }
      throw StateError('Unexpected fixture URL: ${request.url}');
    });
    addTearDown(client.close);
    final universe = StockUniverseService(
      client: client,
      preferences: preferences,
      now: () => now,
    );
    addTearDown(universe.close);
    final quotes = _QuoteFixture(preferences, () => now);
    addTearDown(quotes.close);

    DirectLiveCandidateRepository scanner() {
      final repository = DirectLiveCandidateRepository(
        api: quotes,
        universe: universe,
        preferences: preferences,
        now: () => now,
        interBatchDelay: const Duration(milliseconds: 1),
      );
      addTearDown(repository.close);
      return repository;
    }

    final firstScanner = scanner();
    final first = await firstScanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(first.universeCount, 1979);
    expect(first.coverageTotalCount, 1979);
    expect(first.coverageScannedCount, 30);
    expect(first.coverageEvaluatedCount, 30);
    expect(first.coverageRemainingCount, 1949);
    expect(first.scanPageStart, 0);
    expect(first.universeIsComplete, isTrue);
    expect(first.universeAsOf, _initialNow);
    expect(quotes.dailySymbols,
        List.generate(30, (index) => '${1000 + index}.TW'));
    expect(directoryRequests.length, 2);

    // Exercise the real metadata service separately while the round is
    // unfinished. A successful 894-stock TPEx reply cannot erase TWSE's 1085
    // last-known identities or claim that the failed source was just renewed.
    now = now.add(const Duration(minutes: 1));
    listedBlocked = true;
    final mixed = await universe.load(StockMarket.tw, forceRefresh: true);
    expect(mixed.totalCount, 1979);
    expect(mixed.stocks.where((row) => row.symbol.endsWith('.TW')).length, 1085);
    expect(mixed.stocks.where((row) => row.symbol.endsWith('.TWO')).length, 894);
    expect(mixed.isComplete, isFalse);
    expect(mixed.isCached, isTrue);
    expect(mixed.asOf, _initialNow);
    expect(mixed.warnings.join(' '), contains('HTTP 403'));
    expect(mixed.warnings.join(' '), contains('沿用最後成功取得'));
    expect(directoryRequests.length, 4);

    final storedDirectory = jsonDecode(preferences.getString(
        StockUniverseService.cacheKey(StockMarket.tw))!) as Map<String, dynamic>;
    final exchangeSources = (storedDirectory['tw_exchange_sources']
        as Map<String, dynamic>)['sources'] as Map<String, dynamic>;
    final listedSource = exchangeSources['TWSE'] as Map<String, dynamic>;
    final otcSource = exchangeSources['TPEx'] as Map<String, dynamic>;
    expect(listedSource['retrieved_at'], _initialNow.toIso8601String());
    expect(listedSource['as_of'], _initialNow.toIso8601String());
    expect(otcSource['retrieved_at'], now.toIso8601String());

    final second = await firstScanner.fetch(StockMarket.tw,
        adrThreshold: 3.5, forceRefresh: true);
    expect(second.coverageTotalCount, 1979);
    expect(second.coverageScannedCount, 60);
    expect(second.coverageEvaluatedCount, 60);
    expect(second.coverageRemainingCount, 1919);
    expect(second.scanPageStart, 30);
    expect(second.coverageRound, 1);
    expect(second.universeFingerprint, first.universeFingerprint);
    expect(second.universeAsOf, _initialNow);
    expect(quotes.dailySymbols.skip(30),
        List.generate(30, (index) => '${1030 + index}.TW'));
    expect(directoryRequests.length, 4,
        reason: 'A forced price refresh reuses the active round identity list.');

    // Close/recreate only the scanner. Names, suffixes and the next cursor
    // must survive via SharedPreferences, not the retired repository's memory.
    firstScanner.close();
    now = now.add(const Duration(minutes: 1));
    final resumed = await scanner().fetch(StockMarket.tw,
        adrThreshold: 3.5, forceRefresh: true);
    expect(resumed.coverageTotalCount, 1979);
    expect(resumed.coverageScannedCount, 90);
    expect(resumed.coverageEvaluatedCount, 90);
    expect(resumed.coverageRemainingCount, 1889);
    expect(resumed.scanPageStart, 60);
    expect(resumed.coverageRound, 1);
    expect(resumed.universeFingerprint, first.universeFingerprint);
    expect(resumed.universeAsOf, _initialNow);
    expect(quotes.dailySymbols.skip(60),
        List.generate(30, (index) => '${1060 + index}.TW'));
    expect(quotes.dailySymbols.length, 90);
    expect(quotes.dailySymbols.toSet().length, 90,
        reason: 'No directory failure or repository restart may replay page one.');
    expect(quotes.maximumActive, lessThanOrEqualTo(5));
    expect(directoryRequests.length, 4);
    expect(resumed.candidates, isEmpty,
        reason: 'Verified low-ADR fixtures are valid zero-recommendation pages.');

    final journal = MobileScanCheckpoint.fromJson(jsonDecode(preferences
        .getString('martin-mobile-tw-rolling-v1-3.5')!) as Map<String, dynamic>);
    expect(journal.symbols.length, 1979);
    expect(journal.members.length, 1979);
    expect(journal.attempted.length, 90);
    expect(journal.evaluated.length, 90);
    expect(journal.round, 1);
    expect(journal.members.first.nameZh, '測試上市1000');
    expect(journal.members.last.symbol, '3893.TWO');
  });
}
