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
import 'mobile_scan_checkpoint.dart';
import 'stock_universe_service.dart';

/// Serverless scanner: both markets resume pages across every returned member.
/// Each immutable round uses the actual provider universe. Five-stock chunks
/// and cancellable pauses protect the public provider from request bursts.
/// Partial coverage, page-local RS and individual failures are disclosed.
class DirectLiveCandidateRepository implements ProgressiveCandidateRepository {
  DirectLiveCandidateRepository({MarketDataApi? api, StockUniverseService? universe,
    SharedPreferences? preferences, DateTime Function()? now,
    Duration scanBudget = const Duration(seconds: 9),
    Duration quoteRefreshBudget = const Duration(seconds: 6),
    int? corePoolSize,
    int? usPageSize,
    this.twPageSize = 30,
    this.batchSize = 5,
    this.interBatchDelay = const Duration(milliseconds: 150)})
      : _api = api ?? MarketDataApi(preferences: preferences, now: now),
        _universe = universe ?? StockUniverseService(preferences: preferences, now: now,
          requestTimeout: const Duration(seconds: 4),
          storageTimeout: const Duration(milliseconds: 500)),
        _ownsApi = api == null, _ownsUniverse = universe == null,
        usPageSize = usPageSize ?? corePoolSize ?? 30,
        scanBudget = _boundedBudget(scanBudget, 'scanBudget'),
        quoteRefreshBudget = _boundedBudget(quoteRefreshBudget, 'quoteRefreshBudget'),
        _preferences = preferences, _now = now ?? DateTime.now {
    if (batchSize < 1 || batchSize > 5) throw ArgumentError.value(batchSize, 'batchSize');
    if (corePoolSize != null && usPageSize != null && corePoolSize != usPageSize) {
      throw ArgumentError('corePoolSize 與 usPageSize 同時設定時必須相同。');
    }
    if (this.usPageSize < 1 || this.usPageSize > 30) {
      throw ArgumentError.value(this.usPageSize, 'usPageSize');
    }
    if (twPageSize < 1 || twPageSize > 30) throw ArgumentError.value(twPageSize, 'twPageSize');
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
  /// Retained source compatibility: this limits one US page, never membership.
  @Deprecated('Use usPageSize; a page limit does not limit universe coverage.')
  int get corePoolSize => usPageSize;
  final int usPageSize;
  final int twPageSize;
  final int batchSize;
  final Duration interBatchDelay;
  SharedPreferences? _preferences;
  final _engine = const LiveStrategyEngine();
  final Map<String, CandidateSnapshot> _snapshots = {};
  final Map<String, Future<CandidateSnapshot>> _pending = {};
  final Map<StockMarket, Map<String, StockItem>> _members = {};
  final Set<LiveBatchDeadline> _runs = {};
  bool _closed = false;
  final Map<String, MobileScanCheckpoint> _checkpoints = {};
  final Map<StockMarket, double> _activeThresholds = {};

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
    // Quote-only intent cannot bypass unfinished membership. A completed
    // round may use bounded hot quotes during its fixed 15-minute cooldown.
    operation = _fetchRolling(market, adrThreshold, forceRefresh, onProgress)
        .whenComplete(() {
      if (identical(_pending[key], operation)) _pending.remove(key);
    });
    _pending[key] = operation;
    return operation;
  }

  /// Both markets use the COMPLETE actual member list returned by the source.
  /// An incomplete source remains explicitly incomplete; no symbol is invented.
  /// A page is only a work budget, never a fixed priority/allow list. Each call
  /// resumes the first unattempted member; failures advance and are disclosed.
  Future<CandidateSnapshot> _fetchRolling(StockMarket market, double threshold, bool force,
      void Function(MarketScanProgress)? onProgress) async {
    final marketLabel = market == StockMarket.tw ? '台股' : '美股';
    final key = '${market.name}:$threshold';
    final reserve = scanBudget ~/ 10;
    final run = LiveBatchDeadline(scanBudget, reserve: reserve);
    _runs.add(run);
    MobileScanCheckpoint? checkpoint = _checkpoints[key];
    CandidateSnapshot? previous = _snapshots[key] ?? checkpoint?.toSnapshot();
    try {
      checkpoint ??= await run.wait(_loadCheckpoint(market, threshold, run),
          maximum: const Duration(milliseconds: 500));
      if (_closed || !run.active) throw TimeoutException('$marketLabel輪掃已取消或逾時。');
      if (checkpoint != null && (checkpoint.updatedAt.isAfter(_now().toUtc()) ||
          _now().toUtc().difference(checkpoint.updatedAt) > const Duration(days: 7))) {
        // In-memory resumes obey the same retention limit as a phone restart.
        checkpoint = null;
        previous = null;
        _checkpoints.remove(key);
        _snapshots.remove(key);
      }
      previous ??= checkpoint?.toSnapshot(fromDisk: true);
      // Restore actual names/suffixes too. A restart must not depend on the
      // next directory response containing both exchanges to resume its round.
      if (checkpoint != null) {
        _members[market] = {
          ...?_members[market],
          for (final stock in checkpoint.members) stock.symbol: stock,
        };
      }
      final thresholdChanged = _activeThresholds[market] != null &&
          _activeThresholds[market] != threshold;
      final today = MobileScanCheckpoint.dayFor(_now(), market: market);
      // Progress/quote refreshes may renew updatedAt. Only the immutable round
      // completion stamp can authorize a cooldown; an interrupted final chunk
      // must start a new round instead of refreshing itself forever.
      final completedAt = checkpoint?.roundCompletedAt;
      final completedAge = completedAt == null ? null :
          _now().toUtc().difference(completedAt);
      final completedToday = market == StockMarket.us
          ? completedAt != null &&
              MobileScanCheckpoint.dayFor(completedAt, market: market) == today
          : checkpoint?.day == today;
      // Only a complete current-day round may enter the old hot-quote path.
      // Incomplete rounds ignore both quotesOnly and the 15-minute cooldown.
      if (checkpoint != null && checkpoint.remaining == 0 && !force &&
          !thresholdChanged && completedToday &&
          completedAge != null && !completedAge.isNegative &&
          completedAge < const Duration(minutes: 15) && previous != null) {
        _checkpoints[key] = checkpoint;
        run.capTo(quoteRefreshBudget);
        return await _refreshHotQuotes(market, threshold, previous, run, onProgress);
      }
      _emitProgress(onProgress, MarketScanProgress(market: market,
        universeCount: previous?.universeCount ?? 0, poolSize: 0,
        attemptedCount: 0, completedCount: 0, evaluatedCount: 0,
        adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
        finished: false, stage: '正在取得$marketLabel完整名單與大盤'));
      // Once a round has real metadata for every symbol, membership HTTP is
      // unnecessary between pages (even on a manual force-price refresh).
      // Keep its exact identity/date until the round boundary, rather than
      // allowing an intermittently missing exchange to reset the scan cursor.
      final Future<UniverseSnapshot> directory;
      if (checkpoint != null && !thresholdChanged &&
          checkpoint.canResume(threshold, _now()) &&
          checkpoint.members.length == checkpoint.symbols.length) {
        final pinned = checkpoint;
        directory = Future<UniverseSnapshot>.value(UniverseSnapshot(
          stocks: pinned.members, asOf: pinned.universeAsOf,
          source: '本輪已保存的$marketLabel股票名單',
          isComplete: pinned.universeIsComplete,
          warnings: pinned.universeWarnings));
      } else {
        directory = _loadUniverse(market, force);
      }
      final prerequisites = await run.wait(Future.wait<Object>([
        directory, _loadBenchmark(market, force),
      ], eagerError: true));
      if (_closed || !run.active) throw TimeoutException('$marketLabel名單或大盤取得逾時。');
      final universe = prerequisites[0] as UniverseSnapshot;
      final benchmark = prerequisites[1] as MarketChart;
      if (benchmark.isStale) {
        throw const RepositoryException('大盤行情為過期快取，無法建立新的 RS 排名。');
      }
      final currentMembers = <String, StockItem>{
        for (final stock in universe.stocks)
          if (stock.market == market &&
              MobileScanCheckpoint.isCanonicalSymbol(stock.symbol, market))
            stock.symbol: stock,
      };
      final currentSymbols = currentMembers.keys.toList()..sort();
      if (currentSymbols.isEmpty) {
        throw RepositoryException('$marketLabel來源未提供可掃描的普通股。');
      }
      final oldRound = checkpoint?.round ?? 0;
      final reset = checkpoint == null || thresholdChanged ||
          !checkpoint.canResume(threshold, _now());
      if (reset) {
        checkpoint = MobileScanCheckpoint(market: market, symbols: currentSymbols,
          members: currentSymbols.map((symbol) => currentMembers[symbol]!).toList(),
          universeWarnings: universe.warnings,
          threshold: threshold, day: today, round: oldRound + 1,
          attempted: const <String>{}, evaluated: const <String>{}, candidates: const [],
          updatedAt: _now().toUtc(), universeAsOf: universe.asOf,
          universeIsComplete: universe.isComplete, warnings: universe.warnings);
      }
      final initial = checkpoint!;
      // Pin the round identity until its final member has been attempted.
      // Temporary TWSE/TPEx failures (e.g. 1,979 -> 894 -> 1,979) and name-list
      // reordering must never replay page one. New listings join the next round.
      final symbols = initial.symbols;
      final bySymbol = <String, StockItem>{
        ...?_members[market],
        for (final stock in initial.members) stock.symbol: stock,
        ...currentMembers,
      };
      final roundMembers = <StockItem>[
        for (final symbol in symbols)
          if (bySymbol[symbol] != null) bySymbol[symbol]!,
      ];
      _members[market] = bySymbol;
      final membershipChanged = !initial.matches(currentSymbols, threshold, _now());
      final start = initial.attempted.length;
      final pool = symbols.skip(start).take(market == StockMarket.tw ? twPageSize : usPageSize).toList();
      final attempted = <String>{};
      final evaluations = <String, LiveEvaluation>{};
      final failures = <String, String>{};
      final intradayFailures = <String, String>{};
      final intradayPending = <String>{};
      CandidateSnapshot? partial;
      var storageFailed = false;

      MobileScanCheckpoint buildCheckpoint({bool finalPage = false}) {
        final pageCandidates = _engine.rank(evaluations.values.toList())
            .where((row) => row.adrPercent >= threshold)
            .map(_withPageRankingNote).toList();
        final candidates = <String, StockCandidate>{
          for (final row in initial.candidates) row.symbol: row,
        };
        // A newly attempted stock replaces its former round observation, even
        // if this attempt failed or no longer meets ADR. No old entry is sold
        // as a newly verified member of this page.
        for (final symbol in attempted) { candidates.remove(symbol); }
        for (final row in pageCandidates) { candidates[row.symbol] = row; }
        final accumulated = candidates.values.toList()
          ..sort((left, right) => left.symbol.compareTo(right.symbol));
        final allAttempted = {...initial.attempted, ...attempted};
        final allEvaluated = {...initial.evaluated, ...evaluations.keys};
        final pageComplete = attempted.length == pool.length &&
            evaluations.length == pool.length && intradayPending.isEmpty;
        final now = _now().toUtc();
        return MobileScanCheckpoint(market: market, symbols: symbols, threshold: threshold,
          members: roundMembers,
          universeWarnings: initial.universeWarnings,
          day: initial.day, round: initial.round, attempted: allAttempted,
          evaluated: allEvaluated, candidates: accumulated, updatedAt: now,
          universeAsOf: initial.universeAsOf,
          universeIsComplete: initial.universeIsComplete,
          roundCompletedAt: finalPage && allAttempted.length == symbols.length
              ? now : null,
          pageStart: start, pageSize: pool.length,
          pageEvaluated: evaluations.length, pageAdrMatches: pageCandidates.length,
          pageScanCompletedAt: finalPage && pageComplete ? now : null,
          pageStale: evaluations.isEmpty,
          warnings: [
            ...universe.warnings,
            if (membershipChanged)
              '本輪固定沿用 ${symbols.length} 檔股票名單；最新來源取得 '
                '${currentSymbols.length} 檔，差異於下一輪套用，避免重掃第一頁。',
            '手機$marketLabel完整名單分批輪掃：第 ${initial.round} 輪已嘗試 '
              '${allAttempted.length}/${symbols.length} 檔，成功評估 '
              '${allEvaluated.length} 檔，剩餘 ${symbols.length - allAttempted.length} 檔。',
            '本頁股票 ${start + 1}–${start + pool.length}，已嘗試 ${attempted.length} 檔、'
              '成功 ${evaluations.length} 檔；每批最多 $batchSize 檔，失敗跳過後繼續。',
            if (attempted.isNotEmpty)
              '本頁已嘗試代碼：${pool.first}–${symbols[start + attempted.length - 1]}；'
                '下一檔：${allAttempted.length < symbols.length ? symbols[allAttempted.length] : '本輪已全部嘗試'}。',
            '候選跨頁累積並保留各卡原始行情時間；RS 為原掃描頁內排名，非全市場同步排名。',
            if (evaluations.isEmpty)
              '本頁尚無成功的真實日 K／RS 評估；此為失敗或未完成狀態，不是成功的零候選結果。',
            if (evaluations.isNotEmpty && pageCandidates.isEmpty)
              '本頁已評估的真實行情沒有標的符合 ADR ≥ $threshold%；零候選為有效結果。',
            if (attempted.length < pool.length)
              '整批期限已到；尚未嘗試的 ${pool.length - attempted.length} 檔保留至下次，不會跳過。',
            if (failures.isNotEmpty) '個股錯誤摘要：${_failureSummary(failures)}。',
            if (intradayFailures.isNotEmpty)
              '部分盤中行情未取得：${_failureSummary(intradayFailures)}；只保留已驗證日 K，不確認突破。',
            if (intradayPending.isNotEmpty)
              '有 ${intradayPending.length} 檔盤中資料尚未完成；僅供觀察，不確認突破。',
            '前台定期更新、下拉刷新或已啟用的 Android 背景服務會續掃下一頁；'
                '未啟用服務時切到背景暫停，下次由已保存進度繼續。',
            if (storageFailed)
              '本機進度未儲存，僅暫存在記憶體，重啟可能重掃；行情計算結果仍可查看。',
          ]);
      }

      void report({bool finished = false}) {
        if (_closed || (!run.active && !finished)) return;
        final matches = evaluations.values.where((row) => row.adr >= threshold).length;
        final confirmed = evaluations.values.where((row) =>
            row.adr >= threshold && row.stop != null).length;
        partial = buildCheckpoint(finalPage: finished).toSnapshot();
        _emitProgress(onProgress, MarketScanProgress(market: market,
          universeCount: symbols.length, poolSize: pool.length,
          attemptedCount: attempted.length,
          completedCount: evaluations.length + failures.length,
          evaluatedCount: evaluations.length, adrMatchCount: matches,
          confirmedCount: confirmed, failedCount: failures.length,
          finished: finished,
          stage: '$marketLabel第 ${initial.round} 輪・第 ${start + 1}–${start + pool.length} 檔'
              '${finished ? '完成' : '分批輪掃'}',
          partialSnapshot: partial));
      }

      Future<void> persistProgress() async {
        if (_closed || !run.active) return;
        final value = buildCheckpoint();
        _checkpoints[key] = value;
        _activeThresholds[market] = threshold;
        if (!await _saveCheckpoint(value, budget: run.remaining)) {
          storageFailed = true;
        }
      }

      void record(LiveEvaluation value) {
        if (_closed || !run.active) return;
        evaluations[value.stock.symbol] = value;
        report();
      }

      Future<void> evaluateStock(String symbol) async {
        if (_closed || !run.active) return;
        attempted.add(symbol);
        final stock = bySymbol[symbol];
        if (stock == null) {
          // Older journals did not store company metadata. Preserve their
          // attempted prefix and disclose unavailable members; never invent a
          // security name or silently restart the first thirty stocks.
          failures[symbol] = '舊版進度缺少此檔股票元資料且最新名單未提供，已跳過。';
          report();
          return;
        }
        try {
          final daily = await run.wait(_api.fetchDaily(stock.symbol, market,
              forceRefresh: force));
          if (_closed || !run.active) return;
          if (daily.isStale) throw const FormatException('日 K 為過期快取。');
          final adr = _engine.adrPercent(daily.completedDailyBars);
          var bundle = ChartBundle(daily: daily, intradayError: adr >= threshold
              ? '盤中資料尚未完成；僅供觀察，不確認突破。' : null);
          final dailyEvaluation = _engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc());
          if (_closed || !run.active) return;
          if (adr < threshold) { record(dailyEvaluation); return; }
          intradayPending.add(stock.symbol);
          record(dailyEvaluation);
          try {
            final intraday = await run.wait(_api.fetchIntraday(stock.symbol, market,
                forceRefresh: force));
            if (_closed || !run.active) return;
            if (intraday.isStale) throw const FormatException('盤中行情為過期快取。');
            bundle = ChartBundle(daily: daily, intraday: intraday);
          } catch (error) {
            if (_closed || !run.active) return;
            intradayFailures[stock.symbol] = _errorReason(error);
            bundle = ChartBundle(daily: daily,
                intradayError: '盤中資料取得失敗：${_errorReason(error)}');
          }
          if (_closed || !run.active) return;
          intradayPending.remove(stock.symbol);
          record(_engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc()));
        } catch (error) {
          if (_closed || !run.active) return;
          if (evaluations.containsKey(stock.symbol)) {
            intradayPending.remove(stock.symbol);
            intradayFailures[stock.symbol] = _errorReason(error);
          } else {
            failures[stock.symbol] = _errorReason(error);
          }
        } finally {
          if (!_closed && run.active) report();
        }
      }

      report();
      try {
        for (var offset = 0; offset < pool.length; offset += batchSize) {
          if (_closed || !run.active) break;
          final chunk = pool.skip(offset).take(batchSize).toList();
          // Start at most five real symbols. Record that actual attempted
          // prefix immediately, so background/disposal can resume correctly.
          final work = Future.wait(chunk.map(evaluateStock));
          // Observe both futures in this event turn. A slow storage plugin
          // cannot leave an aggregate network failure temporarily unhandled.
          await Future.wait<void>([
            persistProgress(), run.wait(work).then<void>((_) {}),
          ]);
          if (_closed || !run.active) break;
          await persistProgress();
          report();
          if (offset + chunk.length < pool.length) {
            await run.pause(interBatchDelay);
          }
        }
      } on TimeoutException {
        // The prefix already includes only actually started calls. Late
        // workers are observed by Future.wait, sealed below, and cannot write.
      }
      run.seal();
      if (_closed) throw RepositoryException('$marketLabel輪掃已取消。');
      for (final symbol in attempted.difference(evaluations.keys.toSet())) {
        failures.putIfAbsent(symbol, () => '整批期限內未完成日 K 或 RS 評估。');
      }
      var result = buildCheckpoint(finalPage: true);
      _checkpoints[key] = result;
      _activeThresholds[market] = threshold;
      if (!await _saveCheckpoint(result, budget: run.remaining)) {
        storageFailed = true;
        result = buildCheckpoint(finalPage: true);
        _checkpoints[key] = result;
      }
      if (_closed) throw RepositoryException('$marketLabel輪掃已取消。');
      final snapshot = result.toSnapshot();
      _snapshots[key] = snapshot;
      report(finished: true);
      return snapshot;
    } catch (error) {
      if (_closed) throw RepositoryException('$marketLabel輪掃已取消。');
      // Prerequisites may fail before a page can be built. End this attempt's
      // progress with zero new work; the retained journal is historical cache,
      // never a fabricated successful partial result from this request.
      _emitProgress(onProgress, MarketScanProgress(market: market,
        universeCount: checkpoint?.symbols.length ?? previous?.universeCount ?? 0,
        poolSize: 0, attemptedCount: 0, completedCount: 0,
        evaluatedCount: 0, adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
        finished: true, stage: '$marketLabel輪掃未完成：${_errorReason(error)}'));
      final fallback = _checkpoints[key]?.toSnapshot() ?? previous;
      if (fallback != null) {
        return _stale(fallback, '$marketLabel輪掃未完成，保留目前進度；${_errorReason(error)}');
      }
      if (error is RepositoryException) rethrow;
      throw RepositoryException('$marketLabel完整名單輪掃失敗：${_errorReason(error)}');
    } finally {
      run.seal();
      _runs.remove(run);
    }
  }

  StockCandidate _withPageRankingNote(StockCandidate value) =>
      StockCandidate.fromJson({...value.toJson(), 'notes': [
        ...value.notes.where((note) => !note.startsWith('RS 百分位') &&
            note != 'RS 為原掃描頁內排名，非全市場同步排名。'),
        'RS 為原掃描頁內排名，非全市場同步排名。',
      ]});

  String _checkpointKey(StockMarket market, double threshold) =>
      'martin-mobile-${market.name}-rolling-v1-$threshold';
  String _activeThresholdKey(StockMarket market) =>
      'martin-mobile-${market.name}-rolling-v1-active-threshold';

  Future<MobileScanCheckpoint?> _loadCheckpoint(StockMarket market, double threshold,
      LiveBatchDeadline run) async {
    try {
      final preferences = await _prefs().timeout(const Duration(milliseconds: 400));
      if (_closed || !run.active) return null;
      final active = double.tryParse(preferences.getString(_activeThresholdKey(market)) ?? '');
      if (active != null) _activeThresholds.putIfAbsent(market, () => active);
      final text = preferences.getString(_checkpointKey(market, threshold));
      if (text == null || text.length > 32 * 1024 * 1024) return null;
      final value = MobileScanCheckpoint.fromJson(
          jsonDecode(text) as Map<String, dynamic>);
      if (value.market != market || value.threshold != threshold || value.updatedAt.isAfter(_now().toUtc()) ||
          _now().toUtc().difference(value.updatedAt) > const Duration(days: 7)) return null;
      if (_closed || !run.active) return null;
      return value;
    } catch (_) { return null; }
  }

  Future<bool> _saveCheckpoint(MobileScanCheckpoint value,
      {required Duration budget}) async {
    if (_closed || budget <= Duration.zero) return false;
    final limit = budget < const Duration(milliseconds: 400)
        ? budget : const Duration(milliseconds: 400);
    final watch = Stopwatch()..start();
    try {
      final preferences = await _prefs().timeout(limit);
      var left = limit - watch.elapsed;
      if (_closed || left <= Duration.zero ||
          !identical(_checkpoints['${value.market.name}:${value.threshold}'], value)) return false;
      final saved = await preferences.setString(_checkpointKey(value.market, value.threshold),
          jsonEncode(value.toJson())).timeout(left);
      if (!saved) return false;
      left = limit - watch.elapsed;
      if (_closed || left <= Duration.zero ||
          !identical(_checkpoints['${value.market.name}:${value.threshold}'], value)) return false;
      return await preferences.setString(_activeThresholdKey(value.market),
          value.threshold.toString()).timeout(left);
    } catch (_) { return false; }
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
          final refreshed = evaluated.toCandidate(
              rsScore: candidate.rsScore, rsRank: candidate.rsRank);
          updated[candidate.symbol] = previous.candidatesAreCumulative
              ? _withPageRankingNote(refreshed) : refreshed;
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
        candidates: previous.candidates
            .map((candidate) => updated[candidate.symbol] ?? candidate)
            .where((candidate) => !previous.candidatesAreCumulative ||
                candidate.adrPercent >= threshold).toList(),
        fetchedAt: _now().toUtc(), scanCompletedAt: previous.scanCompletedAt,
        source: previous.source, universeCount: previous.universeCount,
        evaluatedCount: previous.evaluatedCount, universeIsComplete: previous.universeIsComplete,
        scanPoolSize: previous.scanPoolSize, adrMatchCount: previous.adrMatchCount,
        universeAsOf: previous.universeAsOf, stale: failed.isNotEmpty,
        candidatesAreCumulative: previous.candidatesAreCumulative,
        coverageTotalCount: previous.coverageTotalCount,
        coverageScannedCount: previous.coverageScannedCount,
        coverageEvaluatedCount: previous.coverageEvaluatedCount,
        coverageRemainingCount: previous.coverageRemainingCount,
        coverageRound: previous.coverageRound,
        scanPageStart: previous.scanPageStart,
        scanPageSize: previous.scanPageSize,
        universeFingerprint: previous.universeFingerprint,
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

  Future<SharedPreferences> _prefs() async => _preferences ??=
      await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));

  Future<void> _saveCache(StockMarket market, double threshold,
      CandidateSnapshot snapshot, {required Duration budget}) async {
    if (_closed || budget <= Duration.zero || !snapshot.candidatesAreCumulative) return;
    final key = '${market.name}:$threshold';
    final previous = _checkpoints[key];
    if (previous == null) return;
    final next = previous.withCandidates(snapshot.candidates, snapshot.fetchedAt);
    _checkpoints[key] = next;
    await _saveCheckpoint(next, budget: budget);
  }

  CandidateSnapshot _stale(CandidateSnapshot previous, String warning) => CandidateSnapshot(
    candidates: previous.candidates, fetchedAt: previous.fetchedAt,
    scanCompletedAt: previous.scanCompletedAt, source: '${previous.source}／上次真實快取',
    universeCount: previous.universeCount, evaluatedCount: previous.evaluatedCount,
    scanPoolSize: previous.scanPoolSize, adrMatchCount: previous.adrMatchCount,
    universeIsComplete: previous.universeIsComplete, universeAsOf: previous.universeAsOf,
    candidatesAreCumulative: previous.candidatesAreCumulative,
    coverageTotalCount: previous.coverageTotalCount,
    coverageScannedCount: previous.coverageScannedCount,
    coverageEvaluatedCount: previous.coverageEvaluatedCount,
    coverageRemainingCount: previous.coverageRemainingCount,
    coverageRound: previous.coverageRound,
    scanPageStart: previous.scanPageStart,
    scanPageSize: previous.scanPageSize,
    universeFingerprint: previous.universeFingerprint,
    stale: true, missingSymbols: previous.missingSymbols,
    warnings: [...previous.warnings, warning]);

  void close() {
    _closed = true;
    for (final run in _runs) { run.seal(); }
    if (_ownsApi) _api.close();
    if (_ownsUniverse) _universe.close();
  }
}
