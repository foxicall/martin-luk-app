import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

/// Real HTTPS verification; not a deterministic replacement for unit tests.
///
/// flutter test test/integration_scan_test.dart \
///   --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false
///
/// A closed market, no valid setup, provider throttling, or a missing required
/// quote FAILS this gate. No quote, stop, timestamp or signal is fabricated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Only platform persistence is replaced. Market HTTP requests remain real.
  SharedPreferences.setMockInitialValues({});

  const runLive =
      bool.fromEnvironment('RUN_LIVE_SCAN_TEST', defaultValue: false);

  test('real TW/US scan produces a strictly qualified and sized entry', () async {
    final elapsed = Stopwatch()..start();
    final evidence = <String, dynamic>{
      'status': 'running',
      'started_at_utc': DateTime.now().toUtc().toIso8601String(),
      'provider': 'Yahoo Finance HTTPS chart; actual HTTP client',
      'scope': 'curated partial TW/US probe, not a complete-universe scan',
      'maximum_concurrent_stock_tasks': 5,
      'inter_chunk_delay_ms': 100,
      'whole_run_deadline_seconds': 15,
      'observations': <Map<String, dynamic>>[],
      'errors': <String, String>{},
      'candidates': <Map<String, dynamic>>[],
    };

    final output = File('build/live-scan-evidence.json');
    output.parent.createSync(recursive: true);
    _writeEvidence(output, evidence);

    final previousOverrides = HttpOverrides.current;
    MarketDataApi? api;
    final run = _LiveRun(elapsed);
    Object? failure;
    StackTrace? failureStack;

    try {
      expect(
        AppConfig.useMockData,
        isFalse,
        reason: 'Live gate requires USE_MOCK_DATA=false.',
      );

      // Remove Flutter test binding's HTTP-400 override.
      HttpOverrides.global = null;

      final preferences = await run.wait(SharedPreferences.getInstance());
      api = MarketDataApi(preferences: preferences);
      await run.wait(_scan(api, run, evidence));
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Late futures must not mutate the report or publish PASS.
      run.cancel();
      api?.close();
      HttpOverrides.global = previousOverrides;
    }

    if (elapsed.elapsed > const Duration(seconds: 15)) {
      failure ??= StateError('Real scan exceeded the strict 15-second deadline.');
      failureStack ??= StackTrace.current;
    }

    evidence['finished_at_utc'] = DateTime.now().toUtc().toIso8601String();
    evidence['elapsed_ms'] = elapsed.elapsedMilliseconds;
    evidence['status'] = failure == null ? 'passed' : 'failed';
    if (failure != null) {
      evidence['failure'] = failure.toString();
    }
    _writeEvidence(output, evidence);

    elapsed.stop();
    if (elapsed.elapsed > const Duration(seconds: 15) && failure == null) {
      failure = StateError('Live scan/report cleanup exceeded 15 seconds.');
      failureStack = StackTrace.current;
      evidence['status'] = 'failed';
      evidence['failure'] = failure.toString();
      evidence['elapsed_ms'] = elapsed.elapsedMilliseconds;
      _writeEvidence(output, evidence);
    }

    stdout.writeln(jsonEncode(evidence));

    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }

    stdout.writeln(
      '[TEST PASSED] Successfully refreshed and generated candidates: '
      '${jsonEncode(evidence['candidates'])}',
    );
  },
      skip: runLive
          ? false
          : 'Explicit RUN_LIVE_SCAN_TEST=true is required; '
              'no live gate runs in offline unit tests.',
      timeout: const Timeout(Duration(seconds: 20)));
}

class _LiveRun {
  _LiveRun(this.elapsed);

  final Stopwatch elapsed;
  bool _cancelled = false;

  // Reserve 250 ms for disposal and writing diagnostics.
  Duration get remaining =>
      const Duration(milliseconds: 14750) - elapsed.elapsed;

  bool get active => !_cancelled && remaining > Duration.zero;

  void cancel() {
    _cancelled = true;
  }

  void check() {
    if (!active) {
      throw TimeoutException('Real market scan deadline reached.');
    }
  }

  Future<T> wait<T>(Future<T> operation) {
    if (!active) {
      // Observe late completion, including errors.
      operation.ignore();
      check();
    }
    return operation.timeout(remaining);
  }
}

void _writeEvidence(File output, Map<String, dynamic> evidence) {
  output.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(evidence),
  );
}

Future<void> _scan(
  MarketDataApi api,
  _LiveRun run,
  Map<String, dynamic> evidence,
) async {
  const engine = LiveStrategyEngine();
  final observations =
      evidence['observations'] as List<Map<String, dynamic>>;
  final errors = evidence['errors'] as Map<String, String>;
  final evaluations = <LiveEvaluation>[];
  final stocks = <String, StockItem>{};

  final decoded =
      jsonDecode(await run.wait(rootBundle.loadString('stocks_master.json')));
  if (decoded is! List) {
    throw const FormatException('Stock dictionary is not an array.');
  }

  for (final row in decoded) {
    final stock = StockItem.fromJson(row as Map<String, dynamic>);
    stocks[stock.symbol] = stock;
  }

  final benchmarks = <StockMarket, MarketChart>{};

  await run.wait(Future.wait(StockMarket.values.map((market) async {
    final chart =
        await run.wait(api.fetchBenchmark(market, forceRefresh: true));
    run.check();
    _assertRealDaily(chart, market);
    benchmarks[market] = chart;
    observations.add(_dailyEvidence(chart, engine, kind: 'benchmark'));
  })));

  expect(
    benchmarks.length,
    2,
    reason: 'Both actual TWII and GSPC are required.',
  );

  const symbols = [
    'NVDA', 'AAPL', 'TSLA', '2330.TW', '2603.TW',
    'AMD', 'PLTR', 'SMCI', '3017.TW', '1519.TW',
    'COIN', 'APP', 'MU', '2383.TW', '3661.TW',
    'CRWD', 'AVGO', 'META', '3443.TW', '2049.TW',
    'PANW', 'SHOP', '6669.TW', '6139.TW', '3035.TW',
    '2368.TW', '2376.TW', '1503.TW', '6278.TW',
  ];
  const requiredSymbols = ['NVDA', 'AAPL', 'TSLA', '2330.TW', '2603.TW'];

  evidence['probe_symbols'] = symbols;

  for (final symbol in symbols) {
    expect(
      stocks.containsKey(symbol),
      isTrue,
      reason: 'A real dictionary identity is required for $symbol.',
    );
  }

  Future<void> probe(String symbol) async {
    final stock = stocks[symbol]!;

    try {
      final daily = await run.wait(
        api.fetchDaily(symbol, stock.market, forceRefresh: true),
      );
      run.check();
      _assertRealDaily(daily, stock.market);

      final observation = _dailyEvidence(daily, engine, kind: 'stock');
      observations.add(observation);
      final adr = observation['adr_20_percent'] as double;

      MarketChart? intraday;
      String? intradayError;

      if (adr >= stock.market.defaultAdr) {
  try {
    final MarketChart fetchedIntraday = await run.wait<MarketChart>(
      api.fetchIntraday(
        symbol,
        stock.market,
        forceRefresh: true,
      ),
    );

    run.check();

    expect(fetchedIntraday.isCached, isFalse);
    expect(fetchedIntraday.isStale, isFalse);

    observation['intraday_quote_at_utc'] =
        fetchedIntraday.quoteTimestamp.toIso8601String();

    observation['quote_in_regular_session'] =
        fetchedIntraday.quoteIsInRegularSession;

    observation['quote_fresh_15m'] =
        fetchedIntraday.isQuoteFresh(DateTime.now().toUtc());

    intraday = fetchedIntraday;
  } catch (error) {
    if (!run.active) return;

    intradayError = error.toString();
    observation['intraday_error'] = intradayError;
  }
}

      run.check();

      final evaluation = engine.evaluate(
        stock: stock,
        data: ChartBundle(
          daily: daily,
          intraday: intraday,
          intradayError: intradayError,
        ),
        benchmark: benchmarks[stock.market]!,
        now: DateTime.now().toUtc(),
      );

      observation['patterns'] = evaluation.patterns;
      observation['rs_raw_excess_percent'] = evaluation.momentum;
      observation['has_confirmed_observed_stop'] = evaluation.stop != null;
      evaluations.add(evaluation);
    } catch (error) {
      if (run.active) {
        errors[symbol] = error.toString();
      }
    }
  }

  for (var start = 0; start < symbols.length && run.active; start += 5) {
    final chunk = symbols.skip(start).take(5);
    await run.wait(Future.wait(chunk.map(probe)));

    final requiredComplete = requiredSymbols.every(
      (symbol) => evaluations.any((row) => row.stock.symbol == symbol),
    );

    if (requiredComplete && evaluations.any(_qualifies)) {
      evidence['stopped_after_sufficient_real_evidence'] =
          start + 5 < symbols.length;
      break;
    }

    if (start + 5 < symbols.length) {
      await run.wait(
        Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
  }

  run.check();

  for (final symbol in requiredSymbols) {
    expect(
      evaluations.any((row) => row.stock.symbol == symbol),
      isTrue,
      reason: 'Required real quote/ADR/EMA/RS evaluation failed '
          'for $symbol: ${errors[symbol]}',
    );
  }

  final qualified = <Map<String, dynamic>>[];

  for (final market in StockMarket.values) {
    final ranked = engine.rank(
      evaluations.where((row) => row.stock.market == market).toList(),
    );

    for (final candidate in ranked) {
      final evaluation = evaluations.firstWhere(
        (row) => row.stock.symbol == candidate.symbol,
      );

      if (!_qualifies(evaluation) ||
          !candidate.isConfirmed ||
          !candidate.hasValidStopRange) {
        continue;
      }

      _assertBreakoutEvidence(evaluation, candidate);

      final capital = market.defaultEquity;
      final plan = calculatePositionSize(
        capital: capital,
        entryPrice: candidate.entryPrice,
        stopLossPrice: candidate.stopPrice!,
        isMegaCap: candidate.isLargeLiquid,
      );
      final targets =
          calculateExitTargets(candidate.entryPrice, candidate.stopPrice!);

      expect(plan.shares, greaterThan(0));
      expect(plan.riskAmount, lessThanOrEqualTo(capital * .005 + 1e-8));
      expect(
        plan.positionPercent,
        lessThanOrEqualTo((candidate.isLargeLiquid ? 35 : 25) + 1e-8),
      );
      expect(plan.riskBudget, capital * .005);

      for (final r in [3, 5, 10]) {
        expect(plan.targetPrice(r), closeTo(targets.targetPrice(r), 1e-8));
        expect(
          targets.targetPrice(r),
          closeTo(
            candidate.entryPrice +
                r * (candidate.entryPrice - candidate.stopPrice!),
            1e-8,
          ),
        );
      }

      qualified.add({
        ...candidate.toJson(),
        'account_capital': capital,
        'account_currency': market.currency,
        'risk_budget': plan.riskBudget,
        'actual_stop_risk': plan.riskAmount,
        'shares': plan.shares,
        'position_percent': plan.positionPercent,
        'target_3r': targets.targetPrice(3),
        'target_5r': targets.targetPrice(5),
        'target_10r': targets.targetPrice(10),
        'intraday_source': evaluation.data.intraday!.source,
        'intraday_is_cached': false,
        'intraday_is_stale': false,
      });
    }
  }

  evidence['candidates'] = qualified;
  evidence['evaluated_count'] = evaluations.length;

  expect(
    qualified,
    isNotEmpty,
    reason: 'NO ACTUAL QUALIFIED ENTRY: ADR thresholds, EMA compression, '
        'fresh regular-session PDH/ORH confirmation and observed '
        '1.5%–3% stop must all hold. Closed sessions/no setup/provider '
        'limits must fail this gate; no synthetic substitute is allowed.',
  );
}

bool _qualifies(LiveEvaluation row) {
  final stop = row.stop;

  if (stop == null ||
      row.adr < row.stock.market.defaultAdr ||
      !row.patterns.contains('EMA 9/21/50 收斂') ||
      !row.patterns.contains('${row.triggerType} 突破')) {
    return false;
  }

  final risk = (row.trigger - stop) / row.trigger * 100;
  return risk >= 1.5 && risk <= 3;
}

void _assertRealDaily(MarketChart chart, StockMarket market) {
  expect(chart.market, market);
  expect(chart.currency, market.currency);
  expect(chart.isCached, isFalse);
  expect(chart.isStale, isFalse);
  expect(chart.cacheWarning, isNull);
  expect(chart.latestPrice.isFinite, isTrue);
  expect(chart.latestPrice, greaterThan(0));
  expect(chart.completedDailyBars.length, greaterThanOrEqualTo(61));
  expect(chart.source, contains('Yahoo Finance'));
  expect(
    RegExp(r'mock|fictitious|demo|示範|假', caseSensitive: false)
        .hasMatch(chart.source),
    isFalse,
  );

  final now = DateTime.now().toUtc();
  expect(chart.quoteTimestamp.isAfter(now), isFalse);
  expect(
    now.difference(chart.quoteTimestamp),
    lessThan(const Duration(days: 7)),
    reason: 'Latest available daily quote must not be obsolete.',
  );
}

Map<String, dynamic> _dailyEvidence(
  MarketChart chart,
  LiveStrategyEngine engine, {
  required String kind,
}) {
  final bars = chart.completedDailyBars;
  final closes = bars.map((bar) => bar.close).toList();
  final adr = engine.adrPercent(bars);
  final manualAdr = bars.skip(bars.length - 20).fold<double>(
        0,
        (sum, bar) => sum + (bar.high - bar.low) / bar.low * 100,
      ) /
      20;

  expect(adr.isFinite, isTrue);
  expect(adr, greaterThanOrEqualTo(0));
  expect(adr, closeTo(manualAdr, 1e-9));

  final ema9 = engine.ema(closes, 9);
  final ema21 = engine.ema(closes, 21);
  final ema50 = engine.ema(closes, 50);

  for (final ema in [ema9, ema21, ema50]) {
    expect(ema.isFinite, isTrue);
    expect(ema, greaterThan(0));
  }

  return {
    'kind': kind,
    'symbol': chart.symbol,
    'market': chart.market.name,
    'currency': chart.currency,
    'provider_price': chart.latestPrice,
    'provider_quote_at_utc': chart.quoteTimestamp.toIso8601String(),
    'request_finished_at_utc': chart.fetchedAt.toIso8601String(),
    'completed_daily_bars': bars.length,
    'adr_20_percent': adr,
    'ema_9': ema9,
    'ema_21': ema21,
    'ema_50': ema50,
    'source': chart.source,
    'is_cached': chart.isCached,
    'is_stale': chart.isStale,
  };
}

void _assertBreakoutEvidence(
  LiveEvaluation evaluation,
  StockCandidate candidate,
) {
  final intraday = evaluation.data.intraday!;
  final daily = evaluation.data.daily.completedDailyBars;
  final closes = daily.map((bar) => bar.close).toList();
  final emas = [evaluation.ema9, evaluation.ema21, evaluation.ema50];

  expect(
    (emas.reduce(math.max) - emas.reduce(math.min)) / daily.last.close,
    lessThanOrEqualTo(.025),
  );
  expect(daily.last.close, greaterThanOrEqualTo(emas.reduce(math.max)));
  expect(
    _standardDeviation(closes.sublist(closes.length - 7)),
    lessThanOrEqualTo(
      _standardDeviation(closes.sublist(closes.length - 20)) * .8,
    ),
  );

  expect(intraday.quoteIsInRegularSession, isTrue);
  expect(intraday.isQuoteFresh(DateTime.now().toUtc()), isTrue);
  expect(candidate.patterns, contains('${candidate.triggerType} 突破'));

  final regular = intraday.regularSessionBars
      .where((bar) => !bar.closeTimestamp.isAfter(intraday.quoteTimestamp))
      .toList();

  expect(regular, isNotEmpty);
  expect(regular.first.timestamp, intraday.regularSessionStart);

  final i = regular.indexWhere(
    (bar) => bar.closeTimestamp == candidate.signalTimestamp,
  );
  expect(i, greaterThanOrEqualTo(0));

  final breakout = regular[i];
  final before = i == 0 ? breakout.open : regular[i - 1].close;

  expect(before, lessThanOrEqualTo(candidate.triggerPrice));
  expect(breakout.close, greaterThan(candidate.triggerPrice));
  expect(candidate.confirmationPrice, breakout.close);

  for (var cursor = 1; cursor <= i; cursor++) {
    expect(regular[cursor].timestamp, regular[cursor - 1].closeTimestamp);
  }

  final observedLow =
      regular.take(i + 1).map((bar) => bar.low).reduce(math.min);
  expect(candidate.dayLow, observedLow);
  expect(candidate.entryBarLow, breakout.low);

  if (candidate.triggerType == 'PDH') {
    expect(candidate.triggerPrice, daily.last.high);

    final prior = daily.last;
    final earlier = daily[daily.length - 2];
    final averageRange = daily.skip(daily.length - 20).fold<double>(
          0,
          (sum, bar) => sum + bar.high - bar.low,
        ) /
        20;

    expect(
      (prior.high <= earlier.high && prior.low >= earlier.low) ||
          prior.high - prior.low <= averageRange * .6,
      isTrue,
      reason: 'PDH requires a real inside day or narrow prior range.',
    );
  } else {
    expect(candidate.triggerType, 'ORH');
    expect(i, greaterThan(0));
    expect(candidate.triggerPrice, regular.first.high);

    final previousClose = daily.last.close;
    final averageVolume = daily.skip(daily.length - 20).fold<double>(
          0,
          (sum, bar) => sum + bar.volume,
        ) /
        20;

    final sessionMinutes = intraday.regularSessionEnd!
        .difference(intraday.regularSessionStart!)
        .inMinutes;
    final elapsedMinutes = breakout.closeTimestamp
        .difference(intraday.regularSessionStart!)
        .inMinutes;

    final expectedVolume =
        averageVolume * elapsedMinutes / sessionMinutes;
    final observedVolume = regular.take(i + 1).fold<double>(
          0,
          (sum, bar) => sum + bar.volume,
        );

    expect(
      (regular.first.open / previousClose - 1) * 100,
      greaterThanOrEqualTo(2),
    );
    expect(expectedVolume, greaterThan(0));
    expect(
      observedVolume,
      greaterThanOrEqualTo(expectedVolume * 1.5),
    );
  }

  expect(
    candidate.stopPrice,
    candidate.stopSource == 'day_low' ? observedLow : breakout.low,
  );
}

double _standardDeviation(List<double> values) {
  final mean =
      values.fold<double>(0, (sum, value) => sum + value) / values.length;
  final variance = values.fold<double>(
        0,
        (sum, value) => sum + (value - mean) * (value - mean),
      ) /
      values.length;
  return math.sqrt(variance);
}
