import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Explicit fixtures exercise scanner control flow, not live market evidence.
final _now = DateTime.utc(2026, 10, 14, 14, 50);

StockItem _stock(String symbol) => StockItem(market: StockMarket.us,
  symbol: symbol, code: symbol, nameZh: '', nameFullZh: '',
  nameEn: symbol, abbrEn: '');

MarketChart _daily(String symbol) => MarketChart(symbol: symbol,
  market: StockMarket.us, currency: 'USD',
  exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
  bars: List.generate(80, (index) => PriceBar(
    timestamp: DateTime.utc(2026, 10, 13, 13, 30)
        .subtract(Duration(days: 79 - index)),
    open: 100, high: 104, low: 96, close: 100, volume: 10000)),
  latestPrice: 100, quoteTimestamp: _now, fetchedAt: _now, interval: '1d',
  regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
  regularSessionEnd: DateTime.utc(2026, 10, 14, 20));

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences)
      : super(preferences: preferences, now: () => _now);
  final calls = <String>[];
  final failures = <String>{};
  final dailyHolds = <String, Completer<MarketChart>>{};
  final intradayHolds = <String, Completer<MarketChart>>{};
  Completer<MarketChart>? hold;
  int active = 0, maximumActive = 0;

  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async => _daily('^GSPC');

  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    calls.add(symbol);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      final pending = dailyHolds[symbol] ?? hold;
      if (pending != null) return await pending.future;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failures.contains(symbol)) throw StateError('Fixture HTTP failure');
      return _daily(symbol);
    } finally {
      active--;
    }
  }

  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    final pending = intradayHolds[symbol];
    if (pending != null) return pending.future;
    throw const FormatException('Explicit fixture has no intraday evidence');
  }
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences)
      : super(preferences: preferences);
  final List<StockItem> rows;

  @override
  Future<UniverseSnapshot> load(StockMarket market,
      {bool forceRefresh = false}) async => UniverseSnapshot(stocks: rows,
    asOf: _now, source: 'Explicit member fixture', isComplete: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test('only thirty real members are visited with at most five active stocks', () async {
    final api = _Api(preferences);
    final universe = _Universe([
      ...List.generate(57, (index) => _stock('TEST$index')),
      _stock('NVDA'), _stock('AAPL'), _stock('TSLA'),
    ], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 100);
    expect(api.calls.length, 30);
    expect(api.calls.take(3), ['NVDA', 'AAPL', 'TSLA']);
    expect(api.maximumActive, lessThanOrEqualTo(5));
    expect(snapshot.universeCount, 60);
    expect(snapshot.scanPoolSize, 30);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 0);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.stale, isFalse);
    expect(snapshot.scanCompletedAt, _now);
    expect(snapshot.fetchedAt, _now,
        reason: 'A verified zero-ADR result retains its real observation time.');
  });

  test('scan budgets remain below the controller ten-second deadline', () {
    final api = _Api(preferences);
    final universe = _Universe([_stock('NVDA')], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences,
      scanBudget: const Duration(minutes: 5),
      quoteRefreshBudget: const Duration(minutes: 5));
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    expect(repository.scanBudget, const Duration(seconds: 9));
    expect(repository.quoteRefreshBudget, const Duration(seconds: 9));
  });

  test('a completed stock is published while its chunk sibling is hanging', () async {
    final gate = Completer<MarketChart>();
    final api = _Api(preferences)..dailyHolds['AAPL'] = gate;
    final universe = _Universe([_stock('NVDA'), _stock('AAPL')], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now,
      scanBudget: const Duration(milliseconds: 200));
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final observed = Completer<CandidateSnapshot>();
    final running = repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: (value) {
        final partial = value.partialSnapshot;
        if (!observed.isCompleted && !value.finished && partial != null &&
            partial.evaluatedCount == 1) observed.complete(partial);
      });
    final early = await observed.future.timeout(const Duration(seconds: 1));
    expect(early.candidates.map((row) => row.symbol), ['NVDA']);
    expect(early.evaluatedCount, 1);
    expect(early.scanPoolSize, 2);
    expect(early.adrMatchCount, 1);
    expect(early.missingSymbols, ['AAPL']);
    expect(early.scanCompletedAt, isNull);
    expect(early.stale, isFalse);
    expect(early.source, contains('評估未完成'));
    final snapshot = await running.timeout(const Duration(seconds: 1));
    expect(snapshot.scanCompletedAt, isNull);
    expect(snapshot.evaluatedCount, 1);
    final persisted = jsonDecode(
        preferences.getString('martin-live-scan-v1-us-5.0')!) as Map;
    expect(persisted['scan_complete'], isFalse);
    expect(persisted['scan_completed_at'], isNull);
    // An incomplete scan may be viewed offline, but its fresh quote timestamp
    // cannot qualify it for the fifteen-minute completed-scan cooldown.
    api.dailyHolds.clear();
    final callsBefore = api.calls.length;
    final retried = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(api.calls.length - callsBefore, 2);
    expect(retried.evaluatedCount, 2);
    expect(retried.scanCompletedAt, _now);
    gate.completeError(StateError('Late sibling error after scan deadline'));
    await Future<void>.delayed(Duration.zero);
  });

  test('verified daily history survives an intraday timeout without inventing a stop', () async {
    final gate = Completer<MarketChart>();
    final api = _Api(preferences)..intradayHolds['NVDA'] = gate;
    final universe = _Universe([_stock('NVDA')], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now,
      scanBudget: const Duration(milliseconds: 150));
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final progress = <MarketScanProgress>[];
    final snapshot = await repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: progress.add)
        .timeout(const Duration(seconds: 1));
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.adrMatchCount, 1);
    expect(snapshot.scanCompletedAt, isNull);
    expect(snapshot.candidates.single.isConfirmed, isFalse);
    expect(snapshot.candidates.single.stopPrice, isNull);
    expect(snapshot.warnings.join('\n'), contains('盤中資料未於整批期限內完成'));
    expect(progress.any((row) => row.partialSnapshot != null &&
        !row.finished && row.evaluatedCount == 1), isTrue);
    final published = progress.length;
    gate.completeError(StateError('Late intraday error after scan deadline'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, published);
  });

  test('a failed stock and a throwing progress observer cannot abort the next batch', () async {
    final api = _Api(preferences)..failures.add('TEST0');
    final universe = _Universe(
        List.generate(10, (index) => _stock('TEST$index')), preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final progress = <MarketScanProgress>[];
    final snapshot = await repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, onProgress: (value) {
        progress.add(value);
        if (!value.finished && value.completedCount == 5) {
          throw StateError('Fixture observer failure');
        }
      });
    expect(api.calls.length, 10);
    expect(snapshot.evaluatedCount, 9);
    expect(snapshot.adrMatchCount, 9);
    expect(snapshot.missingSymbols, ['TEST0']);
    expect(progress.any((value) => value.completedCount == 5), isTrue);
    expect(progress.last.completedCount, 10);
    expect(progress.last.failedCount, 1);
    expect(progress.last.finished, isTrue);
    expect(snapshot.candidates.every((row) => !row.isConfirmed), isTrue);
  });

  test('all failed quotes finish with an error instead of a fresh empty snapshot', () async {
    final api = _Api(preferences)..failures.addAll(['TEST0', 'TEST1']);
    final universe = _Universe([_stock('TEST0'), _stock('TEST1')], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final progress = <MarketScanProgress>[];
    await expectLater(repository.fetchWithProgress(StockMarket.us,
        adrThreshold: 5, onProgress: progress.add),
        throwsA(isA<RepositoryException>()));
    expect(progress.last.finished, isTrue);
    expect(progress.last.failedCount, 2);
    expect(progress.last.evaluatedCount, 0);
  });

  test('closing a hung batch finishes and cannot publish late progress', () async {
    final api = _Api(preferences)..hold = Completer<MarketChart>();
    final universe = _Universe([_stock('TEST0')], preferences);
    final repository = DirectLiveCandidateRepository(api: api,
      universe: universe, preferences: preferences, now: () => _now);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final progress = <MarketScanProgress>[];
    final running = repository.fetchWithProgress(StockMarket.us,
        adrThreshold: 5, onProgress: progress.add);
    final failed = expectLater(running, throwsA(isA<RepositoryException>()));
    final elapsed = Stopwatch()..start();
    while (api.calls.isEmpty && elapsed.elapsed < const Duration(seconds: 1)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(api.calls, ['TEST0']);
    repository.close();
    final published = progress.length;
    await failed.timeout(const Duration(seconds: 1));
    api.hold!.complete(_daily('TEST0'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, published);
  });
}
