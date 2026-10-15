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

/// Real HTTPS health gate; not a deterministic replacement for unit tests.
///
/// flutter test test/integration_scan_test.dart \
///   --dart-define=RUN_LIVE_SCAN_TEST=true --dart-define=USE_MOCK_DATA=false
///
/// Both real benchmarks and all five required stocks must pass independent
/// ADR/EMA/RS checks. Zero qualified entries is a valid market outcome; data,
/// calculation and deadline failures still fail this gate. No market data or
/// entry is fabricated, and the entry strategy's thresholds remain unchanged.
const _requiredSymbols = ['NVDA', 'AAPL', 'TSLA', '2330.TW', '2603.TW'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Initialize the storage test adapter only after Flutter's binding exists.
  // This replaces platform persistence, not the real Yahoo HTTP client.
  SharedPreferences.setMockInitialValues({});
  const runLive = bool.fromEnvironment('RUN_LIVE_SCAN_TEST', defaultValue: false);
  test('real TW/US market data and independent indicator health gate', () async {
    final elapsed = Stopwatch()..start();
    final evidence = <String, dynamic>{
      'schema_version': 2,
      'verification_mode': 'real_market_health',
      'use_mock_data': AppConfig.useMockData,
      'status': 'running',
      'started_at_utc': DateTime.now().toUtc().toIso8601String(),
      'provider': 'Yahoo Finance HTTPS chart; actual HTTP client',
      'scope': 'five required TW/US health probes, not a complete-universe recommendation scan',
      'maximum_concurrent_stock_tasks': 5,
      'inter_chunk_delay_ms': 100,
      'whole_run_deadline_seconds': 15,
      'required_symbols': _requiredSymbols,
      'benchmarks_verified': false,
      'required_symbols_verified': false,
      'indicators_verified': false,
      'candidate_count': 0,
      'recommendation_status': 'not_evaluated',
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
      expect(AppConfig.useMockData, isFalse,
          reason: 'Live gate requires USE_MOCK_DATA=false.');
      // Only persistent platform storage is isolated. There is no MockClient,
      // injected response, stored price, cached-success fixture or API relay.
      HttpOverrides.global = null; // Remove Flutter test binding's HTTP-400 override.
      final preferences = await run.wait(SharedPreferences.getInstance());
      api = MarketDataApi(preferences: preferences);
      await run.wait(_scan(api, run, evidence));
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Seal first: abandoned futures cannot mutate the report or publish PASS.
      run.cancel();
      api?.close();
      HttpOverrides.global = previousOverrides;
    }
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      failure ??= StateError('Real scan exceeded the strict 15-second deadline.');
      failureStack ??= StackTrace.current;
    }
    _recordFilterSummary(evidence,
        evidence['observations'] as List<Map<String, dynamic>>);
    evidence['finished_at_utc'] = DateTime.now().toUtc().toIso8601String();
    evidence['elapsed_ms'] = elapsed.elapsedMilliseconds;
    evidence['status'] = failure == null ? 'passed' : 'failed';
    if (failure != null) evidence['failure'] = failure.toString();
    _writeEvidence(output, evidence);
    // Include writing the report, disposal and override restoration in the
    // whole-run deadline; a late artifact cannot be reported as a passed gate.
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
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    stdout.writeln('[TEST PASSED] Real TW/US data and ADR/EMA/RS verified; '
        'qualified recommendations: ${evidence['candidate_count']}. '
        '${evidence['candidate_count'] == 0 ? 'No current qualified entry; no trade is recommended.' : jsonEncode(evidence['candidates'])}');
  }, skip: runLive ? false :
      'Explicit RUN_LIVE_SCAN_TEST=true is required; no live gate runs in offline unit tests.',
    timeout: const Timeout(Duration(seconds: 20)));
}

class _LiveRun {
  _LiveRun(this.elapsed);
  final Stopwatch elapsed;
  bool _cancelled = false;

  // Reserve 250 ms for synchronous HTTP disposal and writing diagnostics.
  Duration get remaining => const Duration(milliseconds: 14750) - elapsed.elapsed;
  bool get active => !_cancelled && remaining > Duration.zero;
  void cancel() { _cancelled = true; }
  void check() {
    if (!active) throw TimeoutException('Real market scan deadline reached.');
  }
  Future<T> wait<T>(Future<T> operation) {
    if (!active) {
      // Arguments may already have started an asynchronous operation. Observe
      // its completion even when the run expired immediately before this call.
      operation.ignore();
      check();
    }
    return operation.timeout(remaining);
  }
}

void _writeEvidence(File output, Map<String, dynamic> evidence) {
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
}

Future<void> _scan(MarketDataApi api, _LiveRun run,
    Map<String, dynamic> evidence) async {
  const engine = LiveStrategyEngine();
  final observations = evidence['observations'] as List<Map<String, dynamic>>;
  final errors = evidence['errors'] as Map<String, String>;
  final evaluations = <LiveEvaluation>[];
  final stocks = <String, StockItem>{};
  final decoded = jsonDecode(await run.wait(rootBundle.loadString('stocks_master.json')));
  if (decoded is! List) throw const FormatException('Stock dictionary is not an array.');
  for (final row in decoded) {
    final stock = StockItem.fromJson(row as Map<String, dynamic>);
    stocks[stock.symbol] = stock;
  }
  final benchmarks = <StockMarket, MarketChart>{};
  await run.wait(Future.wait(StockMarket.values.map((market) async {
    final chart = await run.wait(api.fetchBenchmark(market, forceRefresh: true));
    run.check();
    _assertRealDaily(chart, market);
    benchmarks[market] = chart;
    observations.add(_dailyEvidence(chart, engine, kind: 'benchmark'));
  })));
  expect(benchmarks.length, 2, reason: 'Both actual TWII and GSPC are required.');

  // This gate verifies actual data and calculations for a fixed sample. It
  // does not assert that a qualified trade exists, nor replace the App's scan.
  const symbols = _requiredSymbols;
  evidence['probe_symbols'] = symbols;
  for (final symbol in symbols) {
    expect(stocks.containsKey(symbol), isTrue,
        reason: 'A real dictionary identity is required for $symbol.');
  }
  Future<void> probe(String symbol) async {
    final stock = stocks[symbol]!;
    Map<String, dynamic>? currentObservation;
    try {
      final daily = await run.wait(api.fetchDaily(symbol, stock.market, forceRefresh: true));
      run.check();
      _assertRealDaily(daily, stock.market);
      final observation = _dailyEvidence(daily, engine, kind: 'stock');
      currentObservation = observation;
      observations.add(observation);
      final adr = observation['adr_20_percent'] as double;
      MarketChart? intraday;
      String? intradayError;
      if (adr >= stock.market.defaultAdr) {
        try {
          final MarketChart fetchedIntraday = await run.wait<MarketChart>(
            api.fetchIntraday(symbol, stock.market, forceRefresh: true),
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
      final evaluation = engine.evaluate(stock: stock,
          data: ChartBundle(daily: daily, intraday: intraday, intradayError: intradayError),
          benchmark: benchmarks[stock.market]!, now: DateTime.now().toUtc());
      observation['patterns'] = evaluation.patterns;
      observation['rs_raw_excess_percent'] = evaluation.momentum;
      observation['rs_alignment_notes'] = evaluation.notes
          .where((note) => note.startsWith('RS 計算截至') || note.contains('日 K 落後'))
          .toList();
      observation['has_confirmed_observed_stop'] = evaluation.stop != null;
      _recordEvaluationEvidence(observation, evaluation, benchmarks[stock.market]!,
          DateTime.now().toUtc());
      evaluations.add(evaluation);
    } catch (error) {
      if (run.active) {
        errors[symbol] = error.toString();
        final failedObservation = currentObservation ?? <String, dynamic>{
          'kind': 'stock', 'symbol': symbol, 'market': stock.market.name,
        };
        failedObservation['evaluation_verified'] = false;
        failedObservation['evaluation_error'] = error.toString();
        failedObservation['all_rejection_reasons'] = ['DATA_OR_CALCULATION_ERROR'];
        if (currentObservation == null) observations.add(failedObservation);
      }
    }
  }

  for (var start = 0; start < symbols.length && run.active; start += 5) {
    final chunk = symbols.skip(start).take(5);
    await run.wait(Future.wait(chunk.map(probe)));
    final requiredComplete = _requiredSymbols.every((symbol) =>
        evaluations.any((row) => row.stock.symbol == symbol));
    if (requiredComplete) {
      evidence['stopped_after_required_health_checks'] = true;
      break;
    }
    if (start + 5 < symbols.length) {
      await run.wait(Future<void>.delayed(const Duration(milliseconds: 100)));
    }
  }
  run.check();
  for (final symbol in _requiredSymbols) {
    expect(evaluations.any((row) => row.stock.symbol == symbol), isTrue,
        reason: 'Required real quote/ADR/EMA/RS evaluation failed for $symbol: ${errors[symbol]}');
  }
  final qualified = <Map<String, dynamic>>[];
  // Each market ranks its own observed sample; USD and TWD are never combined.
  for (final market in StockMarket.values) {
    final ranked = engine.rank(evaluations.where((row) => row.stock.market == market).toList());
    for (final candidate in ranked) {
      final evaluation = evaluations.firstWhere((row) => row.stock.symbol == candidate.symbol);
      if (!_qualifies(evaluation) || !candidate.isConfirmed ||
          !candidate.hasValidStopRange) continue;
      _assertBreakoutEvidence(evaluation, candidate);
      final capital = market.defaultEquity;
      final plan = calculatePositionSize(capital: capital,
          entryPrice: candidate.entryPrice, stopLossPrice: candidate.stopPrice!,
          isMegaCap: candidate.isLargeLiquid);
      final targets = calculateExitTargets(candidate.entryPrice, candidate.stopPrice!);
      expect(plan.shares, greaterThan(0));
      expect(plan.riskAmount, lessThanOrEqualTo(capital * .005 + 1e-8));
      expect(plan.positionPercent,
          lessThanOrEqualTo((candidate.isLargeLiquid ? 35 : 25) + 1e-8));
      expect(plan.riskBudget, capital * .005);
      for (final r in [3, 5, 10]) {
        expect(plan.targetPrice(r), closeTo(targets.targetPrice(r), 1e-8));
        expect(targets.targetPrice(r), closeTo(candidate.entryPrice +
            r * (candidate.entryPrice - candidate.stopPrice!), 1e-8));
      }
      qualified.add({
        ...candidate.toJson(),
        'account_capital': capital, 'account_currency': market.currency,
        'risk_budget': plan.riskBudget, 'actual_stop_risk': plan.riskAmount,
        'shares': plan.shares, 'position_percent': plan.positionPercent,
        'target_3r': targets.targetPrice(3), 'target_5r': targets.targetPrice(5),
        'target_10r': targets.targetPrice(10),
        'intraday_source': evaluation.data.intraday!.source,
        'intraday_is_cached': false, 'intraday_is_stale': false,
      });
    }
  }
  evidence['candidates'] = qualified;
  evidence['evaluated_count'] = evaluations.length;
  evidence['candidate_count'] = qualified.length;
  evidence['recommendation_status'] = qualified.isEmpty
      ? 'no_qualified_entry' : 'qualified_entries';
  _recordFilterSummary(evidence, observations);
  run.check();
  // Set verification flags only after both benchmark checks, every required
  // symbol's independent indicator checks and any actual entry assertions.
  evidence['benchmarks_verified'] = true;
  evidence['required_symbols_verified'] = true;
  evidence['indicators_verified'] = true;
}

bool _qualifies(LiveEvaluation row) {
  final stop = row.stop;
  if (stop == null || row.adr < row.stock.market.defaultAdr ||
      !row.patterns.contains('EMA 9/21/50 收斂') ||
      !row.patterns.contains('${row.triggerType} 突破')) return false;
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
  expect(RegExp(r'mock|fictitious|demo|示範|假', caseSensitive: false)
      .hasMatch(chart.source), isFalse);
  final now = DateTime.now().toUtc();
  expect(chart.quoteTimestamp.isAfter(now), isFalse);
  expect(now.difference(chart.quoteTimestamp), lessThan(const Duration(days: 7)),
      reason: 'Latest available daily quote must not be an obsolete observation.');
}

Map<String, dynamic> _dailyEvidence(MarketChart chart, LiveStrategyEngine engine,
    {required String kind}) {
  final bars = chart.completedDailyBars;
  final closes = bars.map((bar) => bar.close).toList();
  final adr = engine.adrPercent(bars);
  final manualAdr = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + (bar.high - bar.low) / bar.low * 100) / 20;
  expect(adr.isFinite, isTrue);
  expect(adr, greaterThanOrEqualTo(0));
  expect(adr, closeTo(manualAdr, 1e-9));
  final ema9 = engine.ema(closes, 9), ema21 = engine.ema(closes, 21), ema50 = engine.ema(closes, 50);
  final independentEmas = [for (final period in [9, 21, 50]) _independentEma(closes, period)];
  final actualEmas = [ema9, ema21, ema50];
  for (var index = 0; index < actualEmas.length; index++) {
    final ema = actualEmas[index];
    expect(ema.isFinite, isTrue);
    expect(ema, greaterThan(0));
    expect(ema, closeTo(independentEmas[index], math.max(1.0, ema.abs()) * 1e-10),
        reason: 'EMA ${[9, 21, 50][index]} differs from the independent weighted-sum formula.');
  }
  return {
    'kind': kind, 'symbol': chart.symbol, 'market': chart.market.name,
    'currency': chart.currency, 'provider_price': chart.latestPrice,
    'provider_quote_at_utc': chart.quoteTimestamp.toIso8601String(),
    'request_finished_at_utc': chart.fetchedAt.toIso8601String(),
    'completed_daily_bars': bars.length, 'adr_20_percent': adr,
    'adr_threshold': chart.market.defaultAdr,
    'adr_pass': adr >= chart.market.defaultAdr,
    'daily_indicators_verified': true,
    'independent_adr_20_percent': manualAdr,
    'last_raw_session_date': chart.localSessionDate(chart.bars.last.timestamp)
        .toIso8601String().substring(0, 10),
    'last_completed_session_date': chart.localSessionDate(bars.last.timestamp)
        .toIso8601String().substring(0, 10),
    'regular_session_start_utc': chart.regularSessionStart?.toIso8601String(),
    'regular_session_end_utc': chart.regularSessionEnd?.toIso8601String(),
    'ema_9': ema9, 'ema_21': ema21, 'ema_50': ema50,
    'independent_ema_9': independentEmas[0],
    'independent_ema_21': independentEmas[1],
    'independent_ema_50': independentEmas[2],
    'source': chart.source, 'is_cached': chart.isCached, 'is_stale': chart.isStale,
  };
}

/// Closed-form weighted sum, separate from the production iterative EMA.
double _independentEma(List<double> closes, int period) {
  final alpha = 2 / (period + 1);
  final decay = 1 - alpha;
  final seed = closes.take(period).fold<double>(0, (sum, close) => sum + close) / period;
  var result = seed * math.pow(decay, closes.length - period).toDouble();
  for (var index = period; index < closes.length; index++) {
    result += alpha * closes[index] * math.pow(decay, closes.length - index - 1).toDouble();
  }
  return result;
}

Map<String, dynamic> _independentRs(MarketChart stock, MarketChart benchmark) {
  String date(MarketChart chart, PriceBar bar) =>
      chart.localSessionDate(bar.timestamp).toIso8601String().substring(0, 10);
  final stockPrices = {for (final bar in stock.completedDailyBars) date(stock, bar): bar.close};
  final indexPrices = {for (final bar in benchmark.completedDailyBars) date(benchmark, bar): bar.close};
  final common = stockPrices.keys.where(indexPrices.containsKey).toList()..sort();
  expect(common.length, greaterThanOrEqualTo(61));
  final latest = common.last;
  double returnOf(Map<String, double> prices, int period) =>
      (prices[latest]! - prices[common[common.length - 1 - period]]!) /
      prices[common[common.length - 1 - period]]!;
  final score = ((returnOf(stockPrices, 20) - returnOf(indexPrices, 20)) +
      (returnOf(stockPrices, 60) - returnOf(indexPrices, 60))) * 50;
  return {
    'rs_as_of_session_date': latest,
    'rs_common_completed_sessions': common.length,
    'rs_stock_tail_sessions': stockPrices.keys.where((key) => key.compareTo(latest) > 0).length,
    'rs_benchmark_tail_sessions': indexPrices.keys.where((key) => key.compareTo(latest) > 0).length,
    'independent_rs_raw_excess_percent': score,
  };
}

List<PriceBar> _completedRegularBars(MarketChart chart) =>
    chart.regularSessionBars.where((bar) =>
        !bar.closeTimestamp.isAfter(chart.quoteTimestamp)).toList();

void _recordEvaluationEvidence(Map<String, dynamic> observation,
    LiveEvaluation evaluation, MarketChart benchmark, DateTime now) {
  final daily = evaluation.data.daily;
  final independentRs = _independentRs(daily, benchmark);
  expect(evaluation.momentum,
      closeTo(independentRs['independent_rs_raw_excess_percent'] as double, 1e-8),
      reason: 'RS differs from independent 20/60-day common-date return calculations.');
  observation.addAll(independentRs);
  final bars = daily.completedDailyBars;
  final prior = bars.last, earlier = bars[bars.length - 2];
  final closes = bars.map((bar) => bar.close).toList();
  final emas = [evaluation.ema9, evaluation.ema21, evaluation.ema50];
  final std7 = _standardDeviation(closes.sublist(closes.length - 7));
  final std20 = _standardDeviation(closes.sublist(closes.length - 20));
  final averageRange = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + bar.high - bar.low) / 20;
  final intraday = evaluation.data.intraday;
  // The closure receives a non-null chart parameter; never capture a nullable
  // local whose promotion could be invalidated by future edits.
  final regular = intraday == null ? <PriceBar>[] : _completedRegularBars(intraday);
  final first = regular.isEmpty ? null : regular.first;
  final sessionStart = intraday?.regularSessionStart;
  final sessionEnd = intraday?.regularSessionEnd;
  MarketChart? marketSessionChart;
  String? marketSessionSource;
  for (final entry in {'intraday': intraday, 'daily': daily, 'benchmark': benchmark}.entries) {
    final chart = entry.value;
    if (chart != null && chart.regularSessionStart != null && chart.regularSessionEnd != null) {
      marketSessionChart = chart;
      marketSessionSource = entry.key;
      break;
    }
  }
  final marketSessionStart = marketSessionChart?.regularSessionStart;
  final marketSessionEnd = marketSessionChart?.regularSessionEnd;
  final sessionMinutes = sessionStart != null && sessionEnd != null
      ? sessionEnd.difference(sessionStart).inMinutes : 0;
  final elapsedMinutes = sessionStart != null && regular.isNotEmpty
      ? regular.last.closeTimestamp.difference(sessionStart).inMinutes : 0;
  final averageVolume = bars.skip(bars.length - 20)
      .fold<double>(0, (sum, bar) => sum + bar.volume) / 20;
  final expectedVolume = sessionMinutes > 0 ? averageVolume * elapsedMinutes / sessionMinutes : 0.0;
  final observedVolume = regular.fold<double>(0, (sum, bar) => sum + bar.volume);
  final stop = evaluation.stop;
  final risk = stop == null ? null : (evaluation.trigger - stop) / evaluation.trigger * 100;
  final adrPass = evaluation.adr >= evaluation.stock.market.defaultAdr;
  final emaPass = evaluation.patterns.contains('EMA 9/21/50 收斂');
  final fresh = intraday?.isQuoteFresh(now) ?? false;
  final quoteInSession = intraday?.quoteIsInRegularSession ?? false;
  final reasons = <String>[];
  if (!adrPass) reasons.add('ADR_BELOW_THRESHOLD');
  if (!emaPass) reasons.add('EMA_NOT_COMPRESSED');
  if (intraday == null) {
    reasons.add(!adrPass ? 'INTRADAY_NOT_REQUESTED_ADR_FILTER' : 'INTRADAY_UNAVAILABLE');
  } else {
    if (!fresh) reasons.add('QUOTE_STALE_OR_CACHED');
    if (!quoteInSession) reasons.add('QUOTE_OUTSIDE_REGULAR_SESSION');
    if (first == null || first.timestamp != sessionStart) reasons.add('OPENING_CANDLE_UNAVAILABLE');
  }
  if (evaluation.notes.any((note) => note.contains('日 K 落後'))) {
    reasons.add('STOCK_DAILY_HISTORY_LAG');
  }
  if (evaluation.confirmation == null) reasons.add('NO_OBSERVED_BREAKOUT');
  if (stop == null) reasons.add('NO_VALID_INITIAL_STOP');
  if (risk != null && (risk < 1.5 || risk > 3)) reasons.add('STOP_DISTANCE_OUTSIDE_1_5_TO_3_PERCENT');
  observation.addAll({
    'evaluation_verified': true, 'rs_verified': true,
    'notes': evaluation.notes, 'ema_compression_pass': emaPass,
    'ema_spread_fraction': (emas.reduce(math.max) - emas.reduce(math.min)) / prior.close,
    'std_7': std7, 'std_20': std20, 'volatility_shrinking': std7 <= std20 * .8,
    'prior_close_above_emas': prior.close >= emas.reduce(math.max),
    'prior_inside_day': prior.high <= earlier.high && prior.low >= earlier.low,
    'prior_narrow_range': prior.high - prior.low <= averageRange * .6,
    'intraday_received': intraday != null,
    'intraday_error': evaluation.data.intradayError,
    'evaluation_time_utc': now.toIso8601String(),
    'intraday_regular_session_start_utc': sessionStart?.toIso8601String(),
    'intraday_regular_session_end_utc': sessionEnd?.toIso8601String(),
    'market_session_start_utc': marketSessionStart?.toIso8601String(),
    'market_session_end_utc': marketSessionEnd?.toIso8601String(),
    'market_session_source': marketSessionSource,
    'market_session_symbol': marketSessionChart?.symbol,
    'market_now_in_regular_session': marketSessionStart == null || marketSessionEnd == null
        ? null : !now.isBefore(marketSessionStart) && now.isBefore(marketSessionEnd),
    'quote_in_regular_session': quoteInSession, 'quote_fresh_15m': fresh,
    'quote_age_seconds': intraday == null ? null : now.difference(intraday.quoteTimestamp).inSeconds,
    'regular_completed_bars': regular.length,
    'opening_candle_complete': first != null && first.timestamp == sessionStart,
    'opening_gap_percent': first == null ? null : (first.open / prior.close - 1) * 100,
    'observed_session_volume': observedVolume, 'expected_session_volume': expectedVolume,
    'session_volume_ratio': expectedVolume > 0 ? observedVolume / expectedVolume : null,
    'trigger_type': evaluation.triggerType, 'trigger_price': evaluation.trigger,
    'stop_price': stop, 'stop_source': evaluation.stopSource,
    'stop_risk_percent': risk, 'strict_stop_range_pass': risk != null && risk >= 1.5 && risk <= 3,
    'signal_time_utc': evaluation.signalTime?.toIso8601String(),
    'signal_age_seconds': evaluation.signalTime == null ? null : now.difference(evaluation.signalTime!).inSeconds,
    'observed_confirmation_price': evaluation.confirmation,
    'latest_available_price': (intraday ?? daily).latestPrice,
    'recommendation_qualified': _qualifies(evaluation),
    'all_rejection_reasons': reasons,
    'primary_rejection_reason': reasons.isEmpty ? null : reasons.first,
  });
}

void _recordFilterSummary(Map<String, dynamic> evidence,
    List<Map<String, dynamic>> observations) {
  final stocks = observations.where((row) => row['kind'] == 'stock').toList();
  int count(String field) => stocks.where((row) => row[field] == true).length;
  final rejections = <String, int>{};
  for (final stock in stocks) {
    final reasons = stock['all_rejection_reasons'];
    if (reasons is List) {
      for (final reason in reasons.whereType<String>().toSet()) {
        rejections.update(reason, (value) => value + 1, ifAbsent: () => 1);
      }
    }
  }
  evidence['rejection_counts'] = rejections;
  evidence['filter_counts'] = {
    'observed_stocks': stocks.length,
    'daily_indicators_verified': count('daily_indicators_verified'),
    'evaluations_verified': count('evaluation_verified'),
    'adr_pass': count('adr_pass'), 'ema_compression_pass': count('ema_compression_pass'),
    'intraday_received': count('intraday_received'),
    'current_market_open': count('market_now_in_regular_session'),
    'market_session_unknown': stocks.where((row) => row['market_now_in_regular_session'] == null).length,
    'fresh_quote': count('quote_fresh_15m'),
    'quote_regular_session': count('quote_in_regular_session'),
    'observed_breakout': count('has_confirmed_observed_stop'),
    'strict_stop_range_pass': count('strict_stop_range_pass'),
    'qualified': count('recommendation_qualified'),
  };
}

void _assertBreakoutEvidence(LiveEvaluation evaluation, StockCandidate candidate) {
  final intraday = evaluation.data.intraday!;
  final daily = evaluation.data.daily.completedDailyBars;
  final closes = daily.map((bar) => bar.close).toList();
  final emas = [evaluation.ema9, evaluation.ema21, evaluation.ema50];
  expect((emas.reduce(math.max) - emas.reduce(math.min)) / daily.last.close,
      lessThanOrEqualTo(.025));
  expect(daily.last.close, greaterThanOrEqualTo(emas.reduce(math.max)));
  expect(_standardDeviation(closes.sublist(closes.length - 7)),
      lessThanOrEqualTo(_standardDeviation(closes.sublist(closes.length - 20)) * .8));
  expect(intraday.quoteIsInRegularSession, isTrue);
  expect(intraday.isQuoteFresh(DateTime.now().toUtc()), isTrue);
  expect(candidate.patterns, contains('${candidate.triggerType} 突破'));
  final regular = intraday.regularSessionBars.where((bar) =>
      !bar.closeTimestamp.isAfter(intraday.quoteTimestamp)).toList();
  expect(regular, isNotEmpty);
  expect(regular.first.timestamp, intraday.regularSessionStart);
  final i = regular.indexWhere((bar) => bar.closeTimestamp == candidate.signalTimestamp);
  expect(i, greaterThanOrEqualTo(0));
  final breakout = regular[i];
  final before = i == 0 ? breakout.open : regular[i - 1].close;
  expect(before, lessThanOrEqualTo(candidate.triggerPrice));
  expect(breakout.close, greaterThan(candidate.triggerPrice));
  expect(candidate.confirmationPrice, breakout.close);
  for (var cursor = 1; cursor <= i; cursor++) {
    expect(regular[cursor].timestamp, regular[cursor - 1].closeTimestamp);
  }
  final observedLow = regular.take(i + 1).map((bar) => bar.low).reduce(math.min);
  expect(candidate.dayLow, observedLow);
  expect(candidate.entryBarLow, breakout.low);
  if (candidate.triggerType == 'PDH') {
    expect(candidate.triggerPrice, evaluation.data.daily.completedDailyBars.last.high);
    final prior = daily.last, earlier = daily[daily.length - 2];
    final averageRange = daily.skip(daily.length - 20)
        .fold<double>(0, (sum, bar) => sum + bar.high - bar.low) / 20;
    expect((prior.high <= earlier.high && prior.low >= earlier.low) ||
        prior.high - prior.low <= averageRange * .6, isTrue,
        reason: 'PDH entry requires a real inside day or a narrow prior range.');
  } else {
    expect(candidate.triggerType, 'ORH');
    expect(i, greaterThan(0));
    expect(candidate.triggerPrice, regular.first.high);
    final previousClose = daily.last.close;
    final averageVolume = daily.skip(daily.length - 20)
        .fold<double>(0, (sum, bar) => sum + bar.volume) / 20;
    final sessionMinutes = intraday.regularSessionEnd!
        .difference(intraday.regularSessionStart!).inMinutes;
    final elapsedMinutes = breakout.closeTimestamp
        .difference(intraday.regularSessionStart!).inMinutes;
    final expectedVolume = averageVolume * elapsedMinutes / sessionMinutes;
    final observedVolume = regular.take(i + 1)
        .fold<double>(0, (sum, bar) => sum + bar.volume);
    expect((regular.first.open / previousClose - 1) * 100,
        greaterThanOrEqualTo(2));
    expect(expectedVolume, greaterThan(0));
    expect(observedVolume, greaterThanOrEqualTo(expectedVolume * 1.5));
  }
  expect(candidate.stopPrice, candidate.stopSource == 'day_low' ? observedLow : breakout.low);
}

double _standardDeviation(List<double> values) {
  final mean = values.fold<double>(0, (sum, value) => sum + value) / values.length;
  final variance = values.fold<double>(0,
      (sum, value) => sum + (value - mean) * (value - mean)) / values.length;
  return math.sqrt(variance);
}
