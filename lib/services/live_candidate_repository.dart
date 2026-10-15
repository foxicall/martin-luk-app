import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/market_data.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'candidate_repository.dart';
import 'live_batch_deadline.dart';
import 'live_strategy_engine.dart';
import 'market_data_api.dart';
import 'market_scan_progress.dart';
import 'stock_universe_service.dart';

/// Serverless core-market scanner. Membership still comes from the current
/// universe, but at most 30 genuine members are evaluated per scan. Five-stock
/// chunks and cancellable pauses protect the public provider from request
/// bursts. Partial coverage and individual failures are always disclosed.
class DirectLiveCandidateRepository implements ProgressiveCandidateRepository {
  DirectLiveCandidateRepository({MarketDataApi? api, StockUniverseService? universe,
    SharedPreferences? preferences, DateTime Function()? now,
    Duration scanBudget = const Duration(seconds: 9),
    Duration quoteRefreshBudget = const Duration(seconds: 6),
    this.corePoolSize = 30,
    this.batchSize = 5,
    this.interBatchDelay = const Duration(milliseconds: 150)})
      : _api = api ?? MarketDataApi(preferences: preferences, now: now),
        _universe = universe ?? StockUniverseService(preferences: preferences, now: now,
          requestTimeout: const Duration(seconds: 2),
          storageTimeout: const Duration(milliseconds: 500)),
        _ownsApi = api == null, _ownsUniverse = universe == null,
        scanBudget = _boundedBudget(scanBudget, 'scanBudget'),
        quoteRefreshBudget = _boundedBudget(quoteRefreshBudget, 'quoteRefreshBudget'),
        _preferences = preferences, _now = now ?? DateTime.now {
    if (batchSize < 1 || batchSize > 5) throw ArgumentError.value(batchSize, 'batchSize');
    if (corePoolSize < 1 || corePoolSize > 30) throw ArgumentError.value(corePoolSize, 'corePoolSize');
    if (interBatchDelay < Duration.zero) throw ArgumentError.value(interBatchDelay, 'interBatchDelay');
  }

  /// The controller has a separate ten-second hard deadline. Leave a second
  /// for its validation/finally block; custom short test budgets stay short.
  static const maximumScanBudget = Duration(seconds: 9);

  static Duration _boundedBudget(Duration value, String name) {
    if (value <= Duration.zero) throw ArgumentError.value(value, name);
    return value > maximumScanBudget ? maximumScanBudget : value;
  }

  final MarketDataApi _api;
  final StockUniverseService _universe;
  final bool _ownsApi, _ownsUniverse;
  final DateTime Function() _now;
  final Duration scanBudget;
  final Duration quoteRefreshBudget;
  final int corePoolSize;
  final int batchSize;
  final Duration interBatchDelay;
  SharedPreferences? _preferences;
  final _engine = const LiveStrategyEngine();
  final Map<String, CandidateSnapshot> _snapshots = {};
  final Map<String, Future<CandidateSnapshot>> _pending = {};
  final Map<StockMarket, Map<String, StockItem>> _members = {};
  final Set<LiveBatchDeadline> _runs = {};
  bool _closed = false;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {required double adrThreshold,
    bool forceRefresh = false, bool refreshQuotesOnly = false}) => fetchWithProgress(
        market, adrThreshold: adrThreshold, forceRefresh: forceRefresh,
        refreshQuotesOnly: refreshQuotesOnly);

  @override
  Future<CandidateSnapshot> fetchWithProgress(StockMarket market,
      {required double adrThreshold, bool forceRefresh = false,
      bool refreshQuotesOnly = false,
      void Function(MarketScanProgress)? onProgress}) {
    if (_closed) throw StateError('行情掃描服務已關閉。');
    if (!adrThreshold.isFinite || adrThreshold < 0) throw ArgumentError.value(adrThreshold);
    final key = '${market.name}:$adrThreshold';
    // Coalesce overlap from a pull gesture, timer and market tab switch.
    final pending = _pending[key];
    if (pending != null) return pending;
    late Future<CandidateSnapshot> operation;
    operation = _fetch(market, adrThreshold, forceRefresh, refreshQuotesOnly, onProgress)
        .whenComplete(() {
      if (identical(_pending[key], operation)) _pending.remove(key);
    });
    _pending[key] = operation;
    return operation;
  }

  Future<CandidateSnapshot> _fetch(StockMarket market, double threshold,
      bool force, bool quotesOnly, void Function(MarketScanProgress)? onProgress) async {
    final key = '${market.name}:$threshold';
    final budget = quotesOnly && !force ? quoteRefreshBudget : scanBudget;
    final cacheReserve = budget ~/ 10 < const Duration(seconds: 2)
        ? budget ~/ 10 : const Duration(seconds: 2);
    final run = LiveBatchDeadline(budget, reserve: cacheReserve);
    _runs.add(run);
    CandidateSnapshot? previous = _snapshots[key];
    var universeCount = previous?.universeCount ?? 0;
    var poolSize = 0, attemptedCount = 0, completedCount = 0;
    var evaluatedCount = 0, adrMatchCount = 0, confirmedCount = 0, failedCount = 0;
    CandidateSnapshot? latestPartial;
    void report(String stage, {bool finished = false}) {
      _emitProgress(onProgress, MarketScanProgress(market: market,
        universeCount: universeCount, poolSize: poolSize,
        attemptedCount: attemptedCount, completedCount: completedCount,
        evaluatedCount: evaluatedCount, adrMatchCount: adrMatchCount,
        confirmedCount: confirmedCount, failedCount: failedCount,
        finished: finished, stage: stage, partialSnapshot: latestPartial));
    }
    try {
      report('正在取得股票池與大盤');
      previous ??= await run.wait(_loadCache(market, threshold));
      if (_closed || !run.active) throw TimeoutException('掃描更新已取消或逾時。');
      // A partial scan's fresh quote time does not prove completion. Otherwise
      // one verified stock can suppress retries for the next fifteen minutes.
      final scanTime = previous?.scanCompletedAt;
      final age = scanTime == null ? null : _now().toUtc().difference(scanTime);
      final recentlyScanned = age != null && !age.isNegative &&
          age < const Duration(minutes: 15);
      // Timer updates refresh only known candidates. Initialization/manual
      // refresh must establish a real scan before the quote-only path is used.
      if (previous != null && !force && (quotesOnly || recentlyScanned)) {
        run.capTo(quoteRefreshBudget);
        return await _refreshHotQuotes(market, threshold, previous, run, onProgress);
      }
      if (quotesOnly && !force && previous == null) {
        // Do not start a whole-universe scan in a timer refresh with no prior
        // snapshot. Initialization/manual refresh is responsible for scanning.
        throw const RepositoryException('尚無真實掃描快取，請下拉更新以建立候選清單。');
      }
      // Universe metadata and benchmark prices are independent. Start both
      // together so two slow endpoints do not consume the whole foreground
      // budget serially. Future.wait observes either request's late failure.
      var universeReady = false, benchmarkReady = false;
      late List<Object> prerequisites;
      try {
        prerequisites = await run.wait(Future.wait<Object>([
          _loadUniverse(market, force).then((value) {
            if (run.active) universeReady = true;
            return value;
          }),
          _loadBenchmark(market, force).then((value) {
            if (run.active) benchmarkReady = true;
            return value;
          }),
        ], eagerError: true));
      } on TimeoutException {
        final pendingStages = [
          if (!universeReady) '股票池來源',
          if (!benchmarkReady) '大盤 ${market == StockMarket.tw ? '^TWII' : '^GSPC'}',
        ];
        final stage = pendingStages.isEmpty ? '股票池與大盤整合' : pendingStages.join('、');
        throw RepositoryException('${stage}未於 ${scanBudget.inSeconds} 秒更新期限內完成。');
      }
      if (_closed || !run.active) throw TimeoutException('股票池或大盤更新已取消或逾時。');
      final universe = prerequisites[0] as UniverseSnapshot;
      final benchmark = prerequisites[1] as MarketChart;
      _members[market] = {for (final stock in universe.stocks) stock.symbol: stock};
      if (benchmark.isStale) throw const RepositoryException('大盤行情為過期快取，無法建立新的 RS 排名。');
      final pool = _selectCorePool(universe.stocks, market);
      universeCount = universe.totalCount;
      poolSize = pool.length;
      report('核心精選池評估');
      final evaluations = <LiveEvaluation>[];
      final attempted = <String>{};
      final failures = <String, String>{};
      final intradayFailures = <String, String>{};
      final intradayPending = <String>{};
      void updateCounts() {
        evaluatedCount = evaluations.length;
        adrMatchCount = evaluations.where((row) => row.adr >= threshold).length;
        confirmedCount = evaluations.where((row) =>
            row.adr >= threshold && row.stop != null).length;
        failedCount = failures.length;
        completedCount = evaluatedCount + failedCount;
      }

      void publishPartial() {
        if (_closed || !run.active || evaluations.isEmpty) return;
        updateCounts();
        final evaluated = evaluations.map((row) => row.stock.symbol).toSet();
        final candidates = _engine.rank(evaluations)
            .where((candidate) => candidate.adrPercent >= threshold).toList();
        if (_closed || !run.active) return;
        latestPartial = CandidateSnapshot(candidates: candidates,
          fetchedAt: _now().toUtc(), scanCompletedAt: null,
          source: 'Yahoo Finance 真實行情／市場評估未完成（部分資料）',
          universeCount: universe.totalCount, evaluatedCount: evaluations.length,
          scanPoolSize: pool.length, adrMatchCount: candidates.length,
          universeIsComplete: universe.isComplete, universeAsOf: universe.asOf,
          stale: false,
          missingSymbols: pool.map((stock) => stock.symbol)
              .where((symbol) => !evaluated.contains(symbol)).toList()..sort(),
          warnings: [
            ...universe.warnings,
            '市場評估未完成；僅呈現已驗證的 ${evaluations.length}/${pool.length} 檔真實行情，RS 為目前已取得股票的暫時排名。',
            if (intradayPending.isNotEmpty)
              '有 ${intradayPending.length} 檔仍等待盤中資料；未確認突破的卡片僅供觀察。',
            if (failures.isNotEmpty) '個股錯誤摘要：${_failureSummary(failures)}。',
            if (intradayFailures.isNotEmpty)
              '部分盤中行情未取得：${_failureSummary(intradayFailures)}；僅保留已驗證日 K。',
          ]);
        // Publish after each validated symbol, rather than waiting for all
        // siblings in its chunk. One hung stock cannot hide completed data.
        report('核心精選池評估');
      }

      void recordEvaluation(LiveEvaluation value) {
        final index = evaluations.indexWhere((row) =>
            row.stock.symbol == value.stock.symbol);
        if (index < 0) {
          evaluations.add(value);
        } else {
          evaluations[index] = value;
        }
        publishPartial();
      }

      Future<void> evaluateStock(StockItem stock) async {
        if (_closed || !run.active) return;
        attempted.add(stock.symbol);
        attemptedCount = attempted.length;
        try {
          // Daily data is enough to reject low ADR. Intraday requests are
          // reserved for ADR-qualified stocks instead of 3 requests × 800.
          final daily = await run.wait(_api.fetchDaily(stock.symbol, market, forceRefresh: force));
          if (_closed || !run.active) return;
          if (daily.isStale) throw FormatException('日 K 為過期快取：${daily.cacheWarning ?? '最新日 K 取得失敗。'}');
          final adr = _engine.adrPercent(daily.completedDailyBars);
          var bundle = ChartBundle(daily: daily, intradayError: adr >= threshold
              ? '盤中資料尚未完成；僅供日線動能觀察，不確認突破。' : null);
          // ADR/EMA/RS can be verified independently of a slow intraday API.
          // A real daily-only evaluation never manufactures an entry or stop.
          final dailyEvaluation = _engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc());
          if (_closed || !run.active) return;
          if (adr >= threshold) {
            intradayPending.add(stock.symbol);
            recordEvaluation(dailyEvaluation);
            try {
              final intraday = await run.wait(_api.fetchIntraday(stock.symbol, market, forceRefresh: force));
              if (_closed || !run.active) return;
              if (intraday.isStale) {
                throw FormatException('盤中行情為過期快取：${intraday.cacheWarning ?? '最新盤中資料取得失敗。'}');
              }
              bundle = ChartBundle(daily: daily, intraday: intraday);
            } catch (error) {
              if (_closed || !run.active) return;
              final reason = _errorReason(error);
              intradayFailures[stock.symbol] = reason;
              bundle = ChartBundle(daily: daily, intradayError: '盤中資料取得失敗：$reason');
            }
            if (_closed || !run.active) return;
            intradayPending.remove(stock.symbol);
          } else {
            recordEvaluation(dailyEvaluation);
            return;
          }
          if (_closed || !run.active) return;
          final evaluation = _engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc());
          if (_closed || !run.active) return;
          recordEvaluation(evaluation);
        } catch (error) {
          if (_closed || !run.active) return;
          if (evaluations.any((row) => row.stock.symbol == stock.symbol)) {
            // An intraday parsing/calculation error cannot discard the daily
            // observation that already passed EMA and common-session RS checks.
            intradayPending.remove(stock.symbol);
            intradayFailures[stock.symbol] = _errorReason(error);
          } else {
            failures[stock.symbol] = _errorReason(error);
          }
        } finally {
          if (!_closed && run.active) {
            updateCounts();
            if (evaluations.isNotEmpty) publishPartial();
            else report('核心精選池評估');
          }
        }
      }
      try {
        for (var start = 0; start < pool.length; start += batchSize) {
          if (_closed || !run.active) break;
          final chunk = pool.skip(start).take(batchSize).toList();
          // No worker continuously drains a shared queue. Await ALL stocks in
          // this bounded chunk before scheduling even one subsequent symbol.
          await run.wait(Future.wait(chunk.map(evaluateStock)));
          if (_closed || !run.active) break;
          report('核心精選池評估');
          if (start + chunk.length < pool.length &&
              !_closed && run.active) {
            await run.pause(interBatchDelay);
          }
        }
      } on TimeoutException {
        // Keep completed observations, but seal all workers before publishing.
        // Future.wait still observes late futures; they cannot mutate this run.
      }
      run.seal();
      if (_closed) throw const RepositoryException('行情更新已取消。');
      final evaluated = evaluations.map((row) => row.stock.symbol).toSet();
      final missing = pool.map((stock) => stock.symbol)
          .where((symbol) => !evaluated.contains(symbol)).toSet();
      for (final symbol in attempted.difference(evaluated)) {
        failures.putIfAbsent(symbol, () => '${scanBudget.inSeconds} 秒整批期限內未完成行情或指標運算。');
      }
      // A whole-batch deadline resolves the attempted, unfinished symbols as
      // failures. Unvisited core members remain missing, never successful.
      failedCount = failures.length;
      completedCount = evaluations.length + failures.length;
      if (evaluations.isEmpty) {
        throw RepositoryException(pool.isEmpty
            ? '股票池沒有可掃描的普通股，請重新取得上市清單。'
            : '本次已嘗試 ${attempted.length}/${pool.length} 檔核心股票，沒有股票取得足夠日 K 與共同 RS 交易日。'
              '錯誤摘要：${_failureSummary(failures)}；請重試。');
      }
      final candidates = _engine.rank(evaluations)
          .where((candidate) => candidate.adrPercent >= threshold).toList();
      final finished = _now().toUtc();
      final scanComplete = missing.isEmpty && intradayPending.isEmpty;
      final snapshot = CandidateSnapshot(candidates: candidates, fetchedAt: finished,
        scanCompletedAt: scanComplete ? finished : null,
        source: scanComplete ? 'Yahoo Finance 直接連網核心精選掃描（公開行情可能延遲）'
            : 'Yahoo Finance 真實行情／市場評估未完成（部分資料）',
        universeCount: universe.totalCount, evaluatedCount: evaluations.length,
        scanPoolSize: pool.length, adrMatchCount: candidates.length,
        universeIsComplete: universe.isComplete, universeAsOf: universe.asOf,
        stale: false, missingSymbols: missing.toList()..sort(), warnings: [
          ...universe.warnings,
          '股票池共 ${universe.totalCount} 檔；本次核心精選池 ${pool.length} 檔，已評估 ${evaluations.length} 檔。'
            '未向整個市場同時發送請求；RS 排名僅涵蓋成功對齊交易日的核心股票。',
          if (candidates.isEmpty)
            '本次已評估的真實行情沒有標的符合 ADR ≥ $threshold%；推薦清單為有效的空結果。',
          if (missing.isNotEmpty) '有 ${missing.length} 檔因缺資料、請求失敗或 ${scanBudget.inSeconds} 秒整批掃描期限未完成；下拉更新可重新掃描。',
          if (failures.isNotEmpty) '個股錯誤摘要：${_failureSummary(failures)}。',
          if (intradayFailures.isNotEmpty) '部分盤中行情未取得：${_failureSummary(intradayFailures)}；這些股票僅保留有效日 K，無法確認盤中突破。',
          if (intradayPending.isNotEmpty) '有 ${intradayPending.length} 檔盤中資料未於整批期限內完成；保留有效日 K，不確認突破。',
          '前台每分鐘僅更新前 20 個候選報價；核心精選池評估間隔至少 15 分鐘，下拉更新可強制評估。',
          '手機直接請求公開端點可能遇到限流；Web 受跨來源限制時可選擇中繼後端。',
        ]);
      _snapshots[key] = snapshot;
      await _saveCache(market, threshold, snapshot, budget: run.remaining);
      if (_closed) throw const RepositoryException('行情更新已取消。');
      latestPartial = scanComplete ? null : snapshot;
      report(scanComplete ? '評估完成' : '部分評估完成', finished: true);
      return snapshot;
    } catch (error) {
      if (_closed) throw const RepositoryException('行情更新已取消。');
      report('評估失敗：${_errorReason(error)}', finished: true);
      if (previous != null) return _stale(previous, '連網掃描失敗：$error');
      if (error is RepositoryException) rethrow;
      throw RepositoryException('真實市場掃描失敗：$error');
    } finally {
      run.seal();
      _runs.remove(run);
    }
  }

  Future<CandidateSnapshot> _refreshHotQuotes(StockMarket market, double threshold,
      CandidateSnapshot previous, LiveBatchDeadline run,
      void Function(MarketScanProgress)? onProgress) async {
    final updated = <String, StockCandidate>{};
    final failures = <String, String>{};
    final attempted = <String>{};
    final bySymbol = _members[market] ?? {};
    final hot = previous.candidates.take(20).toList();
    void report(String stage, {bool finished = false}) {
      _emitProgress(onProgress, MarketScanProgress(market: market,
        universeCount: previous.universeCount, poolSize: hot.length,
        attemptedCount: attempted.length,
        completedCount: updated.length + failures.length,
        evaluatedCount: updated.length,
        adrMatchCount: updated.values.where((row) => row.adrPercent >= threshold).length,
        confirmedCount: updated.values.where((row) => row.isConfirmed && row.adrPercent >= threshold).length,
        failedCount: failures.length, finished: finished, stage: stage));
    }
    if (hot.isEmpty) {
      report('上次評估無 ADR 候選，保留原評估時間', finished: true);
      if (_closed) throw const RepositoryException('候選報價更新已取消。');
      return previous;
    }
    try {
      report('候選報價更新');
      if (_closed || !run.active) throw TimeoutException('候選報價更新已取消或逾時。');
      final benchmark = await run.wait(_loadBenchmark(market, false));
      if (_closed || !run.active) throw TimeoutException('候選報價更新已取消或逾時。');
      Future<void> updateCandidate(StockCandidate candidate) async {
        if (_closed || !run.active) return;
        attempted.add(candidate.symbol);
        final stock = bySymbol[candidate.symbol] ?? StockItem(
          market: market, symbol: candidate.symbol,
          code: market == StockMarket.tw ? candidate.symbol.split('.').first : candidate.symbol,
          nameZh: candidate.name, nameFullZh: '', nameEn: candidate.name, abbrEn: '');
        try {
          final bundle = await _fetchBundleWithinRun(stock.symbol, market, run);
          if (_closed || !run.active) return;
          if (bundle.daily.isStale || bundle.intraday?.isStale == true || benchmark.isStale) {
            throw FormatException('最新請求僅取得過期快取：'
                '${bundle.intraday?.cacheWarning ?? bundle.daily.cacheWarning ?? benchmark.cacheWarning ?? '最新行情取得失敗。'}');
          }
          if (bundle.intraday == null && bundle.intradayError != null) {
            throw FormatException('盤中報價失敗：${bundle.intradayError}');
          }
          final evaluated = _engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc());
          if (_closed || !run.active) return;
          // Quote refresh never re-ranks a small hot list as if it were the
          // full evaluated universe. Keep the last complete scan ranking.
          updated[candidate.symbol] = evaluated.toCandidate(
              rsScore: candidate.rsScore, rsRank: candidate.rsRank);
        } catch (error) {
          if (_closed || !run.active) return;
          failures[candidate.symbol] = _errorReason(error);
        }
      }
      try {
        for (var start = 0; start < hot.length; start += batchSize) {
          if (_closed || !run.active) break;
          final chunk = hot.skip(start).take(batchSize).toList();
          await run.wait(Future.wait(chunk.map(updateCandidate)));
          if (_closed || !run.active) break;
          report('候選報價更新');
          if (start + chunk.length < hot.length && !_closed && run.active) {
            await run.pause(interBatchDelay);
          }
        }
      } on TimeoutException {
        // Publish only fully completed refreshes and account for every other
        // hot symbol, including workers already inside a timed-out request.
      }
      run.seal();
      if (_closed) throw const RepositoryException('候選報價更新已取消。');
      final failed = hot.where((candidate) => !updated.containsKey(candidate.symbol))
          .map((candidate) => candidate.symbol).toList();
      for (final symbol in failed) {
        failures.putIfAbsent(symbol, () => attempted.contains(symbol)
            ? '${quoteRefreshBudget.inSeconds} 秒更新期限內未完成。' : '整批期限內尚未輪到此股票。');
      }
      if (updated.isEmpty) {
        report('候選報價更新失敗，保留快取', finished: true);
        return _stale(previous,
            '候選報價更新 0/${hot.length}；保留上次真實快取。錯誤摘要：${_failureSummary(failures)}。');
      }
      final snapshot = CandidateSnapshot(
        candidates: previous.candidates.map((candidate) => updated[candidate.symbol] ?? candidate).toList(),
        fetchedAt: _now().toUtc(), scanCompletedAt: previous.scanCompletedAt,
        source: previous.source, universeCount: previous.universeCount,
        evaluatedCount: previous.evaluatedCount, universeIsComplete: previous.universeIsComplete,
        scanPoolSize: previous.scanPoolSize, adrMatchCount: previous.adrMatchCount,
        universeAsOf: previous.universeAsOf, stale: failed.isNotEmpty,
        missingSymbols: previous.missingSymbols, warnings: [
          ...previous.warnings.where((warning) => !warning.startsWith('本次即時更新')),
          '本次即時更新 ${updated.length}/${hot.length} 個候選；其餘保留卡片原始行情時間。',
          if (failed.isNotEmpty) '部分候選報價失敗：${_failureSummary(failures)}。',
        ]);
      _snapshots['${market.name}:$threshold'] = snapshot;
      await _saveCache(market, threshold, snapshot, budget: run.remaining);
      if (_closed) throw const RepositoryException('候選報價更新已取消。');
      report(failed.isEmpty ? '候選報價更新完成' : '候選報價部分更新完成', finished: true);
      return snapshot;
    } catch (error) {
      if (_closed) throw const RepositoryException('候選報價更新已取消。');
      report('候選報價更新失敗：${_errorReason(error)}', finished: true);
      return _stale(previous, '候選報價更新失敗：$error');
    }
  }

  /// Emitters are UI observers, not part of the price/strategy transaction.
  /// A faulty observer cannot abort siblings or retain the repository lock.
  void _emitProgress(void Function(MarketScanProgress)? observer,
      MarketScanProgress progress) {
    if (_closed || observer == null) return;
    try { observer(progress); } catch (_) { /* Observer errors are isolated. */ }
  }

  List<StockItem> _selectCorePool(List<StockItem> stocks, StockMarket market) {
    const usPriority = [
      'NVDA', 'AAPL', 'TSLA', 'AMD', 'AVGO', 'META', 'MSFT', 'AMZN',
      'GOOGL', 'GOOG', 'MU', 'PLTR', 'PANW', 'CRWD', 'AMAT', 'LRCX',
      'KLAC', 'SMCI', 'APP', 'NFLX', 'COIN', 'GE', 'UBER', 'ORCL',
      'CRM', 'NOW', 'ANET', 'INTU', 'ISRG', 'JPM',
    ];
    const twPriority = [
      '2330.TW', '2603.TW', '2454.TW', '2317.TW', '2308.TW', '2382.TW',
      '3231.TW', '6669.TW', '3017.TW', '2376.TW', '2379.TW', '2345.TW',
      '3034.TW', '3661.TW', '3443.TW', '2357.TW', '2303.TW', '2408.TW',
      '3711.TW', '2383.TW', '2609.TW', '2615.TW', '2618.TW', '2610.TW',
      '2881.TW', '2882.TW', '2891.TW', '2886.TW', '2002.TW', '1301.TW',
    ];
    // The allowlist controls ordering only. An absent current-universe symbol
    // is never manufactured as a member or requested from the price API.
    final members = <String, StockItem>{
      for (final stock in stocks.where((stock) => stock.market == market))
        stock.symbol: stock,
    };
    final pool = <StockItem>[];
    for (final symbol in market == StockMarket.tw ? twPriority : usPriority) {
      final member = members.remove(symbol);
      if (member != null) pool.add(member);
      if (pool.length >= corePoolSize) return pool;
    }
    pool.addAll(members.values.take(corePoolSize - pool.length));
    return pool;
  }

  Future<UniverseSnapshot> _loadUniverse(StockMarket market, bool force) async {
    try {
      return await _universe.load(market, forceRefresh: force);
    } catch (error) {
      throw RepositoryException('股票池來源取得失敗：${_errorReason(error)}');
    }
  }

  Future<MarketChart> _loadBenchmark(StockMarket market, bool force) async {
    try {
      return await _api.fetchBenchmark(market, forceRefresh: force);
    } catch (error) {
      throw RepositoryException('大盤 ${market == StockMarket.tw ? '^TWII' : '^GSPC'} 行情取得失敗：${_errorReason(error)}');
    }
  }

  String _errorReason(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 220 ? text : '${text.substring(0, 220)}…';
  }

  String _failureSummary(Map<String, String> failures) {
    if (failures.isEmpty) return '尚未完成個股請求。';
    final first = failures.entries.take(6).map((entry) => '${entry.key}：${entry.value}').join('；');
    return failures.length <= 6 ? first : '$first；其餘 ${failures.length - 6} 檔錯誤摘要已省略。';
  }

  Future<ChartBundle> _fetchBundleWithinRun(String symbol, StockMarket market,
      LiveBatchDeadline run) async {
    if (_closed || !run.active) throw TimeoutException('候選更新已取消或逾時。');
    final daily = await run.wait(_api.fetchDaily(symbol, market));
    if (_closed || !run.active) throw TimeoutException('候選更新已取消或逾時。');
    try {
      final intraday = await run.wait(_api.fetchIntraday(symbol, market));
      if (_closed || !run.active) throw TimeoutException('候選更新已取消或逾時。');
      return ChartBundle(daily: daily, intraday: intraday);
    } catch (error) {
      if (_closed || !run.active) rethrow;
      return ChartBundle(daily: daily, intradayError: error.toString());
    }
  }

  String _cacheKey(StockMarket market, double threshold) =>
      'martin-live-scan-v1-${market.name}-$threshold';
  Future<SharedPreferences> _prefs() async => _preferences ??=
      await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));

  Future<void> _saveCache(StockMarket market, double threshold, CandidateSnapshot snapshot,
      {required Duration budget}) async {
    if (_closed || budget <= Duration.zero) return;
    final limit = budget < const Duration(seconds: 2) ? budget : const Duration(seconds: 2);
    final storage = Stopwatch()..start();
    try {
      final preferences = await _prefs().timeout(limit);
      final left = limit - storage.elapsed;
      if (_closed || left <= Duration.zero ||
          !identical(_snapshots['${market.name}:$threshold'], snapshot)) return;
      await preferences.setString(_cacheKey(market, threshold), jsonEncode({
        'schema': 1, 'fetched_at': snapshot.fetchedAt.toUtc().toIso8601String(),
        'scan_completed_at': snapshot.scanCompletedAt?.toUtc().toIso8601String(),
        // Partial observations remain useful offline, but this flag and the
        // null completion time prohibit treating them as a completed scan.
        'scan_complete': snapshot.scanCompletedAt != null,
        'source': snapshot.source, 'universe_count': snapshot.universeCount,
        'evaluated_count': snapshot.evaluatedCount, 'universe_is_complete': snapshot.universeIsComplete,
        'scan_pool_size': snapshot.scanPoolSize, 'adr_match_count': snapshot.adrMatchCount,
        'universe_as_of': snapshot.universeAsOf?.toUtc().toIso8601String(),
        'warnings': snapshot.warnings, 'missing_symbols': snapshot.missingSymbols,
        'candidates': snapshot.candidates.map((candidate) => candidate.toJson()).toList(),
      })).timeout(left);
    } catch (_) { /* Cache failure must not discard successfully fetched quotes. */ }
  }

  Future<CandidateSnapshot?> _loadCache(StockMarket market, double threshold) async {
    try {
      final value = (await _prefs()).getString(_cacheKey(market, threshold));
      if (value == null) return null;
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data['schema'] != 1) return null;
      final fetched = DateTime.parse(data['fetched_at'] as String).toUtc();
      final age = _now().toUtc().difference(fetched);
      if (age.isNegative || age > const Duration(hours: 24)) return null;
      final candidates = (data['candidates'] as List).map((row) =>
          StockCandidate.fromJson(row as Map<String, dynamic>)).toList();
      if (candidates.any((candidate) => candidate.market != market || candidate.adrPercent < threshold)) return null;
      return CandidateSnapshot(candidates: candidates, fetchedAt: fetched,
        scanCompletedAt: data['scan_complete'] == false ||
            data['scan_completed_at'] == null ? null :
            DateTime.parse(data['scan_completed_at'] as String).toUtc(),
        source: data['source'] as String, universeCount: data['universe_count'] as int,
        evaluatedCount: data['evaluated_count'] as int?,
        scanPoolSize: data['scan_pool_size'] as int?, adrMatchCount: data['adr_match_count'] as int?,
        universeIsComplete: data['universe_is_complete'] as bool,
        universeAsOf: data['universe_as_of'] == null ? null : DateTime.parse(data['universe_as_of'] as String).toUtc(),
        stale: true, warnings: [...(data['warnings'] as List).cast<String>(),
          if (data['scan_complete'] == false || data['scan_completed_at'] == null)
            '此快取僅含上次部分評估；市場掃描未完成，不能視為完整新評估。',
          '顯示上次真實行情快取，尚待連網更新。'],
        missingSymbols: (data['missing_symbols'] as List).cast<String>());
    } catch (_) { return null; }
  }

  CandidateSnapshot _stale(CandidateSnapshot previous, String warning) => CandidateSnapshot(
    candidates: previous.candidates, fetchedAt: previous.fetchedAt,
    scanCompletedAt: previous.scanCompletedAt, source: '${previous.source}／上次真實快取',
    universeCount: previous.universeCount, evaluatedCount: previous.evaluatedCount,
    scanPoolSize: previous.scanPoolSize, adrMatchCount: previous.adrMatchCount,
    universeIsComplete: previous.universeIsComplete, universeAsOf: previous.universeAsOf,
    stale: true, missingSymbols: previous.missingSymbols,
    warnings: [...previous.warnings, warning]);

  void close() {
    _closed = true;
    for (final run in _runs) { run.seal(); }
    if (_ownsApi) _api.close();
    if (_ownsUniverse) _universe.close();
  }
}
