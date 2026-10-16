import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/live_batch_deadline.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/live_portfolio_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 14, 14, 50);
StockItem _stock(String symbol) => StockItem(market: StockMarket.us,
  symbol: symbol, code: symbol, nameZh: '', nameFullZh: '', nameEn: symbol, abbrEn: '');

MarketChart _daily(String symbol, {int count = 80, bool lowAdr = false,
    int sessionOffsetDays = 0, StockMarket market = StockMarket.us}) => MarketChart(symbol: symbol,
  market: market, currency: market.currency,
  exchangeTimezoneName: market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York',
  gmtoffset: market == StockMarket.tw ? 28800 : -14400, bars: List.generate(count, (index) => PriceBar(
    timestamp: DateTime.utc(2026, 10, 13, 13, 30)
        .subtract(Duration(days: count - 1 - index + sessionOffsetDays)),
    open: 100, high: lowAdr ? 101 : 104, low: lowAdr ? 99 : 96, close: 100, volume: 10000)),
  latestPrice: 100, quoteTimestamp: _now, fetchedAt: _now, interval: '1d',
  regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
  regularSessionEnd: DateTime.utc(2026, 10, 14, 20));

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences) : super(preferences: preferences, now: () => _now);
  bool fail = false;
  final Map<String, Object> dailyFailures = {};
  final Map<String, Object> intradayFailures = {};
  final Map<String, MarketChart> dailyCharts = {};
  final Map<String, Completer<MarketChart>> dailyGates = {};
  final Map<String, Completer<MarketChart>> intradayGates = {};
  Completer<MarketChart>? benchmarkGate;
  final Stopwatch timing = Stopwatch()..start();
  final Map<String, Duration> dailyStarted = {};
  final Map<String, Duration> intradayFinished = {};
  int dailyCalls = 0, intradayCalls = 0, benchmarkCalls = 0;
  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    dailyCalls++;
    dailyStarted[symbol] = timing.elapsed;
    if (fail) throw StateError('Network unavailable');
    final failure = dailyFailures[symbol];
    if (failure != null) throw failure;
    final gate = dailyGates[symbol];
    if (gate != null) return gate.future;
    return dailyCharts[symbol] ?? _daily(symbol, market: market);
  }
  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async {
    benchmarkCalls++;
    if (fail) throw StateError('Network unavailable');
    final gate = benchmarkGate;
    if (gate != null) return gate.future;
    return _daily(market == StockMarket.tw ? '^TWII' : '^GSPC', market: market);
  }
  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    intradayCalls++;
    if (fail) throw StateError('Network unavailable');
    final failure = intradayFailures[symbol];
    if (failure != null) throw failure;
    final gate = intradayGates[symbol];
    if (gate != null) {
      final chart = await gate.future;
      intradayFinished[symbol] = timing.elapsed;
      return chart;
    }
    final chart = MarketChart(symbol: symbol, market: market, currency: 'USD',
      exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
      bars: [PriceBar(timestamp: DateTime.utc(2026, 10, 14, 13, 30),
        open: 100, high: 101, low: 99, close: 100, volume: 1000,
        interval: const Duration(minutes: 5))], latestPrice: 100,
      quoteTimestamp: _now, fetchedAt: _now, interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
    intradayFinished[symbol] = timing.elapsed;
    return chart;
  }
}

Future<void> _waitForDailyCalls(_Api api, int expected) async {
  final watch = Stopwatch()..start();
  while (api.dailyCalls < expected) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Test refresh did not start the expected chunk.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

// Unit-only Yahoo-shaped HTTP payload. This exercises the real parser and
// strategy path without inserting fixture prices into any production service.
Map<String, Object> _chartDocument(String symbol, String interval) {
  int unix(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
  final daily = interval == '1d';
  final times = daily
      ? List.generate(80, (index) => unix(DateTime.utc(2026, 10, 13, 13, 30)
          .subtract(Duration(days: 79 - index))))
      : [unix(DateTime.utc(2026, 10, 14, 13, 30))];
  final count = times.length;
  return {
    'chart': {
      'error': null,
      'result': [{
        'meta': {
          'symbol': symbol, 'currency': 'USD',
          'exchangeTimezoneName': 'America/New_York', 'gmtoffset': -14400,
          'regularMarketPrice': 100, 'regularMarketTime': unix(_now),
          'currentTradingPeriod': {'regular': {
            'start': unix(DateTime.utc(2026, 10, 14, 13, 30)),
            'end': unix(DateTime.utc(2026, 10, 14, 20)),
          }},
        },
        'timestamp': times,
        'indicators': {'quote': [{
          'open': List.filled(count, 100), 'high': List.filled(count, 104),
          'low': List.filled(count, 96), 'close': List.filled(count, 100),
          'volume': List.filled(count, 10000),
        }]},
      }],
    },
  };
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences) : super(preferences: preferences);
  final List<StockItem> rows;
  int calls = 0;
  Completer<UniverseSnapshot>? gate;
  @override
  Future<UniverseSnapshot> load(StockMarket market, {bool forceRefresh = false}) async {
    calls++;
    final pending = gate;
    if (pending != null) return pending.future;
    return UniverseSnapshot(stocks: rows, asOf: _now,
      source: 'Unit-test member fixture', isComplete: false,
      warnings: const ['Partial fixture, not a live complete universe']);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _Api api;
  late _Universe universe;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    api = _Api(preferences);
    universe = _Universe([_stock('NVDA'), _stock('TSLA')], preferences);
  });

  test('scan reports evaluated coverage and ranks before ADR filtering', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.universeCount, 2);
    expect(snapshot.universeIsComplete, false);
    expect(snapshot.candidates.map((stock) => stock.rsScore), [50, 50]);
    expect(snapshot.candidates.every((stock) => !stock.isConfirmed), true);
    expect(api.dailyCalls, 2);
    expect(api.intradayCalls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('completed-round quote refresh reuses the directory and force starts a new round', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await repository.fetch(StockMarket.us, adrThreshold: 5);
    await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(universe.calls, 1);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(universe.calls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('HTTP failure retains explicitly stale true-data snapshot', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, adrThreshold: 5);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(cached.stale, true);
    expect(cached.fetchedAt, first.fetchedAt);
    expect(cached.source, contains('真實快取'));
    expect(cached.candidates.map((stock) => stock.symbol), ['NVDA', 'TSLA']);
    repository.close(); api.close(); universe.close();
  });
  test('no cache and no real data reports error instead of demo fallback', () async {
    api.fail = true;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5), throwsA(isA<Exception>()));
    repository.close(); api.close(); universe.close();
  });
  test('portfolio completed EMA quote and stale fallback preserve timestamp', () async {
    final repository = DirectLivePortfolioRepository(api: api,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    final quote = first.quotes['NVDA']!;
    expect(quote.currentPrice, 100);
    expect(quote.ema9, 100);
    expect(quote.ema21, 100);
    expect(quote.ema50, 100);
    expect(quote.closeConfirmed, true);
    expect(quote.isStale, false);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    expect(cached.quotes['NVDA']!.isStale, true);
    expect(cached.quotes['NVDA']!.isCached, true);
    expect(cached.quotes['NVDA']!.quoteTimestamp, quote.quoteTimestamp);
    expect(cached.errors['NVDA'], contains('保留上次真實快取'));
    repository.close(); api.close();
  });

  test('scan deadline returns partial coverage and does not publish late workers', () async {
    final rows = ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList();
    universe = _Universe(rows, preferences);
    final gates = {for (final symbol in ['TSLA', 'AMD', 'AAPL', 'META'])
      symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 200));
    final firstRequest = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    final sameRequest = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(identical(firstRequest, sameRequest), true);
    final partial = await firstRequest.timeout(const Duration(seconds: 2));
    expect(partial.evaluatedCount, 1);
    expect(partial.universeCount, 5);
    expect(partial.missingSymbols.toSet(), gates.keys.toSet());
    expect(partial.warnings.any((warning) => warning.contains('整批期限')), true);
    final partialCache = jsonDecode(preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map;
    expect(partialCache['page_evaluated'], 1,
        reason: 'The scan reserves time to persist a partial offline snapshot inside its budget.');

    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(recovered.evaluatedCount, 5);
    expect(recovered.missingSymbols, isEmpty);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls,
        reason: 'Late daily replies must not schedule another intraday request.');
    final persisted = jsonDecode(preferences.getString('martin-mobile-us-rolling-v1-5.0')!) as Map;
    expect(persisted['page_evaluated'], 5,
        reason: 'The expired batch must not overwrite a successful retry cache.');
    repository.close(); api.close(); universe.close();
  });

  test('universe request is inside deadline and a failed pending entry can retry', () async {
    final gate = Completer<UniverseSnapshot>();
    universe.gate = gate;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 80));
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5)
        .timeout(const Duration(seconds: 2)), throwsA(isA<RepositoryException>()));
    expect(api.benchmarkCalls, 1,
        reason: 'Independent benchmark loading starts while the universe request is pending.');
    universe.gate = null;
    final retry = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(retry.evaluatedCount, 2);
    gate.completeError(StateError('Old universe request failed after retry.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close(); universe.close();
  });

  test('benchmark deadline preserves genuine cache and next forced refresh recovers', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 150));
    final initial = await repository.fetch(StockMarket.us, adrThreshold: 5);
    final gate = Completer<MarketChart>();
    api.benchmarkGate = gate;
    final stale = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 2));
    expect(stale.stale, true);
    expect(stale.fetchedAt, initial.fetchedAt);
    expect(stale.candidates.length, initial.candidates.length);
    api.benchmarkGate = null;
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(recovered.stale, false);
    gate.complete(_daily('^GSPC'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close(); universe.close();
  });

  test('cold polling starts one bounded US page instead of an unbounded universe scan', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final initialized = await repository.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect(universe.calls, 1);
    expect(initialized.evaluatedCount, 2);
    expect(initialized.coverageScannedCount, 2);
    expect(initialized.coverageRemainingCount, 0);
    expect(initialized.scanPoolSize, lessThanOrEqualTo(30));
    expect(api.dailyCalls, 2);
    repository.close(); api.close(); universe.close();
  });

  test('hot quote deadline preserves timestamps and cannot launch late intraday work', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      quoteRefreshBudget: const Duration(milliseconds: 150));
    final initial = await repository.fetch(StockMarket.us, adrThreshold: 5);
    final gates = {for (final symbol in ['NVDA', 'TSLA']) symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final stale = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true)
        .timeout(const Duration(seconds: 2));
    expect(stale.stale, true);
    expect(stale.fetchedAt, initial.fetchedAt);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls);
    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(recovered.stale, false);
    expect(universe.calls, 1);
    repository.close(); api.close(); universe.close();
  });

  test('portfolio whole-batch deadline identifies all missing symbols and retries', () async {
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now, updateBudget: const Duration(milliseconds: 500));
    final gates = {for (final symbol in ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'])
      symbol: Completer<MarketChart>()};
    api.dailyGates.addAll(gates);
    final request = repository.fetch(StockMarket.us, gates.keys.toList(), forceRefresh: true);
    final sameRequest = repository.fetch(StockMarket.us, gates.keys.toList().reversed.toList(), forceRefresh: true);
    expect(identical(request, sameRequest), true);
    final failed = await request.timeout(const Duration(seconds: 2));
    expect(failed.quotes, isEmpty);
    expect(failed.errors.keys.toSet(), gates.keys.toSet());
    expect(api.dailyCalls, lessThanOrEqualTo(4));
    expect(api.intradayCalls, 0);
    api.dailyGates.clear();
    final recovered = await repository.fetch(StockMarket.us, gates.keys.toList(), forceRefresh: true);
    expect(recovered.quotes.length, 5);
    expect(recovered.errors, isEmpty);
    final intradayCalls = api.intradayCalls;
    for (final entry in gates.entries) { entry.value.complete(_daily(entry.key)); }
    await Future<void>.delayed(Duration.zero);
    expect(api.intradayCalls, intradayCalls);
    repository.close(); api.close();
  });

  test('portfolio timed-out refresh retains stale original quote rather than empty success', () async {
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now, updateBudget: const Duration(milliseconds: 500));
    final initial = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final stale = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    expect(stale.errors['NVDA'], contains('保留上次真實快取'));
    expect(stale.quotes['NVDA']!.isStale, true);
    expect(stale.quotes['NVDA']!.isCached, true);
    expect(stale.quotes['NVDA']!.quoteTimestamp, initial.quotes['NVDA']!.quoteTimestamp);
    expect(stale.quotes['NVDA']!.fetchedAt, initial.quotes['NVDA']!.fetchedAt);
    gate.completeError(StateError('Disconnected after batch was returned.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); api.close();
  });

  test('disposal ends a blocked batch without closing a borrowed market API', () async {
    api.dailyGates['NVDA'] = Completer<MarketChart>();
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final request = repository.fetch(StockMarket.us, adrThreshold: 5);
    final checked = expectLater(request, throwsA(isA<RepositoryException>()));
    await _waitForDailyCalls(api, 1);
    repository.close();
    await checked.timeout(const Duration(seconds: 2));
    api.dailyGates.clear();
    expect((await api.fetchDaily('NVDA', StockMarket.us)).latestPrice, 100);
    api.close(); universe.close();
  });

  test('sealed deadline consumes an already-created operation that fails later', () async {
    final run = LiveBatchDeadline(const Duration(seconds: 1));
    run.seal();
    final late = Completer<int>();
    await expectLater(run.wait(late.future), throwsA(isA<TimeoutException>()));
    late.completeError(StateError('Late response failure must remain observed.'));
    await Future<void>.delayed(Duration.zero);
  });

  test('scan waits for all four stocks and throttles before the next chunk', () async {
    universe = _Universe(['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList(), preferences);
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, batchSize: 4);
    final request = repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4,
        reason: 'A fast worker must not start a fifth stock while another chunk member is pending.');
    expect(api.dailyStarted.keys, ['AAPL', 'AMD', 'META', 'NVDA']);
    expect(api.dailyStarted.containsKey('TSLA'), false);
    gate.complete(_daily('NVDA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.evaluatedCount, 5);
    expect(api.dailyStarted['TSLA']! - api.intradayFinished['NVDA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 145)),
        reason: 'The default 150 ms delay occurs after every stock in the chunk finishes.');
    repository.close(); api.close(); universe.close();
  });

  test('hot quote refresh uses the same complete-chunk barrier and pause', () async {
    universe = _Universe(['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'].map(_stock).toList(), preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, batchSize: 4);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    api.dailyCalls = 0;
    api.dailyStarted.clear();
    api.intradayFinished.clear();
    // Candidate ranking uses symbol order for equal fixture momentum.
    // TSLA is the fifth ranked symbol; gate a member of the first hot chunk.
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final request = repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4);
    expect(api.dailyStarted.containsKey('TSLA'), false);
    gate.complete(_daily('NVDA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.stale, false);
    expect(api.dailyStarted['TSLA']! - api.intradayFinished['NVDA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 145)));
    repository.close(); api.close(); universe.close();
  });

  test('portfolio waits for the entire chunk and limits it to four symbols', () async {
    final gate = Completer<MarketChart>();
    api.dailyGates['TSLA'] = gate;
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now);
    final request = repository.fetch(StockMarket.us,
        ['NVDA', 'TSLA', 'AMD', 'AAPL', 'META'], forceRefresh: true);
    await _waitForDailyCalls(api, 4);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.dailyCalls, 4);
    expect(api.dailyStarted.containsKey('META'), false);
    gate.complete(_daily('TSLA'));
    final snapshot = await request.timeout(const Duration(seconds: 2));
    expect(snapshot.quotes.length, 5);
    expect(snapshot.errors, isEmpty);
    expect(api.dailyStarted['META']! - api.intradayFinished['TSLA']!,
        greaterThanOrEqualTo(const Duration(milliseconds: 95)));
    repository.close(); api.close();
  });

  test('deadline during the inter-chunk pause returns partial data without another request', () async {
    universe = _Universe(['NVDA', 'TSLA'].map(_stock).toList(), preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      scanBudget: const Duration(milliseconds: 150), batchSize: 1,
      interBatchDelay: const Duration(seconds: 5));
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 1));
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols, isEmpty,
        reason: 'TSLA was not started, so it remains queued rather than failed.');
    expect(snapshot.coverageScannedCount, 1);
    expect(snapshot.coverageRemainingCount, 1);
    expect(snapshot.scanCompletedAt, isNull);
    expect(api.dailyStarted.keys, ['NVDA']);
    expect(api.dailyCalls, 1);
    expect(api.intradayCalls, 1);
    repository.close(); api.close(); universe.close();
  });

  test('sealing a run cancels a long inter-chunk pause immediately', () async {
    final run = LiveBatchDeadline(const Duration(seconds: 10));
    final waiting = expectLater(run.pause(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()));
    run.seal();
    await waiting.timeout(const Duration(seconds: 1));
  });

  test('invalid chunk sizes cannot create an unbounded or non-progressing scan', () {
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, batchSize: 0), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, batchSize: 6), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 0), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 31), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, usPageSize: 31), throwsArgumentError);
    expect(() => DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, corePoolSize: 5, usPageSize: 6), throwsArgumentError);
    expect(() => DirectLivePortfolioRepository(api: api, preferences: preferences,
      batchSize: 6), throwsArgumentError);
    api.close(); universe.close();
  });

  test('one provider failure and one RS alignment failure leave healthy recommendations intact', () async {
    universe = _Universe(['BAD', 'TSLA', 'NVDA'].map(_stock).toList(), preferences);
    api.dailyFailures['BAD'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyCharts['TSLA'] = _daily('TSLA', sessionOffsetDays: 2);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates.map((stock) => stock.symbol), ['NVDA']);
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols.toSet(), {'BAD', 'TSLA'});
    final warning = snapshot.warnings.join('\n');
    expect(warning, contains('BAD：Yahoo chart HTTP 403'));
    expect(warning, contains('TSLA：FormatException: RS 資料落差超過一個已知交易日'));
    repository.close(); api.close(); universe.close();
  });

  test('a later healthy stock is still evaluated after twelve invalid stocks', () async {
    final bad = List.generate(12, (index) => 'BAD$index');
    // Sorted pinned membership places HEALTHY after all twelve failures,
    // exercising continued processing of later chunks.
    universe = _Universe([...bad, 'HEALTHY'].map(_stock).toList(), preferences);
    for (final symbol in bad) {
      api.dailyFailures[symbol] = const FormatException('OHLCV 欄位缺漏');
    }
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates.single.symbol, 'HEALTHY');
    expect(snapshot.evaluatedCount, 1);
    expect(snapshot.missingSymbols.length, 12);
    expect(api.dailyCalls, 13);
    expect(snapshot.warnings.join('\n'), contains('其餘 6 檔錯誤摘要已省略'));
    repository.close(); api.close(); universe.close();
  });

  test('all failed stock requests retain provider reasons rather than a generic empty result', () async {
    api.dailyFailures['NVDA'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyFailures['TSLA'] = const FormatException('OHLCV 缺漏');
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final failed = await repository.fetch(StockMarket.us, adrThreshold: 5,
        forceRefresh: true);
    expect(failed.stale, isTrue);
    expect(failed.evaluatedCount, 0);
    expect(failed.candidates, isEmpty);
    expect(failed.scanCompletedAt, isNull);
    expect(failed.coverageScannedCount, 2);
    expect(failed.coverageEvaluatedCount, 0);
    expect(failed.missingSymbols, ['NVDA', 'TSLA']);
    expect(failed.warnings.join('\n'), contains('NVDA：Yahoo chart HTTP 403'));
    expect(failed.warnings.join('\n'), contains('TSLA：FormatException: OHLCV 缺漏'));
    repository.close(); api.close(); universe.close();
  });

  test('successful low-ADR scan returns a valid empty recommendation without relaxing thresholds', () async {
    api.dailyCharts['NVDA'] = _daily('NVDA', lowAdr: true);
    api.dailyCharts['TSLA'] = _daily('TSLA', lowAdr: true);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.missingSymbols, isEmpty);
    expect(snapshot.stale, false);
    expect(snapshot.warnings.join('\n'), contains('零候選為有效結果'));
    expect(api.intradayCalls, 0);
    repository.close(); api.close(); universe.close();
  });

  test('US pages preserve all real members and continue beyond the first thirty', () async {
    final rows = [
      ...List.generate(60, (index) => _stock('S$index')),
      _stock('TSLA'), _stock('AAPL'), _stock('NVDA'),
    ];
    universe = _Universe(rows, preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now,
      interBatchDelay: Duration.zero);
    final ordered = rows.map((row) => row.symbol).toList()..sort();
    final first = await repository.fetch(StockMarket.us, adrThreshold: 5,
      forceRefresh: true);
    expect(first.universeCount, 63);
    expect(first.scanPoolSize, 30);
    expect(first.evaluatedCount, 30);
    expect(first.adrMatchCount, 30);
    expect(first.coverageScannedCount, 30);
    expect(first.coverageRemainingCount, 33);
    expect(api.dailyCalls, 30);
    expect(api.dailyStarted.keys, ordered.take(30));
    expect(first.missingSymbols, isEmpty,
      reason: 'Not-yet-visited directory members are remaining work, not failures.');
    expect(first.warnings.join('\n'), contains('完整名單分批輪掃'));
    expect(first.warnings.join('\n'), contains('RS 為原掃描頁內排名'));

    // Even a quote-refresh tick must advance an unfinished round. No universe
    // reload, duplicate first-page HTTP or fixed core-ceiling is permitted.
    final second = await repository.fetch(StockMarket.us, adrThreshold: 5,
        refreshQuotesOnly: true);
    expect(universe.calls, 1);
    expect(api.dailyCalls, 60);
    expect(api.dailyStarted.keys, ordered.take(60));
    expect(second.scanPageStart, 30);
    expect(second.coverageScannedCount, 60);
    expect(second.coverageRemainingCount, 3);
    expect(second.candidates, hasLength(60));
    expect(second.universeFingerprint, first.universeFingerprint);
    expect(second.candidatesAreCumulative, isTrue);

    final finalPage = await repository.fetch(StockMarket.us, adrThreshold: 5,
        forceRefresh: true);
    expect(universe.calls, 1,
        reason: 'Manual pulls also retain the in-progress round membership.');
    expect(api.dailyCalls, 63);
    expect(api.dailyStarted.keys, ordered);
    expect(finalPage.scanPageStart, 60);
    expect(finalPage.scanPoolSize, 3);
    expect(finalPage.evaluatedCount, 3);
    expect(finalPage.candidates, hasLength(63));
    expect(finalPage.coverageScannedCount, 63);
    expect(finalPage.coverageEvaluatedCount, 63);
    expect(finalPage.coverageRemainingCount, 0);
    expect(finalPage.candidates.every((candidate) => rows.any(
        (row) => row.symbol == candidate.symbol)), isTrue);
    repository.close(); api.close(); universe.close();
  });

  test('TW sorted pages eventually request every current member without a fixed core ceiling', () async {
    StockItem tw(String code) => StockItem(market: StockMarket.tw,
      symbol: '$code.TW', code: code, nameZh: code, nameFullZh: '',
      nameEn: '', abbrEn: '');
    final rows = [
      ...List.generate(34, (index) => tw('${4000 + index}')),
      tw('2603'), tw('2330'), tw('1101'),
    ];
    universe = _Universe(rows, preferences);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, interBatchDelay: Duration.zero);
    final snapshot = await repository.fetch(StockMarket.tw, adrThreshold: 100,
      forceRefresh: true);
    expect(snapshot.universeCount, 37);
    expect(snapshot.scanPoolSize, 30);
    expect(snapshot.evaluatedCount, 30);
    expect(snapshot.adrMatchCount, 0);
    expect(api.dailyStarted.keys.take(3), ['1101.TW', '2330.TW', '2603.TW']);
    expect(api.dailyStarted.containsKey('2454.TW'), false,
      reason: 'Stocks absent from actual membership must not be invented.');
    expect(api.dailyCalls, 30);
    expect(api.intradayCalls, 0);
    expect(snapshot.coverageScannedCount, 30);
    expect(snapshot.coverageRemainingCount, 7);
    expect(snapshot.candidatesAreCumulative, isTrue);
    final next = await repository.fetch(StockMarket.tw, adrThreshold: 100,
      refreshQuotesOnly: true);
    expect(api.dailyCalls, 37);
    expect(api.dailyStarted.keys.toSet(), rows.map((row) => row.symbol).toSet());
    expect(next.scanPoolSize, 7);
    expect(next.coverageScannedCount, 37);
    expect(next.coverageEvaluatedCount, 37);
    expect(next.coverageRemainingCount, 0);
    expect(api.intradayCalls, 0);
    repository.close(); api.close(); universe.close();
  });

  test('batch progress counts failed symbols as completed and isolates observer errors', () async {
    universe = _Universe([
      _stock('NVDA'), _stock('AAPL'), _stock('TSLA'),
      ...List.generate(9, (index) => _stock('X$index')),
    ], preferences);
    api.dailyFailures['AAPL'] = const MarketDataException('HTTP 429', statusCode: 429);
    api.dailyCharts['TSLA'] = _daily('TSLA', lowAdr: true);
    final progress = <MarketScanProgress>[];
    var observerErrors = 0;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now, interBatchDelay: Duration.zero);
    try {
      final snapshot = await repository.fetchWithProgress(StockMarket.us,
        adrThreshold: 5, forceRefresh: true, onProgress: (value) {
          progress.add(value);
          if (value.completedCount == 5) {
            observerErrors++;
            throw StateError('Faulty UI observer');
          }
        });
      // Validated daily data is published per stock, then may be updated by
      // intraday data and a batch boundary. Do not require exactly one event
      // per batch: that would reject useful partial data while a sibling waits.
      final completed = progress
          .where((row) => !row.finished && row.completedCount > 0)
          .map((row) => row.completedCount).toList();
      expect(completed, containsAllInOrder([5, 10, 12]),
          reason: 'Every completed batch must still be reported in order.');
      expect(progress.any((row) => !row.finished &&
          row.completedCount > 0 && row.completedCount < 5 &&
          row.partialSnapshot != null), isTrue,
          reason: 'Validated observations must be visible before the first batch finishes.');
      for (var index = 1; index < progress.length; index++) {
        expect(progress[index].completedCount,
            greaterThanOrEqualTo(progress[index - 1].completedCount),
            reason: 'Daily/intraday updates must not double-count or rewind progress.');
        expect(progress[index].attemptedCount,
            greaterThanOrEqualTo(progress[index - 1].attemptedCount));
      }
      for (final row in progress) {
        expect(row.completedCount, row.evaluatedCount + row.failedCount,
            reason: 'A failed symbol is completed work, never a successful evaluation.');
        expect(row.completedCount, inInclusiveRange(0, row.attemptedCount));
        expect(row.attemptedCount, inInclusiveRange(0, row.poolSize));
        expect(row.adrMatchCount, inInclusiveRange(0, row.evaluatedCount));
      }
      expect(observerErrors, greaterThan(0),
          reason: 'The faulty observer must actually run before testing isolation.');
      expect(progress.where((row) => row.finished), hasLength(1));
      final finished = progress.last;
      expect(finished.finished, true);
      expect(finished.attemptedCount, 12);
      expect(finished.completedCount, 12);
      expect(finished.evaluatedCount, 11);
      expect(finished.failedCount, 1);
      expect(finished.adrMatchCount, 10);
      expect(finished.fraction, 1);
      expect(finished.label, contains('已掃描 12/12 檔'));
      expect(snapshot.adrMatchCount, 10);
      expect(snapshot.candidates.length, 10);
      expect(snapshot.missingSymbols, ['AAPL']);
    } finally {
      repository.close(); api.close(); universe.close();
    }
  });

  test('disposed progressive scan does not commit or notify after a late response', () async {
    final gate = Completer<MarketChart>();
    api.dailyGates['NVDA'] = gate;
    final progress = <MarketScanProgress>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final request = repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: progress.add);
    final checked = expectLater(request, throwsA(isA<RepositoryException>()));
    await _waitForDailyCalls(api, 2);
    repository.close();
    final journalAtClose = preferences.getString('martin-mobile-us-rolling-v1-5.0');
    await checked.timeout(const Duration(seconds: 2));
    final countAtClose = progress.length;
    final intradayAtClose = api.intradayCalls;
    gate.complete(_daily('NVDA'));
    await Future<void>.delayed(Duration.zero);
    expect(progress.length, countAtClose);
    expect(api.intradayCalls, intradayAtClose);
    expect(preferences.getString('martin-mobile-us-rolling-v1-5.0'), journalAtClose,
        reason: 'Late workers must not overwrite the prefix saved before disposal.');
    api.close(); universe.close();
  });

  test('all-failed US page finishes stale with errors and keeps a resumable journal', () async {
    api.dailyFailures['NVDA'] = const MarketDataException('HTTP 403', statusCode: 403);
    api.dailyFailures['TSLA'] = const FormatException('OHLCV missing');
    final progress = <MarketScanProgress>[];
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final failed = await repository.fetchWithProgress(StockMarket.us,
      adrThreshold: 5, forceRefresh: true, onProgress: progress.add);
    expect(failed.stale, isTrue);
    expect(failed.scanCompletedAt, isNull);
    expect(failed.evaluatedCount, 0);
    expect(failed.candidates, isEmpty);
    expect(failed.coverageScannedCount, 2);
    expect(failed.coverageEvaluatedCount, 0);
    expect(failed.missingSymbols, ['NVDA', 'TSLA']);
    expect(failed.warnings.join('\n'), contains('不是成功的零候選結果'));
    expect(failed.warnings.join('\n'), contains('NVDA：HTTP 403'));
    expect(failed.warnings.join('\n'), contains('TSLA：FormatException: OHLCV missing'));
    expect(progress.last.finished, true);
    expect(progress.last.failedCount, 2);
    expect(progress.last.completedCount, 2);
    expect(progress.last.partialSnapshot!.stale, isTrue);
    final journal = jsonDecode(preferences.getString(
        'martin-mobile-us-rolling-v1-5.0')!) as Map;
    expect(journal['attempted'], ['NVDA', 'TSLA']);
    expect(journal['evaluated'], isEmpty);
    expect(journal['page_stale'], isTrue);
    repository.close(); api.close(); universe.close();
  });

  test('daily evaluation is preserved and a missing intraday quote gives its own cause', () async {
    api.intradayFailures['TSLA'] = const MarketDataException('Intraday HTTP 429', statusCode: 429);
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.missingSymbols, isEmpty);
    expect(snapshot.candidates.singleWhere((stock) => stock.symbol == 'TSLA').isConfirmed, false);
    expect(snapshot.warnings.join('\n'), contains('TSLA：Intraday HTTP 429'));
    repository.close(); api.close(); universe.close();
  });

  test('hot quote errors preserve the actual failing symbol and HTTP status', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    api.dailyFailures['TSLA'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(snapshot.stale, true);
    expect(snapshot.candidates.length, 2);
    expect(snapshot.warnings.join('\n'), contains('TSLA：Yahoo chart HTTP 403'));
    repository.close(); api.close(); universe.close();
  });

  test('portfolio invalid EMA and provider data do not discard a healthy quote or mask their causes', () async {
    api.dailyFailures['BAD'] = const MarketDataException('Yahoo chart HTTP 403', statusCode: 403);
    api.dailyCharts['TSLA'] = _daily('TSLA', count: 30);
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences,
      now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, ['BAD', 'TSLA', 'NVDA'], forceRefresh: true);
    expect(snapshot.quotes.keys, ['NVDA']);
    expect(snapshot.errors['BAD'], contains('HTTP 403'));
    expect(snapshot.errors['BAD'], isNot(contains('逾時')));
    expect(snapshot.errors['TSLA'], contains('EMA'));
    expect(snapshot.errors['TSLA'], isNot(contains('逾時')));
    repository.close(); api.close();
  });

  test('one wrongly typed cache key cannot discard another genuinely cached holding', () async {
    final seed = DirectLivePortfolioRepository(api: api, preferences: preferences, now: () => _now);
    final initial = await seed.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    seed.close();
    await preferences.setInt('martin-live-holding-v1-us-TSLA', 42);
    api.fail = true;
    final repository = DirectLivePortfolioRepository(api: api, preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, ['NVDA', 'TSLA'], forceRefresh: true);
    expect(snapshot.quotes['NVDA']!.isStale, true);
    expect(snapshot.quotes['NVDA']!.quoteTimestamp, initial.quotes['NVDA']!.quoteTimestamp);
    expect(snapshot.errors['NVDA'], contains('保留上次真實快取'));
    expect(snapshot.errors['NVDA'], contains('Network unavailable'));
    expect(snapshot.errors['TSLA'], contains('Network unavailable'));
    expect(snapshot.errors['TSLA'], isNot(contains('逾時')));
    repository.close(); api.close();
  });

  test('cold membership timeout falls back early enough to scan real HTTP parser fixtures', () async {
    final stalled = Completer<http.Response>();
    final membershipClient = MockClient((_) => stalled.future);
    final members = StockUniverseService(client: membershipClient,
      preferences: preferences, now: () => _now,
      requestTimeout: const Duration(milliseconds: 40),
      storageTimeout: const Duration(milliseconds: 100));
    final chartRequests = <String>[];
    final chartClient = MockClient((request) async {
      final symbol = request.url.pathSegments.last;
      final interval = request.url.queryParameters['interval']!;
      chartRequests.add('$symbol:$interval');
      return http.Response(jsonEncode(_chartDocument(symbol, interval)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final realApi = MarketDataApi(client: chartClient, preferences: preferences, now: () => _now);
    final repository = DirectLiveCandidateRepository(api: realApi, universe: members,
      preferences: preferences, now: () => _now, scanBudget: const Duration(milliseconds: 300));
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true)
        .timeout(const Duration(seconds: 2));
    expect(chartRequests, contains('^GSPC:1d'));
    expect(snapshot.evaluatedCount, greaterThan(0));
    expect(snapshot.candidates, isNotEmpty);
    expect(snapshot.candidates.first.adrPercent, closeTo(8.3333333333, .000001));
    expect(snapshot.universeCount, greaterThan(snapshot.evaluatedCount!));
    expect(snapshot.universeIsComplete, false);
    expect(snapshot.warnings.join('\n'), contains('僅使用內建'));
    expect(snapshot.warnings.join('\n'), contains('不是目前完整'));
    expect(snapshot.coverageScannedCount, greaterThan(0));
    expect(snapshot.coverageRemainingCount, greaterThan(0));
    expect(snapshot.coverageScannedCount! + snapshot.coverageRemainingCount!,
        snapshot.universeCount,
        reason: 'Unvisited fallback members remain queued instead of being provider failures.');
    // An eventual membership reply cannot turn the already-published partial
    // snapshot into a fabricated, fully refreshed constituent list.
    stalled.completeError(StateError('Late membership failure after fallback.'));
    await Future<void>.delayed(Duration.zero);
    repository.close(); realApi.close(); members.close();
    chartClient.close(); membershipClient.close();
    api.close(); universe.close();
  });
}
