import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/mobile_scan_checkpoint.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Explicit capacity/orchestration fixtures, never evidence of live quotes.
final _initialNow = DateTime.utc(2026, 10, 16, 14, 50);
const _journalKey = 'martin-mobile-us-rolling-v1-5.0';
const _thresholdKey = 'martin-mobile-us-rolling-v1-active-threshold';

StockItem _stock(int index) {
  final symbol = 'S${10000 + index}';
  return StockItem(market: StockMarket.us, symbol: symbol, code: symbol,
    nameZh: '容量測試普通股 $index', nameFullZh: '',
    nameEn: 'Explicit capacity fixture company $index', abbrEn: '');
}

MarketChart _daily(String symbol, DateTime now) => MarketChart(
  symbol: symbol, market: StockMarket.us, currency: 'USD',
  exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
  bars: List.generate(80, (index) => PriceBar(
    timestamp: DateTime.utc(2026, 10, 15, 13, 30)
        .subtract(Duration(days: 79 - index)),
    open: 100, high: 104, low: 96, close: 100, volume: 10000)),
  latestPrice: 100, quoteTimestamp: now, fetchedAt: now, interval: '1d',
  regularSessionStart: DateTime.utc(2026, 10, 16, 13, 30),
  regularSessionEnd: DateTime.utc(2026, 10, 16, 20),
);

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences, this.clock)
      : super(preferences: preferences, now: clock);
  final DateTime Function() clock;
  final calls = <String>[];
  final holds = <String, Completer<MarketChart>>{};
  bool provideIntraday = false;
  double entryBarLow = 102;

  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async => _daily('^GSPC', clock());

  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    calls.add(symbol);
    final held = holds[symbol];
    if (held != null) return held.future;
    await Future<void>.delayed(Duration.zero);
    return _daily(symbol, clock());
  }

  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    if (!provideIntraday) throw const FormatException('No fixture intraday evidence');
    final now = clock();
    return MarketChart(symbol: symbol, market: StockMarket.us, currency: 'USD',
      exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
      bars: [
        PriceBar(timestamp: DateTime.utc(2026, 10, 16, 13, 30),
          open: 100, high: 101, low: 96, close: 100, volume: 1000,
          interval: const Duration(minutes: 5)),
        PriceBar(timestamp: DateTime.utc(2026, 10, 16, 13, 35),
          open: 103, high: 106, low: entryBarLow, close: 105, volume: 1000,
          interval: const Duration(minutes: 5)),
      ],
      latestPrice: 105, quoteTimestamp: now, fetchedAt: now, interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 16, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 20));
  }
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences, this.clock)
      : super(preferences: preferences);
  final List<StockItem> rows;
  final DateTime Function() clock;
  int calls = 0;

  @override
  Future<UniverseSnapshot> load(StockMarket market,
      {bool forceRefresh = false}) async {
    calls++;
    return UniverseSnapshot(stocks: rows, asOf: clock(),
      source: 'Explicit capacity fixture', isComplete: false,
      warnings: const ['Fixture universe, not verified live membership.']);
  }
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Expected fixture progress did not arrive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    now = _initialNow;
  });

  test('5118-member resume writes seven full checkpoints and one unchanged threshold per page', () async {
    final rows = List.generate(5118, _stock);
    final symbols = rows.map((row) => row.symbol).toList()..sort();
    // The seeded prefix represents attempted capacity only: no invented
    // completed evaluations, recommendation or price is credited to it.
    final initial = MobileScanCheckpoint(market: StockMarket.us,
      symbols: symbols, members: rows, threshold: 5,
      day: MobileScanCheckpoint.dayFor(now, market: StockMarket.us), round: 1,
      attempted: symbols.take(5088).toSet(), evaluated: const {},
      candidates: const [], updatedAt: now, universeAsOf: now,
      universeIsComplete: false, warnings: const ['Capacity fixture only.'],
      pageStart: 5058, pageSize: 30, pageStale: true);
    final encoded = jsonEncode(initial.toJson());
    expect(encoded.length, greaterThan(256 * 1024),
      reason: 'Exercise the large-checkpoint isolate decode path.');
    await preferences.setString(_journalKey, encoded);
    final api = _Api(preferences, () => now);
    final universe = _Universe(rows, preferences, () => now);
    final writes = <String>[];
    final checkpoints = <MobileScanCheckpoint>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => now, interBatchDelay: Duration.zero,
      checkpointWriter: (key, value) async {
        writes.add(key);
        if (key == _journalKey) {
          checkpoints.add(MobileScanCheckpoint.fromJson(
            jsonDecode(value) as Map<String, dynamic>));
        }
        return preferences.setString(key, value);
      });
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final result = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(result.coverageTotalCount, 5118);
    expect(result.coverageScannedCount, 5118);
    expect(result.coverageEvaluatedCount, 30);
    expect(result.coverageRemainingCount, 0);
    expect(api.calls, symbols.skip(5088).toList());
    expect(universe.calls, 0, reason: 'Pinned complete metadata must survive loading.');
    expect(writes.where((key) => key == _journalKey), hasLength(7));
    expect(writes.where((key) => key == _thresholdKey), hasLength(1));
    expect(checkpoints.map((value) => value.attempted.length),
      [5093, 5093, 5098, 5103, 5108, 5113, 5118]);
    expect(checkpoints.map((value) => value.evaluated.length),
      [0, 5, 10, 15, 20, 25, 30]);
    expect(checkpoints.every((value) => value.symbols.length == 5118 &&
      value.members.length == 5118), isTrue);
    expect(checkpoints.last.roundCompletedAt, now);
    expect(checkpoints.last.evaluated, symbols.skip(5088).toSet());
  });

  test('stop during a later chunk keeps the verified prefix and rejects late writes', () async {
    final rows = List.generate(30, _stock);
    final api = _Api(preferences, () => now);
    final universe = _Universe(rows, preferences, () => now);
    for (final row in rows.skip(5).take(5)) {
      api.holds[row.symbol] = Completer<MarketChart>();
    }
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => now, interBatchDelay: Duration.zero);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final pending = repository.fetch(StockMarket.us, adrThreshold: 5);
    final rejected = expectLater(pending, throwsA(isA<RepositoryException>()));
    await _until(() => api.calls.length == 10);
    final before = preferences.getString(_journalKey)!;
    final durable = MobileScanCheckpoint.fromJson(jsonDecode(before) as Map<String, dynamic>);
    expect(durable.attempted, rows.take(5).map((row) => row.symbol).toSet());
    expect(durable.evaluated, durable.attempted);
    expect(durable.candidates, hasLength(5));
    repository.close();
    await rejected;
    for (final entry in api.holds.entries) {
      entry.value.complete(_daily(entry.key, now));
    }
    await Future<void>.delayed(Duration.zero);
    expect(preferences.getString(_journalKey), before);

    final nextApi = _Api(preferences, () => now);
    final resumed = DirectLiveCandidateRepository(api: nextApi, universe: universe,
      preferences: preferences, now: () => now, usPageSize: 5,
      interBatchDelay: Duration.zero);
    addTearDown(resumed.close);
    addTearDown(nextApi.close);
    final result = await resumed.fetch(StockMarket.us, adrThreshold: 5);
    expect(nextApi.calls, rows.skip(5).take(5).map((row) => row.symbol).toList());
    expect(result.coverageScannedCount, 10);
    expect(result.coverageEvaluatedCount, 10);
    expect(result.candidates, hasLength(10));
  });

  test('same-count hot refresh persists changed observed entry-bar stop evidence', () async {
    final api = _Api(preferences, () => now)..provideIntraday = true;
    final universe = _Universe([_stock(0)], preferences, () => now);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => now, interBatchDelay: Duration.zero);
    addTearDown(repository.close);
    addTearDown(api.close);
    addTearDown(universe.close);
    final first = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(first.candidates.single.priceSignalConfirmed, isTrue);
    expect(first.candidates.single.isConfirmed, isFalse);
    expect(first.candidates.single.stopSource, 'entry_bar_low');
    expect(first.candidates.single.stopPrice, 102);
    now = now.add(const Duration(minutes: 1));
    api.entryBarLow = 102.2;
    final next = await repository.fetch(StockMarket.us, adrThreshold: 5,
      refreshQuotesOnly: true);
    expect(next.coverageScannedCount, first.coverageScannedCount);
    expect(next.coverageEvaluatedCount, first.coverageEvaluatedCount);
    expect(next.candidates.single.stopPrice, 102.2);
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(
      preferences.getString(_journalKey)!) as Map<String, dynamic>);
    expect(saved.candidates.single.entryBarLow, 102.2);
    expect(saved.candidates.single.stopPrice, 102.2);
    expect(saved.candidates.single.dataTimestamp, now);
  });
}
