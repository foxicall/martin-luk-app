#!/usr/bin/env python3
"""Offline 10-second scan upgrade for the existing Flutter project (Python 3.9+).
Accepts original branch, prior scan fix or this version. No Git or HTTP requests.
Checks every source before any write; backs up and rolls back failed installs.
"""
import argparse
import importlib.util
from pathlib import Path, PurePosixPath
import shutil
import sys
import zipfile

UPDATES = {
    'lib/app_controller.dart': {
        'base': '73d66392fc6882be1ae3666073b0c3325a2b066a00ddb1141751b1eb246437e1',
        'new': '10e081160be363eba26b42a927ef890199fb599b6f7d181d20de46b37d0d7372',
        'edits': [
            (37, 37, r"""  Timer? deadlineTimer;
  CandidateSnapshot? partialSnapshot;
"""),
            (39, 40, r""""""),
            (49, 49, r"""    deadlineTimer?.cancel();
    deadlineTimer = null;
"""),
            (84, 87, r"""        _scanUpdateTimeout = _boundedMarketTimeout(
            scanUpdateTimeout ?? const Duration(seconds: 8)),
        _directMarketScanTimeout = _boundedMarketTimeout(
            directMarketScanTimeout ?? scanUpdateTimeout ?? hardMarketScanTimeout),
"""),
            (97, 97, r"""
  /// Includes repository construction, metadata, requests and validation. A
  /// larger caller-supplied timeout cannot disable the market's hard deadline.
  static const hardMarketScanTimeout = Duration(seconds: 10);
  static Duration _boundedMarketTimeout(Duration requested) =>
      requested > hardMarketScanTimeout ? hardMarketScanTimeout : requested;
"""),
            (116, 120, r"""  // Full scans and hot quotes both obey the outer 10-second limit. Shorter
  // injected durations remain available for deterministic timeout tests.
"""),
            (345, 347, r"""  /// Pulls bypass the TTL. A queued forced follow-up shares the FIRST scan's
  /// deadline; repeated pulls cannot extend one continuously visible spinner.
"""),
            (356, 358, r""""""),
            (376, 377, r"""        forceRefresh, _boundedMarketTimeout(budget));
"""),
            (380, 380, r"""    operation.deadlineTimer = Timer(operation.budget,
        () => _expireMarketScan(operation));
"""),
            (390, 390, r"""
  bool _scanWithinDeadline(_RefreshOperation operation) =>
      _ownsScan(operation) && operation.remaining > Duration.zero;

  /// A separate watchdog releases the UI even if the worker never completes.
  /// Future.timeout alone does not cancel work; retiring ownership prevents all
  /// later callbacks, results and errors from overwriting the current market.
  void _expireMarketScan(_RefreshOperation operation) {
    if (!_ownsScan(operation)) return;
    final cacheKey = operation.key.substring(0, operation.key.lastIndexOf(':'));
    final reason = '市場掃描逾時（全流程最長 ${operation.budget.inMilliseconds / 1000} 秒）';
    debugPrint('[MarketScan] $reason；停止等待並保留可驗證資料。');
    _publishIncompleteScan(operation, cacheKey, reason);
    _finishMarketProgress('評估未完成（已達硬逾時）');
    _cancelScan();
    _notify();
  }

  void _publishIncompleteScan(_RefreshOperation operation,
      String cacheKey, String reason) {
    final partial = operation.partialSnapshot;
    final previous = _candidateSnapshots[cacheKey];
    if (partial != null) {
      _snapshot = _staleSnapshot(partial,
          '$reason；僅顯示本次已驗證的部分資料，評估尚未完成。');
      _error = '$reason；已保留 ${partial.evaluatedCount ?? 0} 檔已驗證資料，請重試完成掃描。';
    } else if (previous != null && !previous.isFallback) {
      _snapshot = _staleSnapshot(previous,
          '$reason；顯示上次快取，不可視為當前突破訊號。');
      _error = '$reason；保留 ${previous.generatedAt.toLocal()} 的快取。';
    } else {
      final progress = _marketScanProgress;
      _snapshot = CandidateSnapshot.fallback(marketType: _market,
          updatedAt: _now().toUtc(), universeCount: progress?.universeCount ?? 0,
          scanPoolSize: progress?.poolSize ?? 0, reason: reason);
      _error = '評估未完成：$reason。請檢查連線後重試。';
    }
    _page = _page.clamp(0, pageCount - 1).toInt();
  }
"""),
            (429, 429, r"""    final operation = _scanOperation!;
    final cacheKey = operation.key.substring(0, operation.key.lastIndexOf(':'));
    if (_snapshot == null || _snapshot!.isFallback || operation.partialSnapshot != null) {
      _publishIncompleteScan(operation, cacheKey, '市場掃描已停止');
    } else {
      _error = '市場掃描已停止；保留上次評估快照。';
    }
"""),
            (431, 432, r""""""),
            (444, 444, r"""      partialSnapshot: current.partialSnapshot,
"""),
            (449, 450, r"""    if (!_scanWithinDeadline(operation) || progress.market != market || market != _market) return;
"""),
            (465, 465, r"""    final partial = progress.partialSnapshot;
    if (partial != null) {
      try {
        if (partial.isFallback || (partial.evaluatedCount ?? 0) <= 0 ||
            partial.universeCount != progress.universeCount ||
            partial.evaluatedCount != progress.evaluatedCount ||
            partial.scanPoolSize != progress.poolSize ||
            partial.adrMatchCount != progress.adrMatchCount) {
          throw const RepositoryException('部分快照與已驗證進度不一致。');
        }
        final checked = _checkedCandidates(partial, market,
            allowMock: _settings.useMockData);
        if (!_scanWithinDeadline(operation)) return;
        operation.partialSnapshot = checked;
      } catch (error, stack) {
        debugPrint('[MarketScan] 已忽略無法驗證的部分快照：$error\n$stack');
      }
    }
"""),
            (476, 476, r"""    var timedOut = false;
"""),
            (484, 484, r"""      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描已達全域硬逾時。', operation.budget);
      }
"""),
            (496, 496, r"""      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描已達全域硬逾時。', operation.budget);
      }
"""),
            (498, 498, r"""      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描驗證已達全域硬逾時。', operation.budget);
      }
      if (checked.isFallback) {
        throw const RepositoryException('行情來源回傳兜底快照，市場評估尚未完成。');
      }
"""),
            (506, 506, r"""      timedOut = exception is TimeoutException;
"""),
            (512, 515, r""""""),
            (517, 520, r"""      _publishIncompleteScan(operation, cacheKey, reason);
"""),
            (523, 523, r"""        if (_snapshot == null) {
          _publishIncompleteScan(operation, cacheKey, '市場評估尚未取得可驗證結果');
        }
"""),
            (524, 525, r"""        final incomplete =
            (_snapshot?.scanPoolSize != null && _snapshot?.scanCompletedAt == null) ||
            (progress != null && progress.completedCount < progress.poolSize);
        final stage = !committed
            ? (timedOut ? '評估未完成（已達硬逾時）' : '更新失敗')
"""),
            (526, 528, r"""            : incomplete ? '本次評估已結束（部分完成）' : '評估已完成';
"""),
            (536, 537, r"""      if (owned && committed && operation.queuedForce != null && !_disposed &&
"""),
            (539, 544, r"""          // A forced follow-up inherits the original operation's remaining
          // deadline. It can never add another 10 seconds to this spinner.
          final queuedBudget = operation.budget;
          final remaining = operation.remaining;
"""),
            (556, 557, r"""      if (owned && !_disposed && _scanOperation == null) _notify();
"""),
            (627, 628, r"""      universeAsOf: response.universeAsOf, scanCompletedAt: response.scanCompletedAt,
      isFallback: response.isFallback, attemptedAt: response.attemptedAt);
"""),
            (648, 649, r"""        scanCompletedAt: value.scanCompletedAt, isFallback: value.isFallback,
        attemptedAt: _now().toUtc());
"""),
            (683, 684, r"""      // Partial direct scans have a genuine quote timestamp but no completed
      // scan timestamp. They must retry the full scan instead of polling only
      // their partial quote list forever. Legacy responses without pool counts
      // retain their historical fetchedAt compatibility.
      final completed = scan?.scanCompletedAt ??
          (scan?.scanPoolSize == null ? scan?.fetchedAt : null);
"""),
        ],
    },
    'lib/services/live_candidate_repository.dart': {
        'base': 'e3bf21dc6ca41e4c2aaaee7beb261411f755cbe59f64d1dcde96b3259a9f6445',
        'new': '8fea5292e053d0028b0db9b8986317c9c87d5cfbcd93fd0de6c6104504552a6c',
        'edits': [
            (22, 24, r"""    Duration scanBudget = const Duration(seconds: 9),
    Duration quoteRefreshBudget = const Duration(seconds: 6),
"""),
            (32, 32, r"""        scanBudget = _boundedBudget(scanBudget, 'scanBudget'),
        quoteRefreshBudget = _boundedBudget(quoteRefreshBudget, 'quoteRefreshBudget'),
"""),
            (36, 36, r"""  }

  /// The controller has a separate ten-second hard deadline. Leave a second
  /// for its validation/finally block; custom short test budgets stay short.
  static const maximumScanBudget = Duration(seconds: 9);

  static Duration _boundedBudget(Duration value, String name) {
    if (value <= Duration.zero) throw ArgumentError.value(value, name);
    return value > maximumScanBudget ? maximumScanBudget : value;
"""),
            (93, 93, r"""    CandidateSnapshot? latestPartial;
"""),
            (99, 100, r"""        finished: finished, stage: stage, partialSnapshot: latestPartial));
"""),
            (105, 106, r"""      // A partial scan's fresh quote time does not prove completion. Otherwise
      // one verified stock can suppress retries for the next fifteen minutes.
      final scanTime = previous?.scanCompletedAt;
"""),
            (157, 157, r"""      final intradayPending = <String>{};
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

"""),
            (168, 169, r"""          var bundle = ChartBundle(daily: daily, intradayError: adr >= threshold
              ? '盤中資料尚未完成；僅供日線動能觀察，不確認突破。' : null);
          // ADR/EMA/RS can be verified independently of a slow intraday API.
          // A real daily-only evaluation never manufactures an entry or stop.
          final dailyEvaluation = _engine.evaluate(stock: stock, data: bundle,
              benchmark: benchmark, now: _now().toUtc());
          if (_closed || !run.active) return;
"""),
            (170, 170, r"""            intradayPending.add(stock.symbol);
            recordEvaluation(dailyEvaluation);
"""),
            (183, 183, r"""            if (_closed || !run.active) return;
            intradayPending.remove(stock.symbol);
          } else {
            recordEvaluation(dailyEvaluation);
            return;
"""),
            (188, 194, r"""          recordEvaluation(evaluation);
"""),
            (196, 197, r"""          if (evaluations.any((row) => row.stock.symbol == stock.symbol)) {
            // An intraday parsing/calculation error cannot discard the daily
            // observation that already passed EMA and common-session RS checks.
            intradayPending.remove(stock.symbol);
            intradayFailures[stock.symbol] = _errorReason(error);
          } else {
            failures[stock.symbol] = _errorReason(error);
          }
"""),
            (199, 201, r"""            updateCounts();
            if (evaluations.isNotEmpty) publishPartial();
            else report('核心精選池評估');
"""),
            (243, 243, r"""      final scanComplete = missing.isEmpty && intradayPending.isEmpty;
"""),
            (244, 245, r"""        scanCompletedAt: scanComplete ? finished : null,
        source: scanComplete ? 'Yahoo Finance 直接連網核心精選掃描（公開行情可能延遲）'
            : 'Yahoo Finance 真實行情／市場評估未完成（部分資料）',
"""),
            (257, 257, r"""          if (intradayPending.isNotEmpty) '有 ${intradayPending.length} 檔盤中資料未於整批期限內完成；保留有效日 K，不確認突破。',
"""),
            (263, 264, r"""      latestPartial = scanComplete ? null : snapshot;
      report(scanComplete ? '評估完成' : '部分評估完成', finished: true);
"""),
            (484, 484, r"""        // Partial observations remain useful offline, but this flag and the
        // null completion time prohibit treating them as a completed scan.
        'scan_complete': snapshot.scanCompletedAt != null,
"""),
            (507, 508, r"""        scanCompletedAt: data['scan_complete'] == false ||
            data['scan_completed_at'] == null ? null :
"""),
            (514, 515, r"""        stale: true, warnings: [...(data['warnings'] as List).cast<String>(),
          if (data['scan_complete'] == false || data['scan_completed_at'] == null)
            '此快取僅含上次部分評估；市場掃描未完成，不能視為完整新評估。',
          '顯示上次真實行情快取，尚待連網更新。'],
"""),
        ],
    },
    'lib/services/market_scan_progress.dart': {
        'base': '9fb6f0bf23b7987a084ca6995864f41fb1b7ee8abe3a0d8fb5d4d939c15ba424',
        'new': 'a190e830f8d88842939f3d53f2f2fadf72540fc0939346935cda519afdc0e8a0',
        'edits': [
            (10, 11, r"""    required this.failedCount, required this.finished, required this.stage,
    this.partialSnapshot});
"""),
            (17, 17, r"""
  /// Only completed, validated provider observations are included. A progress
  /// snapshot is not a completed scan or a successful cache transaction; the
  /// controller may keep it if the outer deadline interrupts this run.
  final CandidateSnapshot? partialSnapshot;
"""),
        ],
    },
    'lib/screens/dashboard_screen.dart': {
        'base': '9c7899433868e5e71336afc79bf3cb6e20f3f622be2837e7059246101ea32811',
        'new': '0ebbae08590bcaa8690ef1d4811ebe7305c55284c1014bd5945e1cd6e19f1021',
        'edits': [
            (335, 336, r"""            Text(snapshot.isFallback
                ? '評估嘗試時間：${_date(snapshot.attemptedAt ?? snapshot.fetchedAt)}'
                : '資料更新時間：${_date(snapshot.fetchedAt)}',
"""),
            (346, 347, r"""              Text(snapshot.isFallback
                  ? '尚未完成股票池與行情驗證；0 表示未取得資料。'
                  : '目前使用本機股票清單；尚未確認完整最新上市成分。',
"""),
            (392, 392, r"""    final incomplete = _hasIncompleteScan;
"""),
            (409, 410, r"""    if (snapshot != null && snapshot.stale) {
"""),
            (412, 414, r"""        child: _warning(context, snapshot.isFallback ? '市場評估未完成'
            : incomplete ? '顯示已取得部分資料' : '顯示上次快取',
            snapshot.isFallback
                ? '本次未取得可驗證行情；顯示的是評估嘗試時間，可下拉或點選重試。'
                : '資料更新時間保留原始時間；請重新整理並確認最新行情後再評估進場。'),
"""),
            (530, 530, r"""  bool get _hasIncompleteScan {
    final snapshot = controller.snapshot;
    return !controller.settings.useMockData &&
        controller.settings.dataProvider == 'direct' &&
        snapshot != null && !snapshot.isFallback &&
        snapshot.scanPoolSize != null && snapshot.scanCompletedAt == null;
  }

"""),
            (539, 541, r"""              Text(controller.loading ? '正在掃描候選股'
                  : controller.snapshot == null || controller.snapshot!.isFallback
                      ? '市場評估未完成，請重試'
                      : _hasIncompleteScan ? '市場評估僅部分完成'
                      : controller.snapshot!.stale
                          ? '暫無可用推薦；目前顯示上次資料'
                          : '目前沒有符合條件的標的',
"""),
            (544, 548, r"""                  ? '掃描最多等待 10 秒；可點選右上方「停止掃描」。'
                  : controller.snapshot == null || controller.snapshot!.isFallback || controller.snapshot!.stale
                      ? '查看上方錯誤提示並下拉重試；未取得有效行情時不產生推薦。'
                      : _hasIncompleteScan
                          ? '已處理部分股票，尚未完成全部核心池；請下拉重試。'
                          : '本次評估已完成；可在設定調整 ADR 門檻，或下拉更新。',
"""),
        ],
    },
    'lib/services/candidate_repository.dart': {
        'base': 'c7d24ac4095ddfecf2bb50f7dc696b5f22a553bfa67164926d6fb39f62843013',
        'new': 'cdbcedca11a66fefb11214b5b6f898c84b58f3db607d2e7a7c219e0a793bb19b',
        'edits': [
            (23, 23, r"""    this.isFallback = false,
    this.attemptedAt,
"""),
            (26, 26, r"""
  /// A diagnostic terminal state, never a successful scan or a quote cache.
  /// Zero means the universe has not yet been loaded; no prices are invented.
  factory CandidateSnapshot.fallback({
    required StockMarket marketType,
    required DateTime updatedAt,
    int universeCount = 0,
    int scanPoolSize = 0,
    String reason = '市場評估未完成，請檢查連線後重試。',
  }) => CandidateSnapshot(
        candidates: const [], fetchedAt: updatedAt.toUtc(),
        attemptedAt: updatedAt.toUtc(),
        warnings: [reason],
        source: '${marketType == StockMarket.tw ? '台股' : '美股'}市場評估未完成',
        universeCount: universeCount, scanPoolSize: scanPoolSize,
        evaluatedCount: 0, adrMatchCount: 0,
        universeIsComplete: false, stale: true, isFallback: true,
      );
"""),
            (42, 42, r"""  /// This timestamp records the failed attempt, not a verified market quote.
  final DateTime? attemptedAt;
  final bool isFallback;
"""),
        ],
    },
    'test/market_scan_progress_test.dart': {
        'base': '1dc6a9c80aa077f93a111be1bd0c5aa9df11c2fef86d57c4341175b738df04cc',
        'new': '04ebed54ee405304df59c4db790da5c98450c32665230a87f924e18f2c9ca7ea',
        'edits': [
            (93, 94, r"""    expect(controller.snapshot!.isFallback, isTrue);
"""),
            (105, 106, r"""    expect(controller.snapshot!.isFallback, isTrue);
"""),
            (226, 227, r"""    expect(controller.marketScanProgress!.stage, contains('硬逾時'));
"""),
            (251, 252, r"""  test('queued full scan cannot extend the preceding scan deadline', () async {
"""),
            (266, 268, r"""    expect(controller.error, contains('逾時'));
    expect(controller.snapshot!.stale, isTrue);
"""),
            (269, 269, r"""    await Future<void>.delayed(const Duration(milliseconds: 60));
"""),
            (331, 332, r"""    expect(find.text('市場評估未完成，請重試'), findsOneWidget);
"""),
            (353, 354, r"""  testWidgets('failed cold scan retains counts with an explicit diagnostic fallback', (tester) async {
"""),
            (366, 367, r"""    expect(controller.snapshot!.isFallback, isTrue);
"""),
            (371, 372, r"""    expect(find.textContaining('核心股票池 HTTP 429'), findsWidgets);
"""),
        ],
    },
    'test/core_market_pool_test.dart': {
        'base': 'fc4ea312a0d57fb0e4f8df5f18b656286579dfa10b7b299a996daadc67a3e833',
        'new': '02d91cd20295192f057eaad864830bd2498ba87161b9bd85990f86fb2cf1ba05',
        'edits': [
            (1, 1, r"""import 'dart:convert';
"""),
            (36, 36, r"""  final dailyHolds = <String, Completer<MarketChart>>{};
  final intradayHolds = <String, Completer<MarketChart>>{};
"""),
            (50, 51, r"""      final pending = dailyHolds[symbol] ?? hold;
"""),
            (63, 63, r"""    final pending = intradayHolds[symbol];
    if (pending != null) return pending.future;
"""),
            (108, 108, r"""    expect(snapshot.fetchedAt, _now,
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
"""),
        ],
    },
    'test/app_controller_test.dart': {
        'base': 'c685bb8ccb6bdc9270832c47a2dcb4fd4facef1412ae160b34e6db4699f91e94',
        'new': 'c0aaceee9c96d7dd5ff0be489d3f4cf4f7a54b82ca1cb8e00ced3ccce0992fd9',
        'edits': [
            (88, 89, r"""    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.snapshot!.scanCompletedAt, isNull);
"""),
        ],
    },
    'test/market_scan_timeout_test.dart': {
        'base': None,
        'new': '1d409a531b046e4be03e6e2391df0b2aebf7156ed0cc18816a945c5ad3c66f1d',
        'edits': [
            (0, 0, r"""import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _quoteTime = DateTime.utc(2026, 10, 14, 15);
final _attemptTime = DateTime.utc(2026, 10, 14, 16);

StockCandidate _candidate(StockMarket market) => StockCandidate(
  id: '${market.name}:position', symbol: market == StockMarket.tw ? '2330.TW' : 'NVDA',
  name: 'Validated fixture', sector: '半導體', market: market,
  adrPercent: 6, rsScore: 90, rsRank: 1,
  patterns: ['PDH 突破'], entryPrice: 100, stopPrice: 98,
  isLargeLiquid: true, status: 'confirmed', dayLow: 98,
  triggerType: 'PDH', dataTimestamp: _quoteTime, signalTimestamp: _quoteTime,
);

CandidateSnapshot _snapshot(StockMarket market, {bool empty = false,
    bool partial = false, String source = 'Verified provider fixture'}) =>
    CandidateSnapshot(
      candidates: empty ? [] : [_candidate(market)], fetchedAt: _quoteTime,
      warnings: partial ? ['市場評估僅部分完成'] : [], source: source,
      universeCount: market == StockMarket.tw ? 900 : 500,
      scanPoolSize: 30, evaluatedCount: partial ? 2 : 30,
      adrMatchCount: empty ? 0 : 1, stale: false,
      scanCompletedAt: partial ? null : _quoteTime,
    );

class _Repository implements ProgressiveCandidateRepository {
  Completer<CandidateSnapshot>? waiting;
  CandidateSnapshot? partial;
  CandidateSnapshot? supplied;
  Object? failure;
  StockMarket? market;
  void Function(MarketScanProgress)? onProgress;
  int calls = 0;
  bool lastQuotesOnly = false;

  void report({int completed = 2, CandidateSnapshot? snapshot}) {
    final current = market;
    if (current == null) return;
    onProgress?.call(MarketScanProgress(
      market: current, universeCount: current == StockMarket.tw ? 900 : 500,
      poolSize: 30, attemptedCount: completed, completedCount: completed,
      evaluatedCount: completed, adrMatchCount: snapshot?.adrMatchCount ?? 0,
      confirmedCount: snapshot?.candidates.where((item) => item.isConfirmed).length ?? 0,
      failedCount: 0, finished: false, stage: '批次評估中', partialSnapshot: snapshot,
    ));
  }

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) => fetchWithProgress(market, adrThreshold: adrThreshold,
      forceRefresh: forceRefresh, refreshQuotesOnly: refreshQuotesOnly);

  @override
  Future<CandidateSnapshot> fetchWithProgress(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
    void Function(MarketScanProgress)? onProgress,
  }) {
    calls++;
    lastQuotesOnly = refreshQuotesOnly;
    this.market = market;
    this.onProgress = onProgress;
    report(completed: 0);
    if (partial != null) report(snapshot: partial);
    if (failure != null) return Future<CandidateSnapshot>.error(failure!);
    return waiting?.future ?? Future<CandidateSnapshot>.value(supplied ?? _snapshot(market));
  }
}

AppController _controller(_Repository repository, {
  Duration timeout = const Duration(milliseconds: 50),
  RepositoryFactory? factory,
}) => AppController(
  forceMockPreview: false, repositoryFactory: factory ?? (_) => repository,
  scanUpdateTimeout: timeout, now: () => _attemptTime,
  pollingInterval: const Duration(hours: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(const AppSettings(
        useMockData: false, dataProvider: 'direct', autoRefreshEnabled: false).toJson()),
  }));

  test('cold hanging scan settles its public future with a diagnostic fallback', () async {
    final pending = Completer<CandidateSnapshot>();
    final repository = _Repository()..waiting = pending;
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false)
        .timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.snapshot!.candidates, isEmpty);
    expect(controller.snapshot!.evaluatedCount, 0);
    expect(controller.snapshot!.attemptedAt, _attemptTime);
    expect(controller.snapshot!.scanCompletedAt, isNull);
    expect(controller.error, contains('逾時'));
    final diagnostic = controller.snapshot;
    pending.complete(_snapshot(StockMarket.tw, source: 'Late expired result'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot, same(diagnostic));
  });

  test('deadline preserves verified partial data and settles all queued refreshes', () async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    repository
      ..partial = _snapshot(StockMarket.tw, partial: true)
      ..waiting = Completer<CandidateSnapshot>();
    final first = controller.refresh(forceRefresh: false);
    final forced = controller.refresh();
    await Future.wait([first, forced]).timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    final kept = controller.snapshot!;
    expect(kept.isFallback, isFalse);
    expect(kept.stale, isTrue);
    expect(kept.evaluatedCount, 2);
    expect(kept.candidates.single.symbol, '2330.TW');
    expect(kept.candidates.single.entryPrice, 100);
    expect(kept.candidates.single.stopPrice, 98);
    expect(kept.scanCompletedAt, isNull);
    expect(kept.generatedAt, _quoteTime);
    expect(controller.error, contains('已驗證'));
    final calls = repository.calls;
    repository.report(completed: 30, snapshot: _snapshot(StockMarket.tw));
    repository.waiting!.complete(_snapshot(StockMarket.tw, source: 'Late expired result'));
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, calls); // No follow-up may extend an expired scan.
    expect(controller.snapshot, same(kept));
    expect(controller.marketScanProgress!.evaluatedCount, 2);
  });

  test('counts alone never manufacture a partial quote snapshot', () async {
    final repository = _Repository()..failure = StateError('cold failure');
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    repository
      ..failure = null
      ..waiting = Completer<CandidateSnapshot>();
    final running = controller.refresh();
    repository.report(completed: 10);
    await running.timeout(const Duration(seconds: 1));
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.snapshot!.candidates, isEmpty);
    expect(controller.snapshot!.evaluatedCount, 0);
    expect(controller.marketScanProgress!.evaluatedCount, 10);
    repository.waiting!.completeError(StateError('Consumed late failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test('timeout retains original cache time and a later retry recovers', () async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final pending = Completer<CandidateSnapshot>();
    repository.waiting = pending;
    await controller.refresh().timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.isFallback, isFalse);
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.snapshot!.generatedAt, _quoteTime);
    expect(controller.snapshot!.attemptedAt, _attemptTime);
    repository.waiting = null;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.snapshot!.stale, isFalse);
    expect(controller.snapshot!.isFallback, isFalse);
    pending.completeError(StateError('Expired response must not poison the retry'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNull);
  });

  test('successful empty scan remains a real dated result', () async {
    final repository = _Repository()..supplied = _snapshot(StockMarket.tw, empty: true);
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot!.candidates, isEmpty);
    expect(controller.snapshot!.isFallback, isFalse);
    expect(controller.snapshot!.stale, isFalse);
    expect(controller.snapshot!.generatedAt, _quoteTime);
    expect(controller.snapshot!.evaluatedCount, 30);
    expect(controller.error, isNull);
  });

  test('fresh but incomplete scan retries the full pool on the next poll', () async {
    SharedPreferences.setMockInitialValues({
      'martin_luk_settings_v1': jsonEncode(const AppSettings(
          useMockData: false, dataProvider: 'direct', autoRefreshEnabled: true).toJson()),
    });
    final freshPartial = CandidateSnapshot(
      candidates: [_candidate(StockMarket.tw)], fetchedAt: _attemptTime,
      warnings: ['市場評估僅部分完成'], source: 'Verified provider fixture',
      universeCount: 900, scanPoolSize: 30, evaluatedCount: 2,
      adrMatchCount: 1, stale: false, scanCompletedAt: null,
    );
    final repository = _Repository()..supplied = freshPartial;
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot!.stale, isFalse);
    expect(controller.snapshot!.scanCompletedAt, isNull);
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, 2);
    expect(repository.lastQuotesOnly, isFalse);
    expect(controller.marketScanProgress!.stage, contains('部分完成'));
  });

  test('repository factory failure releases lock and provides cold fallback', () async {
    final repository = _Repository();
    var failFactory = true;
    final controller = _controller(repository, factory: (_) {
      if (failFactory) throw StateError('Metadata service initialization failed');
      return repository;
    });
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.error, contains('initialization failed'));
    failFactory = false;
    await controller.refresh();
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    expect(controller.snapshot!.isFallback, isFalse);
  });

  test('stop cold scan produces a terminal fallback and ignores late notifications', () async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    repository.waiting = Completer<CandidateSnapshot>();
    final changed = controller.setMarket(StockMarket.us);
    controller.cancelMarketEvaluation();
    await changed.timeout(const Duration(seconds: 1));
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.snapshot!.source, contains('美股'));
    final stopped = controller.snapshot;
    var notifications = 0;
    controller.addListener(() => notifications++);
    repository.report(completed: 30, snapshot: _snapshot(StockMarket.us));
    repository.waiting!.complete(_snapshot(StockMarket.us));
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot, same(stopped));
    expect(notifications, 0);
  });

  testWidgets('larger timeout overrides cannot bypass the ten-second watchdog', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository, timeout: const Duration(minutes: 3));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    repository.waiting = Completer<CandidateSnapshot>();
    final running = controller.refresh();
    expect(AppController.hardMarketScanTimeout, const Duration(seconds: 10));
    expect(controller.loading, isTrue);
    await tester.pump(const Duration(seconds: 10));
    await running;
    expect(controller.loading, isFalse);
    expect(controller.error, contains('10.0 秒'));
    repository.waiting!.complete(_snapshot(StockMarket.tw));
    await tester.pump();
  });
}
"""),
        ],
    },
}


def load_previous_updater(project):
    source = project / 'scripts/apply_market_scan_fix.py'
    if not source.is_file():
        raise ValueError('Missing scripts/apply_market_scan_fix.py from the previous fix.')
    spec = importlib.util.spec_from_file_location('market_scan_previous_fix', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apply_edits(data, edits, expected_sha, digest, name):
    lines = [] if data is None else data.decode('utf-8').splitlines(keepends=True)
    last_end = 0
    for start, end, text in edits:
        if not (last_end <= start <= end <= len(lines)) or not isinstance(text, str):
            raise ValueError('Invalid edits: ' + name)
        last_end = end
    for start, end, text in reversed(edits):
        lines[start:end] = text.splitlines(keepends=True)
    result = ''.join(lines).encode('utf-8')
    if digest(result) != expected_sha:
        raise ValueError('Source checksum failed: ' + name)
    return result


def make_plan(project, previous):
    if not (project / 'pubspec.yaml').is_file():
        raise ValueError('Select the existing Flutter folder containing pubspec.yaml.')
    manifest = previous.load_manifest()
    plan, failures = {}, []
    for name in sorted(set(manifest) | set(UPDATES)):
        relative = PurePosixPath(name)
        path = project.joinpath(*relative.parts)
        if relative.is_absolute() or '..' in relative.parts or not path.resolve().is_relative_to(project):
            raise ValueError('Invalid source path: ' + name)
        current = previous.read_source(path) if path.is_file() else None
        current_sha = None if current is None else previous.digest(current)
        old = manifest.get(name)
        update = UPDATES.get(name)
        target_sha = update['new'] if update else old['new']
        if current_sha == target_sha:
            plan[name] = (path, current, False)
            continue
        intermediate = current
        if old and current_sha == old['old']:
            intermediate = apply_edits(current, old['edits'], old['new'], previous.digest, name)
        elif old and current_sha != old['new']:
            failures.append(name)
            continue
        elif not old and current_sha != update['base']:
            failures.append(name)
            continue
        if update:
            intermediate_sha = None if intermediate is None else previous.digest(intermediate)
            if intermediate_sha != update['base']:
                failures.append(name)
                continue
            intermediate = apply_edits(intermediate, update['edits'], update['new'], previous.digest, name)
        if previous.digest(intermediate) != target_sha:
            raise ValueError('Final checksum failed: ' + name)
        plan[name] = (path, intermediate, True)
    if failures:
        raise ValueError('No source files changed. Unrecognized source versions:\n' + '\n'.join(failures))
    return plan


def install(plan, previous):
    originals, installed = {}, []
    for name, (path, data, changed) in plan.items():
        if not changed:
            continue
        originals[name] = path.read_bytes() if path.is_file() else None
        if originals[name] is not None:
            backup = path.with_name(path.name + '.before-market-scan-timeout-fix')
            if backup.exists() and backup.read_bytes() != originals[name]:
                raise ValueError('Different backup already exists: ' + str(backup))
            if not backup.exists():
                shutil.copy2(path, backup)
    try:
        for name, (path, data, changed) in plan.items():
            if changed:
                previous.atomic_write(path, data)
                installed.append(name)
    except Exception:
        for name in reversed(installed):
            if originals[name] is None:
                plan[name][0].unlink(missing_ok=True)
            else:
                previous.atomic_write(plan[name][0], originals[name])
        raise
    for name, (_, _, changed) in plan.items():
        print(('UPDATED ' if changed else 'ALREADY CURRENT ') + name)


def export_zip(project, plan, output, previous):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, (_, data, _) in plan.items():
            archive.writestr(name, data)
        for name in ['scripts/apply_market_scan_fix.py',
                     'scripts/apply_market_scan_timeout_fix.py',
                     '.github/workflows/build_apk.yml']:
            archive.write(project / name, name)
        archive.writestr('README_MARKET_SCAN_TIMEOUT_FIX.txt',
            'Copy these verified files into your existing Flutter project.\n'
            'Global market evaluation deadline: 10 seconds; HTTP deadline: 8 seconds.\n'
            'Timeout releases the UI lock and retains verified partial/cache data.\n'
            'Otherwise a diagnostic fallback shows assessment incomplete, not zero recommendations.\n'
            'Run flutter pub get, flutter analyze and flutter test.\n'
            'Fresh live recommendation gate must pass before APK build.\n')
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP integrity failed.')
    print('SOURCE ZIP: ' + str(output))
    print('ZIP SHA256: ' + previous.digest(output.read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--show', help='Print one complete updated file without writing')
    parser.add_argument('--zip', dest='zip_path', type=Path)
    args = parser.parse_args()
    project = args.project.resolve()
    previous = load_previous_updater(project)
    plan = make_plan(project, previous)
    if args.show:
        if args.show not in plan:
            raise ValueError('Unknown source file: ' + args.show)
        sys.stdout.write(plan[args.show][1].decode('utf-8'))
    elif args.check:
        for name in plan:
            print('VERIFIED ' + name)
    else:
        install(plan, previous)
        if args.zip_path:
            output = args.zip_path if args.zip_path.is_absolute() else project / args.zip_path
            export_zip(project, plan, output, previous)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
