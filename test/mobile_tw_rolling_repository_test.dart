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
import 'package:martin_luk_app/services/mobile_scan_checkpoint.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Explicit fixture prices validate orchestration. They are NOT evidence of
// live provider success and are never installed in a production repository.
final _initialNow = DateTime.utc(2026, 10, 16, 2);

StockItem _stock(int index) {
  final code = '${1000 + index}';
  return StockItem(market: StockMarket.tw,
    symbol: '$code.${index.isEven ? 'TW' : 'TWO'}', code: code,
    nameZh: '測試股票 $index', nameFullZh: '', nameEn: 'Fixture $index', abbrEn: '');
}

MarketChart _daily(String symbol, DateTime now, {bool lowAdr = false}) =>
    MarketChart(symbol: symbol, market: StockMarket.tw, currency: 'TWD',
      exchangeTimezoneName: 'Asia/Taipei', gmtoffset: 28800,
      bars: List.generate(80, (index) => PriceBar(
        timestamp: DateTime.utc(2026, 10, 15, 1)
            .subtract(Duration(days: 79 - index)),
        open: 100, high: lowAdr ? 101 : 104, low: lowAdr ? 99 : 96,
        close: 100, volume: 10000)),
      latestPrice: 100, quoteTimestamp: now, fetchedAt: now, interval: '1d',
      regularSessionStart: DateTime.utc(2026, 10, 16, 1),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 5, 30));

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences, this.clock)
      : super(preferences: preferences, now: clock);
  final DateTime Function() clock;
  final calls = <String>[];
  final failures = <String>{};
  final holds = <String, Completer<MarketChart>>{};
  bool lowAdr = false, benchmarkFails = false, provideIntraday = false;
  int active = 0, maximumActive = 0;

  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async {
    if (benchmarkFails) throw StateError('Explicit benchmark failure');
    return _daily('^TWII', clock());
  }

  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    calls.add(symbol);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      final hold = holds[symbol];
      if (hold != null) return await hold.future;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failures.contains(symbol)) throw StateError('Explicit single-symbol failure');
      return _daily(symbol, clock(), lowAdr: lowAdr);
    } finally { active--; }
  }

  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    if (!provideIntraday) {
      throw const FormatException('Explicit fixture has no intraday evidence');
    }
    return MarketChart(symbol: symbol, market: StockMarket.tw, currency: 'TWD',
      exchangeTimezoneName: 'Asia/Taipei', gmtoffset: 28800,
      bars: [PriceBar(timestamp: DateTime.utc(2026, 10, 16, 1),
        open: 100, high: 101, low: 99, close: 100, volume: 1000,
        interval: const Duration(minutes: 5))],
      latestPrice: 100, quoteTimestamp: clock(), fetchedAt: clock(), interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 16, 1),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 5, 30));
  }
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences, this.clock)
      : super(preferences: preferences);
  List<StockItem> rows;
  final DateTime Function() clock;
  bool fails = false;

  @override
  Future<UniverseSnapshot> load(StockMarket market,
      {bool forceRefresh = false}) async {
    if (fails) throw StateError('Explicit directory failure');
    return UniverseSnapshot(stocks: rows, asOf: clock(),
      source: 'Explicit TWSE/TPEx member fixture', isComplete: false,
      warnings: const ['Fixture membership is not a verified live universe.']);
  }
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw TimeoutException('Fixture progress did not arrive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late DateTime now;
  late _Api api;
  late _Universe universe;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    now = _initialNow;
    api = _Api(preferences, () => now);
    universe = _Universe(List.generate(70, _stock).reversed.toList(),
        preferences, () => now);
    addTearDown(api.close);
    addTearDown(universe.close);
  });

  DirectLiveCandidateRepository repository({int pageSize = 30, int batchSize = 5,
      Duration budget = const Duration(seconds: 9)}) {
    final value = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => now, twPageSize: pageSize,
      batchSize: batchSize, scanBudget: budget,
      interBatchDelay: const Duration(milliseconds: 1));
    addTearDown(value.close);
    return value;
  }

  test('seventy listed and OTC members progress 30, 60, 70 without a core ceiling', () async {
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    final firstPrices = {for (final row in first.candidates) row.symbol: row.dataTimestamp};
    now = now.add(const Duration(minutes: 1));
    // quote-only timer calls MUST advance unfinished full-universe work.
    final second = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
        refreshQuotesOnly: true);
    now = now.add(const Duration(minutes: 1));
    final third = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
        refreshQuotesOnly: true);
    expect([first.coverageScannedCount, second.coverageScannedCount,
      third.coverageScannedCount], [30, 60, 70]);
    expect([first.coverageRemainingCount, second.coverageRemainingCount,
      third.coverageRemainingCount], [40, 10, 0]);
    expect([first.scanPoolSize, second.scanPoolSize, third.scanPoolSize], [30, 30, 10]);
    expect([first.evaluatedCount, second.evaluatedCount, third.evaluatedCount], [30, 30, 10]);
    expect([first.candidates.length, second.candidates.length, third.candidates.length], [30, 60, 70]);
    expect(third.coverageEvaluatedCount, 70);
    expect(third.coverageTotalCount, 70);
    expect(third.candidatesAreCumulative, isTrue);
    expect(third.candidates.last.dataTimestamp, now);
    expect(third.candidates.first.dataTimestamp, _initialNow);
    expect(third.coverageRound, 1);
    final sorted = universe.rows.map((row) => row.symbol).toList()..sort();
    expect(api.calls, sorted);
    expect(api.calls.toSet().length, 70);
    expect(api.maximumActive, lessThanOrEqualTo(5));
    expect(api.calls.any((symbol) => symbol.endsWith('.TW')), isTrue);
    expect(api.calls.any((symbol) => symbol.endsWith('.TWO')), isTrue);
    for (final row in third.candidates.take(30)) {
      expect(row.dataTimestamp, firstPrices[row.symbol]);
      expect(row.notes, contains('RS 為原掃描頁內排名，非全市場同步排名。'));
      expect(row.rsRank, lessThanOrEqualTo(30));
      expect(row.stopPrice, isNull, reason: 'Missing intraday data never invents a stop');
    }
    final persisted = preferences.getString('martin-mobile-tw-rolling-v1-3.5');
    expect(persisted, isNotNull);
    final state = MobileScanCheckpoint.fromJson(jsonDecode(persisted!) as Map<String, dynamic>);
    expect(state.candidates.length, 70, reason: 'Storage must not silently cap accumulated candidates at 30');
    expect(state.attempted.length, 70);
  });

  test('one failed member advances as attempted and cannot abort later pages', () async {
    api.failures.add(_stock(1).symbol);
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    final next = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(first.coverageScannedCount, 30);
    expect(first.coverageEvaluatedCount, 29);
    expect(first.evaluatedCount, 29);
    expect(first.missingSymbols, [_stock(1).symbol]);
    expect(next.coverageScannedCount, 60);
    expect(next.coverageEvaluatedCount, 59);
    expect(next.candidates.length, 59);
    expect(api.calls.where((symbol) => symbol == _stock(1).symbol).length, 1);
  });

  test('new repository resumes the next unattempted member from disk', () async {
    final firstScanner = repository();
    final first = await firstScanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    firstScanner.close();
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(first.coverageScannedCount, 30);
    expect(resumed.scanPageStart, 30);
    expect(resumed.coverageScannedCount, 60);
    expect(resumed.coverageEvaluatedCount, 60);
    expect(resumed.candidates.length, 60);
    expect(api.calls.first, _stock(30).symbol);
    expect(api.calls.contains(_stock(0).symbol), isFalse);
  });

  test('verified zero-ADR page is fresh and still permits subsequent pages', () async {
    api.lowAdr = true;
    final scanner = repository();
    final snapshot = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(snapshot.stale, isFalse);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 0);
    expect(snapshot.scanCompletedAt, now);
    expect(snapshot.coverageScannedCount, 30);
    expect(snapshot.coverageEvaluatedCount, 30);
    final second = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
        refreshQuotesOnly: true);
    expect(second.coverageScannedCount, 60);
    expect(second.coverageEvaluatedCount, 60);
  });

  test('a wholly failed page is stale yet persists coverage and continues', () async {
    api.failures.addAll(List.generate(30, _stock).map((row) => row.symbol));
    final scanner = repository();
    final failed = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(failed.stale, isTrue);
    expect(failed.evaluatedCount, 0);
    expect(failed.candidates, isEmpty);
    expect(failed.scanCompletedAt, isNull);
    expect(failed.coverageScannedCount, 30);
    expect(failed.coverageEvaluatedCount, 0);
    expect(failed.coverageRemainingCount, 40);
    expect(failed.warnings.join(' '), contains('不是成功的零候選'));
    final next = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(next.scanPageStart, 30);
    expect(next.coverageScannedCount, 60);
    expect(next.coverageEvaluatedCount, 30);
    expect(next.stale, isFalse);
  });

  test('deadline advances only the actually started prefix and ignores late errors', () async {
    final hold = Completer<MarketChart>();
    api.holds[_stock(0).symbol] = hold;
    final scanner = repository(batchSize: 2, budget: const Duration(milliseconds: 160));
    final progress = <MarketScanProgress>[];
    final snapshot = await scanner.fetchWithProgress(StockMarket.tw,
      adrThreshold: 3.5, onProgress: progress.add).timeout(const Duration(seconds: 1));
    expect(api.calls, [_stock(0).symbol, _stock(1).symbol]);
    expect(snapshot.coverageScannedCount, 2);
    expect(snapshot.coverageEvaluatedCount, 1);
    expect(snapshot.coverageRemainingCount, 68);
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.scanCompletedAt, isNull);
    final before = preferences.getString('martin-mobile-tw-rolling-v1-3.5');
    final count = progress.length;
    hold.completeError(StateError('Late fixture error'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, count);
    expect(preferences.getString('martin-mobile-tw-rolling-v1-3.5'), before);
    api.holds.clear();
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(api.calls.first, _stock(2).symbol);
    expect(resumed.scanPageStart, 2);
    expect(resumed.coverageScannedCount, 32);
  });

  test('dispose preserves started prefix and rejects late writes or callbacks', () async {
    final first = Completer<MarketChart>(), second = Completer<MarketChart>();
    api.holds[_stock(0).symbol] = first;
    api.holds[_stock(1).symbol] = second;
    final scanner = repository(batchSize: 2);
    final observed = <MarketScanProgress>[];
    final future = scanner.fetchWithProgress(StockMarket.tw,
      adrThreshold: 3.5, onProgress: observed.add);
    final failure = expectLater(future, throwsA(isA<RepositoryException>()));
    await _until(() => preferences.containsKey('martin-mobile-tw-rolling-v1-3.5'));
    scanner.close();
    await failure;
    final before = preferences.getString('martin-mobile-tw-rolling-v1-3.5');
    final count = observed.length;
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(before!) as Map<String, dynamic>);
    expect(saved.attempted, {_stock(0).symbol, _stock(1).symbol});
    first.completeError(StateError('Late disposed daily failure'));
    second.complete(_daily(_stock(1).symbol, now));
    await Future<void>.delayed(Duration.zero);
    expect(observed.length, count);
    expect(preferences.getString('martin-mobile-tw-rolling-v1-3.5'), before);
  });

  test('membership fingerprint changes reset the active round', () async {
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    universe.rows = [...universe.rows, _stock(100)];
    api.calls.clear();
    final changed = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(changed.universeFingerprint, isNot(first.universeFingerprint));
    expect(changed.coverageRound, 2);
    expect(changed.scanPageStart, 0);
    expect(changed.coverageScannedCount, 5);
    expect(changed.coverageTotalCount, 71);
    expect(api.calls.first, _stock(0).symbol);
  });

  test('an interrupted final chunk cannot renew a cooldown forever after restart', () async {
    universe.rows = List.generate(2, _stock);
    final first = Completer<MarketChart>(), second = Completer<MarketChart>();
    api.holds[_stock(0).symbol] = first;
    api.holds[_stock(1).symbol] = second;
    final scanner = repository(batchSize: 2);
    final future = scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    final failure = expectLater(future, throwsA(isA<RepositoryException>()));
    await _until(() => preferences.containsKey('martin-mobile-tw-rolling-v1-3.5'));
    scanner.close();
    await failure;
    final interrupted = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-tw-rolling-v1-3.5')!) as Map<String, dynamic>);
    expect(interrupted.remaining, 0);
    expect(interrupted.roundCompletedAt, isNull);
    first.complete(_daily(_stock(0).symbol, now));
    second.complete(_daily(_stock(1).symbol, now));
    await Future<void>.delayed(Duration.zero);
    api.holds.clear();
    api.calls.clear();
    api.lowAdr = true;
    final resumed = repository();
    final next = await resumed.fetch(StockMarket.tw, adrThreshold: 3.5,
        refreshQuotesOnly: true);
    expect(next.coverageRound, 2);
    expect(next.evaluatedCount, 2);
    expect(api.calls.length, 2, reason: 'Interrupted final page must re-evaluate, never enter hot-only forever');
    for (var minute = 1; minute <= 16; minute++) {
      now = _initialNow.add(Duration(minutes: minute));
      await resumed.fetch(StockMarket.tw, adrThreshold: 3.5,
          refreshQuotesOnly: true);
    }
    expect(api.calls.length, 4,
      reason: 'Cooldown uses fixed completion time and a new round starts after fifteen minutes');
  });

  test('Taipei day and ADR changes never mix old round candidates', () async {
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    now = now.add(const Duration(days: 1));
    final day = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(day.coverageRound, 2);
    expect(day.scanPageStart, 0);
    expect(day.candidates.length, 5);
    final threshold = await scanner.fetch(StockMarket.tw, adrThreshold: 4);
    expect(threshold.scanPageStart, 0);
    expect(threshold.coverageScannedCount, 5);
    final back = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(back.scanPageStart, 0);
    expect(back.coverageRound, greaterThan(day.coverageRound!));
    expect(first.coverageRound, 1);
    expect(MobileScanCheckpoint.dayFor(DateTime.utc(2026, 10, 15, 16)), '2026-10-16');
  });

  test('prerequisite failure never advances an existing cursor', () async {
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    api.benchmarkFails = true;
    final failed = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(failed.stale, isTrue);
    expect(failed.coverageScannedCount, first.coverageScannedCount);
    expect(failed.candidatesAreCumulative, isTrue);
    expect(api.calls.length, 5);
    api.benchmarkFails = false;
    final resumed = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(resumed.scanPageStart, 5);
  });

  test('completed round cools down, force starts a new round, bounds are enforced', () async {
    universe.rows = List.generate(4, _stock);
    api.lowAdr = true;
    final scanner = repository();
    final done = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(done.coverageRemainingCount, 0);
    final calls = api.calls.length;
    final cached = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
      refreshQuotesOnly: true);
    expect(cached.coverageRound, 1);
    expect(api.calls.length, calls);
    final forced = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
      forceRefresh: true);
    expect(forced.coverageRound, 2);
    expect(forced.scanPageStart, 0);
    expect(api.calls.length, calls + 4);
    expect(() => repository(pageSize: 0), throwsArgumentError);
    expect(() => repository(pageSize: 31), throwsArgumentError);
  });

  test('hot quotes remove candidates that fall below ADR and preserve rolling coverage', () async {
    universe.rows = List.generate(3, _stock);
    api.provideIntraday = true;
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect(first.candidates.length, 3);
    api.lowAdr = true;
    now = now.add(const Duration(minutes: 1));
    final refreshed = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5,
        refreshQuotesOnly: true);
    expect(refreshed.candidates, isEmpty);
    expect(refreshed.stale, isFalse);
    expect(refreshed.coverageScannedCount, 3);
    expect(refreshed.coverageEvaluatedCount, 3);
    expect(refreshed.coverageRemainingCount, 0);
    expect(refreshed.coverageRound, 1);
    expect(refreshed.warnings.join(' '), contains('本次即時更新 3/3'));
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-tw-rolling-v1-3.5')!) as Map<String, dynamic>);
    expect(saved.candidates, isEmpty);
    expect(saved.evaluated.length, 3);
  });

  test('checkpoint rejects holes or cross-market candidates and validates exact membership', () async {
    final scanner = repository(pageSize: 5);
    final snapshot = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    final text = preferences.getString('martin-mobile-tw-rolling-v1-3.5')!;
    final data = jsonDecode(text) as Map<String, dynamic>;
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'attempted': [_stock(1).symbol]}), throwsFormatException);
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'fingerprint': 'fabricated'}), throwsFormatException);
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'candidates': [{...snapshot.candidates.first.toJson(), 'market': 'us'}]}),
      throwsFormatException);
    final checkpoint = MobileScanCheckpoint.fromJson(data);
    final different = [...checkpoint.symbols]..[0] = '0999.TW';
    expect(checkpoint.matches(different, 3.5, now), isFalse);
    expect(checkpoint.matches(checkpoint.symbols, 4, now), isFalse);
    expect(snapshot.universeFingerprint, checkpoint.fingerprint);
  });
}
