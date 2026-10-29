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
final _initialNow = DateTime.utc(2026, 10, 16, 14, 50);

StockItem _stock(int index) {
  final code = 'S${1000 + index}';
  return StockItem(market: StockMarket.us,
    symbol: code, code: code,
    nameZh: '測試股票 $index', nameFullZh: '', nameEn: 'Fixture $index', abbrEn: '');
}

MarketChart _daily(String symbol, DateTime now, {bool lowAdr = false,
    StockMarket market = StockMarket.us}) =>
    MarketChart(symbol: symbol, market: market, currency: market.currency,
      exchangeTimezoneName: market == StockMarket.us ? 'America/New_York' : 'Asia/Taipei',
      gmtoffset: market == StockMarket.us ? -14400 : 28800,
      bars: List.generate(80, (index) => PriceBar(
        timestamp: DateTime.utc(2026, 10, 15, 13, 30)
            .subtract(Duration(days: 79 - index)),
        open: 100, high: lowAdr ? 101 : 104, low: lowAdr ? 99 : 96,
        close: 100, volume: 10000)),
      latestPrice: 100, quoteTimestamp: now, fetchedAt: now, interval: '1d',
      regularSessionStart: DateTime.utc(2026, 10, 16, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 20));

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
    return _daily(market == StockMarket.us ? '^GSPC' : '^TWII', clock(), market: market);
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
      return _daily(symbol, clock(), lowAdr: lowAdr, market: market);
    } finally { active--; }
  }

  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    if (!provideIntraday) {
      throw const FormatException('Explicit fixture has no intraday evidence');
    }
    return MarketChart(symbol: symbol, market: StockMarket.us, currency: 'USD',
      exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
      bars: [PriceBar(timestamp: DateTime.utc(2026, 10, 16, 13, 30),
        open: 100, high: 101, low: 99, close: 100, volume: 1000,
        interval: const Duration(minutes: 5))],
      latestPrice: 100, quoteTimestamp: clock(), fetchedAt: clock(), interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 16, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 16, 20));
  }
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences, this.clock)
      : super(preferences: preferences);
  List<StockItem> rows;
  List<StockItem>? twRows;
  final DateTime Function() clock;
  bool fails = false;
  int calls = 0;

  @override
  Future<UniverseSnapshot> load(StockMarket market,
      {bool forceRefresh = false}) async {
    calls++;
    if (fails) throw StateError('Explicit directory failure');
    return UniverseSnapshot(stocks: market == StockMarket.tw ? twRows ?? rows : rows,
      asOf: clock(),
      source: 'Explicit NYSE/Nasdaq/NYSE American member fixture', isComplete: false,
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
      preferences: preferences, now: () => now, usPageSize: pageSize,
      batchSize: batchSize, scanBudget: budget,
      interBatchDelay: const Duration(milliseconds: 1));
    addTearDown(value.close);
    return value;
  }

  test('seventy US exchange members progress 30, 60, 70 without a core ceiling', () async {
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final firstPrices = {for (final row in first.candidates) row.symbol: row.dataTimestamp};
    now = now.add(const Duration(minutes: 1));
    // quote-only timer calls MUST advance unfinished full-universe work.
    final second = await scanner.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    now = now.add(const Duration(minutes: 1));
    final third = await scanner.fetch(StockMarket.us, adrThreshold: 5,
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
    expect(api.calls.any((symbol) => symbol.startsWith('S10')), isTrue);
    expect(api.calls.any((symbol) => symbol.startsWith('S10')), isTrue);
    for (final row in third.candidates.take(30)) {
      expect(row.dataTimestamp, firstPrices[row.symbol]);
      expect(row.notes, contains('RS 為原掃描頁內排名，非全市場同步排名。'));
      expect(row.rsRank, lessThanOrEqualTo(30));
      expect(row.stopPrice, isNull, reason: 'Missing intraday data never invents a stop');
    }
    final persisted = preferences.getString('martin-mobile-us-rolling-v1-5.0');
    expect(persisted, isNotNull);
    final state = MobileScanCheckpoint.fromJson(jsonDecode(persisted!) as Map<String, dynamic>);
    expect(state.candidates.length, 70, reason: 'Storage must not silently cap accumulated candidates at 30');
    expect(state.attempted.length, 70);
  });

  test('one failed member advances as attempted and cannot abort later pages', () async {
    api.failures.add(_stock(1).symbol);
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final next = await scanner.fetch(StockMarket.us, adrThreshold: 5);
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
    final first = await firstScanner.fetch(StockMarket.us, adrThreshold: 5);
    firstScanner.close();
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.us, adrThreshold: 5);
    expect(first.coverageScannedCount, 30);
    expect(resumed.scanPageStart, 30);
    expect(resumed.coverageScannedCount, 60);
    expect(resumed.coverageEvaluatedCount, 60);
    expect(resumed.candidates.length, 60);
    expect(api.calls.first, _stock(30).symbol);
    expect(universe.calls, 1,
      reason: 'Active pages reuse pinned metadata, even if the provider list changes');
    expect(api.calls.contains(_stock(0).symbol), isFalse);
  });

  test('verified zero-ADR page is fresh and still permits subsequent pages', () async {
    api.lowAdr = true;
    final scanner = repository();
    final snapshot = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(snapshot.stale, isFalse);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 0);
    expect(snapshot.scanCompletedAt, now);
    expect(snapshot.coverageScannedCount, 30);
    expect(snapshot.coverageEvaluatedCount, 30);
    final second = await scanner.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect(second.coverageScannedCount, 60);
    expect(second.coverageEvaluatedCount, 60);
  });

  test('a wholly failed page is stale yet persists coverage and continues', () async {
    api.failures.addAll(List.generate(30, _stock).map((row) => row.symbol));
    final scanner = repository();
    final failed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(failed.stale, isTrue);
    expect(failed.evaluatedCount, 0);
    expect(failed.candidates, isEmpty);
    expect(failed.scanCompletedAt, isNull);
    expect(failed.coverageScannedCount, 30);
    expect(failed.coverageEvaluatedCount, 0);
    expect(failed.coverageRemainingCount, 40);
    expect(failed.warnings.join(' '), contains('不是成功的零候選'));
    final next = await scanner.fetch(StockMarket.us, adrThreshold: 5);
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
    final snapshot = await scanner.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, onProgress: progress.add).timeout(const Duration(seconds: 1));
    expect(api.calls, [_stock(0).symbol, _stock(1).symbol]);
    expect(snapshot.coverageScannedCount, 2);
    expect(snapshot.coverageEvaluatedCount, 1);
    expect(snapshot.coverageRemainingCount, 68);
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.scanCompletedAt, isNull);
    final before = preferences.getString('martin-mobile-us-rolling-v1-5.0');
    final count = progress.length;
    hold.completeError(StateError('Late fixture error'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, count);
    expect(preferences.getString('martin-mobile-us-rolling-v1-5.0'), before);
    api.holds.clear();
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.us, adrThreshold: 5);
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
    final future = scanner.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, onProgress: observed.add);
    final failure = expectLater(future, throwsA(isA<RepositoryException>()));
    await _until(() => preferences.containsKey('martin-mobile-us-rolling-v1-5.0'));
    scanner.close();
    await failure;
    final before = preferences.getString('martin-mobile-us-rolling-v1-5.0');
    final count = observed.length;
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(before!) as Map<String, dynamic>);
    expect(saved.attempted, {_stock(0).symbol, _stock(1).symbol});
    first.completeError(StateError('Late disposed daily failure'));
    second.complete(_daily(_stock(1).symbol, now));
    await Future<void>.delayed(Duration.zero);
    expect(observed.length, count);
    expect(preferences.getString('martin-mobile-us-rolling-v1-5.0'), before);
  });

  test('directory growth changes identity only after the pinned round finishes', () async {
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    universe.rows = [...universe.rows, _stock(100)];
    api.calls.clear();
    final changed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(changed.universeFingerprint, first.universeFingerprint);
    expect(changed.coverageRound, 1);
    expect(changed.scanPageStart, 30);
    expect(changed.coverageScannedCount, 60);
    expect(changed.coverageTotalCount, 70);
    expect(api.calls.first, _stock(30).symbol);
    expect(universe.calls, 1,
      reason: 'A membership change is not fetched halfway through a round');
    final completed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(completed.coverageScannedCount, 70);
    expect(completed.coverageRemainingCount, 0);
    expect(api.calls, List.generate(40, (index) => _stock(index + 30).symbol));
    api.calls.clear();
    final nextRound = await scanner.fetch(StockMarket.us, adrThreshold: 5,
        forceRefresh: true);
    expect(nextRound.universeFingerprint, isNot(first.universeFingerprint));
    expect(nextRound.coverageRound, 2);
    expect(nextRound.scanPageStart, 0);
    expect(nextRound.coverageTotalCount, 71);
    expect(api.calls.first, _stock(0).symbol);
    expect(universe.calls, 2);
  });

  test('full subset full directories resume 30, 60, 70 across phone restarts', () async {
    final firstScanner = repository();
    final first = await firstScanner.fetch(StockMarket.us, adrThreshold: 5);
    firstScanner.close();
    // A temporary one-exchange/subset response omits ALL next-page members.
    // Their genuine company metadata must survive in the persisted journal.
    universe.rows = List.generate(30, _stock);
    final secondScanner = repository();
    final second = await secondScanner.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true, forceRefresh: true);
    secondScanner.close();
    universe.rows = List.generate(70, _stock);
    final third = await repository().fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect([first.coverageScannedCount, second.coverageScannedCount,
      third.coverageScannedCount], [30, 60, 70]);
    expect([first.coverageTotalCount, second.coverageTotalCount,
      third.coverageTotalCount], [70, 70, 70]);
    expect([first.coverageRound, second.coverageRound, third.coverageRound], [1, 1, 1]);
    expect(second.scanPageStart, 30);
    expect(third.scanPageStart, 60);
    expect(second.universeFingerprint, first.universeFingerprint);
    expect(third.universeFingerprint, first.universeFingerprint);
    expect(api.calls, List.generate(70, (index) => _stock(index).symbol));
    expect(api.calls.toSet().length, 70);
    expect(second.candidates.singleWhere((row) => row.symbol == _stock(40).symbol).name,
        _stock(40).nameZh);
    expect(universe.calls, 1,
      reason: 'Restoring complete genuine metadata avoids another directory HTTP request');
    expect(third.missingSymbols, isEmpty);
    expect(third.candidates.length, 70);
    final persisted = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(persisted.members.length, 70);
    expect(persisted.members.map((stock) => stock.symbol).toSet(),
        List.generate(70, (index) => _stock(index).symbol).toSet());
    expect(persisted.market, StockMarket.us);
    expect(persisted.members.every((stock) => stock.market == StockMarket.us), isTrue);
  });

  test('an initially partial round finishes once before adopting the larger universe', () async {
    universe.rows = List.generate(35, _stock);
    final scanner = repository();
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    universe.rows = List.generate(70, _stock).reversed.toList();
    final last = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(first.coverageScannedCount, 30);
    expect(last.coverageScannedCount, 35);
    expect(last.coverageTotalCount, 35);
    expect(last.coverageRemainingCount, 0);
    expect(api.calls, List.generate(35, (index) => _stock(index).symbol));
    final next = await scanner.fetch(StockMarket.us, adrThreshold: 5,
        forceRefresh: true);
    expect(next.coverageRound, 2);
    expect(next.coverageTotalCount, 70);
    expect(next.coverageScannedCount, 30);
    expect(next.universeFingerprint, isNot(first.universeFingerprint));
    expect(universe.calls, 2);
  });

  test('saved metadata continues after a directory outage without replaying page one', () async {
    final firstScanner = repository();
    await firstScanner.fetch(StockMarket.us, adrThreshold: 5);
    firstScanner.close();
    universe.fails = true;
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.us, adrThreshold: 5,
        forceRefresh: true);
    expect(resumed.stale, isFalse);
    expect(resumed.scanPageStart, 30);
    expect(resumed.coverageScannedCount, 60);
    expect(resumed.coverageRound, 1);
    expect(universe.calls, 1);
    expect(api.calls, List.generate(30, (index) => _stock(index + 30).symbol));
    expect(resumed.warnings.join(' '), contains('S1030–S1059'));
    expect(resumed.warnings.join(' '), contains('下一檔：S1060'));
  });

  test('legacy schema one resolves real metadata without resetting a changed directory', () async {
    final firstScanner = repository();
    final first = await firstScanner.fetch(StockMarket.us, adrThreshold: 5);
    firstScanner.close();
    const key = 'martin-mobile-us-rolling-v1-5.0';
    final legacy = jsonDecode(preferences.getString(key)!) as Map<String, dynamic>
      ..remove('members')..remove('universe_warnings');
    await preferences.setString(key, jsonEncode(legacy));
    universe.rows = [...universe.rows, _stock(100)];
    api.calls.clear();
    final resumed = await repository().fetch(StockMarket.us, adrThreshold: 5);
    expect(universe.calls, 2,
      reason: 'Old journals need one actual metadata lookup to populate missing names');
    expect(resumed.coverageRound, 1);
    expect(resumed.universeFingerprint, first.universeFingerprint);
    expect(resumed.coverageTotalCount, 70);
    expect(resumed.scanPageStart, 30);
    expect(resumed.coverageScannedCount, 60);
    expect(api.calls, List.generate(30, (index) => _stock(index + 30).symbol));
    final upgraded = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString(key)!) as Map<String, dynamic>);
    expect(upgraded.members.length, 70);
    expect(upgraded.members.any((row) => row.symbol == _stock(100).symbol), isFalse);
  });

  test('an interrupted final chunk cannot renew a cooldown forever after restart', () async {
    universe.rows = List.generate(2, _stock);
    final first = Completer<MarketChart>(), second = Completer<MarketChart>();
    api.holds[_stock(0).symbol] = first;
    api.holds[_stock(1).symbol] = second;
    final scanner = repository(batchSize: 2);
    final future = scanner.fetch(StockMarket.us, adrThreshold: 5);
    final failure = expectLater(future, throwsA(isA<RepositoryException>()));
    await _until(() => preferences.containsKey('martin-mobile-us-rolling-v1-5.0'));
    scanner.close();
    await failure;
    final interrupted = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(interrupted.remaining, 0);
    expect(interrupted.roundCompletedAt, isNull);
    first.complete(_daily(_stock(0).symbol, now));
    second.complete(_daily(_stock(1).symbol, now));
    await Future<void>.delayed(Duration.zero);
    api.holds.clear();
    api.calls.clear();
    api.lowAdr = true;
    final resumed = repository();
    final next = await resumed.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect(next.coverageRound, 2);
    expect(next.evaluatedCount, 2);
    expect(api.calls.length, 2, reason: 'Interrupted final page must re-evaluate, never enter hot-only forever');
    for (var minute = 1; minute <= 16; minute++) {
      now = _initialNow.add(Duration(minutes: minute));
      await resumed.fetch(StockMarket.us, adrThreshold: 5,
          refreshQuotesOnly: true);
    }
    expect(api.calls.length, 4,
      reason: 'Cooldown uses fixed completion time and a new round starts after fifteen minutes');
  });

  test('unfinished US rounds cross New York midnight while ADR changes reset', () async {
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final before = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    now = DateTime.utc(2026, 10, 17, 4, 1);
    final nextDay = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(nextDay.coverageRound, 1);
    expect(nextDay.scanPageStart, 5);
    expect(nextDay.coverageScannedCount, 10);
    expect(nextDay.candidates.length, 10);
    final after = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(after.day, before.day, reason: 'The stored day is the immutable round start.');
    expect(universe.calls, 1);
    final threshold = await scanner.fetch(StockMarket.us, adrThreshold: 6);
    expect(threshold.scanPageStart, 0);
    expect(threshold.coverageScannedCount, 5);
    final back = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(back.scanPageStart, 0);
    expect(back.coverageRound, greaterThan(first.coverageRound!));
  });

  test('prerequisite failure never advances an existing cursor', () async {
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    api.benchmarkFails = true;
    final progress = <MarketScanProgress>[];
    final failed = await scanner.fetchWithProgress(StockMarket.us,
        adrThreshold: 5, onProgress: progress.add);
    expect(failed.stale, isTrue);
    expect(failed.coverageScannedCount, first.coverageScannedCount);
    expect(failed.candidatesAreCumulative, isTrue);
    expect(api.calls.length, 5);
    expect(progress.last.finished, isTrue);
    expect(progress.last.attemptedCount, 0);
    expect(progress.last.evaluatedCount, 0);
    expect(progress.last.partialSnapshot, isNull,
        reason: 'An old cursor is not newly verified partial market data.');
    api.benchmarkFails = false;
    final resumed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(resumed.scanPageStart, 5);
  });

  test('a first prerequisite failure still emits a terminal zero-work event', () async {
    api.benchmarkFails = true;
    final scanner = repository();
    final progress = <MarketScanProgress>[];
    await expectLater(scanner.fetchWithProgress(StockMarket.us,
        adrThreshold: 5, onProgress: progress.add),
      throwsA(isA<RepositoryException>()));
    expect(progress, isNotEmpty);
    expect(progress.last.finished, isTrue);
    expect(progress.last.attemptedCount, 0);
    expect(progress.last.completedCount, 0);
    expect(progress.last.evaluatedCount, 0);
    expect(progress.last.partialSnapshot, isNull);
    expect(api.calls, isEmpty);
    expect(preferences.getString('martin-mobile-us-rolling-v1-5.0'), isNull);
  });

  test('a round started yesterday cools down from todays completion and renews after fifteen minutes', () async {
    universe.rows = List.generate(7, _stock);
    api.lowAdr = true;
    final scanner = repository(pageSize: 5);
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(first.coverageRemainingCount, 2);
    now = DateTime.utc(2026, 10, 17, 4, 1);
    final finished = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(finished.coverageRound, 1);
    expect(finished.coverageRemainingCount, 0);
    final journal = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(journal.day, '2026-10-16');
    expect(MobileScanCheckpoint.dayFor(journal.roundCompletedAt!, market: StockMarket.us),
        '2026-10-17');
    final calls = api.calls.length;
    final cooled = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(cooled.coverageRound, 1);
    expect(cooled.scanPageStart, 5);
    expect(api.calls.length, calls,
        reason: 'An empty qualified list needs no hot-quote work during cooldown.');
    expect(universe.calls, 1);
    now = now.add(const Duration(minutes: 15));
    final renewed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(renewed.coverageRound, 2);
    expect(renewed.scanPageStart, 0);
    expect(renewed.coverageScannedCount, 5);
    expect(universe.calls, 2);
  });

  test('the next New York date starts a new completed round even within cooldown', () async {
    universe.rows = List.generate(2, _stock);
    api.lowAdr = true;
    now = DateTime.utc(2026, 10, 17, 3, 59);
    final scanner = repository();
    final completed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(completed.coverageRemainingCount, 0);
    now = DateTime.utc(2026, 10, 17, 4, 1);
    final nextDay = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(nextDay.coverageRound, 2);
    expect(nextDay.scanPageStart, 0);
    expect(api.calls.length, 4);
    expect(universe.calls, 2);
  });

  test('completed round cools down, force starts a new round, bounds are enforced', () async {
    universe.rows = List.generate(4, _stock);
    api.lowAdr = true;
    final scanner = repository();
    final done = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(done.coverageRemainingCount, 0);
    final calls = api.calls.length;
    final cached = await scanner.fetch(StockMarket.us, adrThreshold: 5,
      refreshQuotesOnly: true);
    expect(cached.coverageRound, 1);
    expect(api.calls.length, calls);
    final forced = await scanner.fetch(StockMarket.us, adrThreshold: 5,
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
    final first = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(first.candidates.length, 3);
    api.lowAdr = true;
    now = now.add(const Duration(minutes: 1));
    final refreshed = await scanner.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect(refreshed.candidates, isEmpty);
    expect(refreshed.stale, isFalse);
    expect(refreshed.coverageScannedCount, 3);
    expect(refreshed.coverageEvaluatedCount, 3);
    expect(refreshed.coverageRemainingCount, 0);
    expect(refreshed.coverageRound, 1);
    expect(refreshed.warnings.join(' '), contains('本次即時更新 3/3'));
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(saved.candidates, isEmpty);
    expect(saved.evaluated.length, 3);
  });

  test('checkpoint rejects holes or cross-market candidates and validates exact membership', () async {
    final scanner = repository(pageSize: 5);
    final snapshot = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final text = preferences.getString('martin-mobile-us-rolling-v1-5.0')!;
    final data = jsonDecode(text) as Map<String, dynamic>;
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'attempted': [_stock(1).symbol]}), throwsFormatException);
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'fingerprint': 'fabricated'}), throwsFormatException);
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'candidates': [{...snapshot.candidates.first.toJson(), 'market': 'tw'}]}),
      throwsFormatException);
    final checkpoint = MobileScanCheckpoint.fromJson(data);
    final different = [...checkpoint.symbols]..[0] = 'A999';
    expect(checkpoint.matches(different, 5, now), isFalse);
    expect(checkpoint.matches(checkpoint.symbols, 6, now), isFalse);
    expect(checkpoint.canResume(5, now), isTrue);
    expect(checkpoint.canResume(6, now), isFalse);
    expect(checkpoint.canResume(5, now.add(const Duration(days: 1))), isTrue);
    expect(() => MobileScanCheckpoint.fromJson({...data,
      'members': [_stock(100).toJson()]}), throwsFormatException);
    final legacy = {...data}..remove('members')..remove('universe_warnings');
    final restored = MobileScanCheckpoint.fromJson(legacy);
    expect(restored.members, isEmpty);
    expect(restored.attempted, checkpoint.attempted);
    expect(restored.universeWarnings, checkpoint.warnings);
    expect(restored.canResume(5, now), isTrue);
    expect(snapshot.universeFingerprint, checkpoint.fingerprint);
  });

  test('New York calendar dates follow both standard time and daylight saving', () {
    String day(DateTime time) => MobileScanCheckpoint.dayFor(time, market: StockMarket.us);
    expect(day(DateTime.utc(2026, 1, 16, 4, 30)), '2026-01-15');
    expect(day(DateTime.utc(2026, 1, 16, 5)), '2026-01-16');
    expect(day(DateTime.utc(2026, 7, 16, 3, 30)), '2026-07-15');
    expect(day(DateTime.utc(2026, 7, 16, 4)), '2026-07-16');
    expect(day(DateTime.utc(2026, 3, 8, 6, 59)), '2026-03-08');
    expect(day(DateTime.utc(2026, 3, 8, 7, 1)), '2026-03-08');
    expect(day(DateTime.utc(2026, 11, 1, 5, 59)), '2026-11-01');
    expect(day(DateTime.utc(2026, 11, 1, 6, 1)), '2026-11-01');
    expect(MobileScanCheckpoint.dayFor(DateTime.utc(2026, 10, 15, 16)), '2026-10-16');
  });

  test('US class-share symbols and market-bound checkpoint identities are strict', () {
    MobileScanCheckpoint make(StockMarket market, List<String> symbols) =>
        MobileScanCheckpoint(market: market, symbols: symbols, threshold: 5,
          day: MobileScanCheckpoint.dayFor(now, market: market), round: 1,
          attempted: const {}, evaluated: const {}, candidates: const [],
          updatedAt: now, universeAsOf: now, universeIsComplete: false,
          warnings: const []);
    final checkpoint = make(StockMarket.us, ['AAPL', 'BF-B', 'BRK-B']);
    final restored = MobileScanCheckpoint.fromJson(checkpoint.toJson());
    expect(restored.market, StockMarket.us);
    expect(restored.symbols, ['AAPL', 'BF-B', 'BRK-B']);
    expect(restored.fingerprint, startsWith('us-mobile-v1-'));
    for (final symbol in ['2330.TW', '^GSPC', 'BRK.B', 'aapl', 'A--B', 'A-B-C']) {
      expect(() => make(StockMarket.us, [symbol]), throwsFormatException);
    }
    final tw = make(StockMarket.tw, ['2330.TW']);
    final legacy = tw.toJson();
    expect(legacy['schema'], 1);
    expect(legacy['market'], 'tw');
    expect(MobileScanCheckpoint.fromJson(legacy).fingerprint,
        MobileScanCheckpoint.fingerprintFor(['2330.TW']));
    expect(() => MobileScanCheckpoint.fromJson({...checkpoint.toJson(),
      'market': 'tw'}), throwsFormatException);
  });

  test('seven-day retention bounds both in-memory and restored US resumes', () async {
    final scanner = repository(pageSize: 5);
    await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(saved.canResume(5, now.add(const Duration(days: 7))), isTrue);
    expect(saved.canResume(5, now.add(const Duration(days: 7, seconds: 1))), isFalse);
    expect(saved.canResume(5, now.subtract(const Duration(seconds: 1))), isFalse);
    now = now.add(const Duration(days: 8));
    api.calls.clear();
    final renewed = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    expect(renewed.scanPageStart, 0);
    expect(renewed.coverageScannedCount, 5);
    expect(universe.calls, 2);
    expect(api.calls.first, _stock(0).symbol);
    scanner.close();
    await preferences.setString('martin-mobile-us-rolling-v1-5.0', jsonEncode(saved.toJson()));
    api.calls.clear();
    final restarted = await repository(pageSize: 5).fetch(StockMarket.us, adrThreshold: 5);
    expect(restarted.scanPageStart, 0);
    expect(restarted.coverageScannedCount, 5);
    expect(api.calls.first, _stock(0).symbol);
  });

  test('Taiwan and US journals retain separate thresholds and next-member cursors', () async {
    universe.twRows = List.generate(40, (index) {
      final code = '${2000 + index}';
      return StockItem(market: StockMarket.tw, symbol: '$code.TW', code: code,
        nameZh: '台股測試 $index', nameFullZh: '', nameEn: 'TW fixture', abbrEn: '');
    });
    final scanner = repository(pageSize: 5);
    final us = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final tw = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    final usNext = await scanner.fetch(StockMarket.us, adrThreshold: 5);
    final twNext = await scanner.fetch(StockMarket.tw, adrThreshold: 3.5);
    expect([us.coverageScannedCount, usNext.coverageScannedCount], [5, 10]);
    expect([tw.coverageScannedCount, twNext.coverageScannedCount], [30, 40]);
    expect(usNext.coverageRound, 1);
    expect(twNext.coverageRound, 1);
    expect(preferences.getString('martin-mobile-us-rolling-v1-5.0'), isNotNull);
    expect(preferences.getString('martin-mobile-tw-rolling-v1-3.5'), isNotNull);
    expect(preferences.getString('martin-mobile-us-rolling-v1-active-threshold'), '5.0');
    expect(preferences.getString('martin-mobile-tw-rolling-v1-active-threshold'), '3.5');
  });

  test('a 5118-member fixture resumes its final thirty rather than capping at thirty or five hundred', () async {
    // Capacity-only fixture. The preseeded prefix records attempted work, not
    // invented historical quotes or evidence of a successful live scan.
    final rows = List.generate(5118, _stock);
    final symbols = rows.map((row) => row.symbol).toList()..sort();
    final journal = MobileScanCheckpoint(market: StockMarket.us,
      symbols: symbols, members: rows,
      threshold: 5, day: MobileScanCheckpoint.dayFor(now, market: StockMarket.us),
      round: 1, attempted: symbols.take(5088).toSet(), evaluated: const {},
      candidates: const [], updatedAt: now, universeAsOf: now,
      universeIsComplete: false, warnings: const ['Explicit capacity fixture, not live evidence.'],
      pageStart: 5058, pageSize: 30, pageStale: true);
    await preferences.setString('martin-mobile-us-rolling-v1-5.0', jsonEncode(journal.toJson()));
    universe.rows = rows;
    final result = await repository().fetch(StockMarket.us, adrThreshold: 5);
    expect(result.coverageTotalCount, 5118);
    expect(result.scanPageStart, 5088);
    expect(result.scanPageSize, 30);
    expect(result.coverageScannedCount, 5118);
    expect(result.coverageEvaluatedCount, 30);
    expect(result.coverageRemainingCount, 0);
    expect(api.calls, symbols.skip(5088).toList());
    expect(api.calls.last, symbols.last);
    expect(api.maximumActive, lessThanOrEqualTo(5));
    expect(universe.calls, 0, reason: 'Resume uses complete actual fixture metadata saved with the round.');
    final saved = MobileScanCheckpoint.fromJson(jsonDecode(
        preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map<String, dynamic>);
    expect(saved.symbols.length, 5118);
    expect(saved.remaining, 0);
    expect(saved.evaluated, symbols.skip(5088).toSet());
    expect(saved.roundCompletedAt, now);
  });

  test('US page-size alias is bounded and cannot silently conflict', () {
    final legacy = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 7);
    final explicit = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, usPageSize: 9);
    addTearDown(legacy.close);
    addTearDown(explicit.close);
    expect(legacy.usPageSize, 7);
    expect(explicit.usPageSize, 9);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      corePoolSize: 7, usPageSize: 9), throwsArgumentError);
    for (final size in [0, 31]) {
      expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
        usPageSize: size), throwsArgumentError);
    }
  });
}
