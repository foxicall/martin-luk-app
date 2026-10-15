import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'models/app_settings.dart';
import 'models/backend_scan_status.dart';
import 'models/stock_candidate.dart';
import 'models/portfolio_position.dart';
import 'services/candidate_repository.dart';
import 'services/exit_advisory_engine.dart';
import 'services/live_candidate_repository.dart';
import 'services/live_portfolio_repository.dart';
import 'services/market_scan_progress.dart';
import 'services/portfolio_repository.dart';
import 'services/reminder_service.dart';
import 'services/strategy_engine.dart';

enum CandidateSort { rs, adr, position }

typedef RepositoryFactory = CandidateRepository Function(AppSettings settings);
typedef PortfolioRepositoryFactory = PortfolioRepository Function(AppSettings settings);
typedef PreferenceWriter = Future<bool> Function(String key, String value);

/// One owner is installed before notifying listeners. Its public future always
/// settles, including cancellation, so a RefreshIndicator cannot stay spinning.
class _RefreshOperation {
  _RefreshOperation(this.key, this.version, this.force, this.budget);
  final String key;
  final int version;
  final bool force;
  final Duration budget;
  final elapsed = Stopwatch()..start();
  Duration get remaining => budget - elapsed.elapsed;
  final completion = Completer<void>();
  final cancelled = Completer<void>();
  Timer? deadlineTimer;
  CandidateSnapshot? partialSnapshot;
  Completer<void>? queuedForce;
  Stopwatch? queuedElapsed;
  bool queuedQuotesOnly = true;

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
    finish();
    finishQueued();
  }

  void finish() {
    deadlineTimer?.cancel();
    deadlineTimer = null;
    elapsed.stop();
    if (!completion.isCompleted) completion.complete();
  }

  void finishQueued() {
    queuedElapsed?.stop();
    final queued = queuedForce;
    if (queued != null && !queued.isCompleted) queued.complete();
  }
}

class _UpdateCancelled implements Exception {
  const _UpdateCancelled();
}

/// 將設定、來源、分頁與行情请求集中管理；過期请求不覆蓋最新市場。
class AppController extends ChangeNotifier {
  AppController({
    RepositoryFactory? repositoryFactory,
    PortfolioRepositoryFactory? portfolioRepositoryFactory,
    ReminderService? reminders,
    bool? forceMockPreview,
    Duration pollingInterval = const Duration(seconds: 60),
    Duration? scanUpdateTimeout,
    Duration? directMarketScanTimeout,
    Duration portfolioUpdateTimeout = const Duration(seconds: 8),
    Duration storageTimeout = const Duration(seconds: 2),
    Duration backendScanWaitTimeout = const Duration(minutes: 3),
    PreferenceWriter? preferenceWriter,
    DateTime Function()? now,
  })
      : _repositoryFactory = repositoryFactory ?? _defaultRepository,
        _portfolioRepositoryFactory = portfolioRepositoryFactory ?? _defaultPortfolioRepository,
        _reminders = reminders ?? ReminderService(),
        _forceMockPreview = forceMockPreview ?? AppConfig.forceMockPreview,
        _pollingInterval = pollingInterval,
        _scanUpdateTimeout = _boundedMarketTimeout(
            scanUpdateTimeout ?? const Duration(seconds: 8)),
        _directMarketScanTimeout = _boundedMarketTimeout(
            directMarketScanTimeout ?? scanUpdateTimeout ?? hardMarketScanTimeout),
        _portfolioUpdateTimeout = portfolioUpdateTimeout,
        _storageTimeout = storageTimeout,
        _backendScanWaitTimeout = backendScanWaitTimeout,
        _preferenceWriter = preferenceWriter,
        _now = now ?? DateTime.now {
    if ([pollingInterval, _scanUpdateTimeout, _directMarketScanTimeout,
        portfolioUpdateTimeout, storageTimeout, backendScanWaitTimeout]
        .any((duration) => duration <= Duration.zero)) {
      throw ArgumentError('更新間隔與逾時必須大於零。');
    }
  }

  /// Includes repository construction, metadata, requests and validation. A
  /// larger caller-supplied timeout cannot disable the market's hard deadline.
  static const hardMarketScanTimeout = Duration(seconds: 10);
  static Duration _boundedMarketTimeout(Duration requested) =>
      requested > hardMarketScanTimeout ? hardMarketScanTimeout : requested;

  static CandidateRepository _defaultRepository(AppSettings settings) =>
      settings.useMockData
          ? MockCandidateRepository()
          : settings.dataProvider == 'backend'
              ? RealCandidateRepository(baseUrl: settings.apiBaseUrl)
              : DirectLiveCandidateRepository();

  final RepositoryFactory _repositoryFactory;
  final PortfolioRepositoryFactory _portfolioRepositoryFactory;
  static PortfolioRepository _defaultPortfolioRepository(AppSettings settings) =>
      settings.useMockData ? MockPortfolioRepository() :
          settings.dataProvider == 'backend'
              ? RealPortfolioRepository(baseUrl: settings.apiBaseUrl)
              : DirectLivePortfolioRepository();
  final ReminderService _reminders;
  final bool _forceMockPreview;
  final Duration _pollingInterval;
  final Duration _scanUpdateTimeout;
  // Full scans and hot quotes both obey the outer 10-second limit. Shorter
  // injected durations remain available for deterministic timeout tests.
  final Duration _directMarketScanTimeout;
  final Duration _portfolioUpdateTimeout;
  final Duration _storageTimeout;
  final Duration _backendScanWaitTimeout;
  final PreferenceWriter? _preferenceWriter;
  final DateTime Function() _now;
  final Map<String, CandidateRepository> _candidateRepositories = {};
  final Map<String, PortfolioRepository> _portfolioRepositories = {};
  final Map<String, CandidateSnapshot> _candidateSnapshots = {};
  Timer? _pollTimer;
  Timer? _backendScanTimer;
  Timer? _backendWaitDeadline;
  Stopwatch? _backendWaitWatch;
  BackendScanStatus? _backendScanStatus;
  String? _backendScanKey;
  bool _backendScanWaiting = false;
  int _backendPollVersion = 0;

  /// These are server work timestamps, deliberately separate from quote age.
  BackendScanStatus? get backendScanStatus => _backendScanStatus;
  bool get waitingForBackendScan => _backendScanWaiting;
  bool get backendStatusPollingActive => _backendScanTimer != null;

  bool _foreground = false;
  bool _initialized = false;
  bool _pollBusy = false;
  int _pollVersion = 0;
  DateTime? _lastAutoRefreshAt;
  bool get autoRefreshActive => _pollTimer != null;
  bool get polling => _pollBusy;
  DateTime? get lastAutoRefreshAt => _lastAutoRefreshAt;
  bool get isSnapshotCached => _snapshot?.stale ?? false;
  DateTime? get lastUpdated => _snapshot?.generatedAt;
  _RefreshOperation? _scanOperation;
  _RefreshOperation? _portfolioOperation;
  static const _settingsKey = 'martin_luk_settings_v1';
  static const _portfolioKey = 'martin_luk_portfolio_v1';
  static const _portfolioRecoveryKey = 'martin_luk_portfolio_recovery_v1';
  static const pageSize = 6;
  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;
  StockMarket _market = StockMarket.tw;
  StockMarket get market => _market;
  CandidateSort _sort = CandidateSort.rs;
  CandidateSort get sort => _sort;
  CandidateSnapshot? _snapshot;
  CandidateSnapshot? get snapshot => _snapshot;
  bool _loading = false;
  bool get loading => _loading;
  bool get isEvaluatingMarket => _loading;
  MarketScanProgress? _marketScanProgress;
  MarketScanProgress? get marketScanProgress => _marketScanProgress;
  String? _error;
  String? get error => _error;
  int _page = 0;
  int get page => _page;
  int _requestVersion = 0;
  bool _disposed = false;
  SharedPreferences? _preferences;
  bool _portfolioStorageCorrupt = false;
  List<PortfolioPosition> _portfolioPositions = [];
  List<PortfolioPosition> get portfolioPositions => List.unmodifiable(_portfolioPositions);
  final Map<String, PortfolioQuote> _portfolioQuotes = {};
  Map<String, PortfolioQuote> get portfolioQuotes => Map.unmodifiable(_portfolioQuotes);
  final Map<String, String> _portfolioErrors = {};
  final Set<String> _cachedQuoteKeys = {};
  bool isPortfolioQuoteCached(String key) => _cachedQuoteKeys.contains(key);
  DateTime? get portfolioUpdatedAt {
    DateTime? latest;
    for (final quote in _portfolioQuotes.values) {
      if (latest == null || quote.quoteTimestamp.isAfter(latest)) {
        latest = quote.quoteTimestamp;
      }
    }
    return latest;
  }
  Map<String, String> get portfolioErrors => Map.unmodifiable(_portfolioErrors);
  final Map<String, PortfolioQuote> _mockQuoteOverrides = {};
  final Map<String, Map<String, Map<String, num>>> _observationHistory = {};
  final Set<String> _dirtyObservationSources = {};
  bool _portfolioLoading = false;
  bool get portfolioLoading => _portfolioLoading;
  int _portfolioRequestVersion = 0;
  double _euphoriaPercent = 20;
  double get euphoriaPercent => _euphoriaPercent;
  String? _portfolioNotice;
  final Set<String> _portfolioDataWarnings = {};
  String? get portfolioNotice {
    final notices = {if (_portfolioNotice != null) _portfolioNotice!,
      ..._portfolioDataWarnings};
    return notices.isEmpty ? null : notices.join('\n');
  }

  String _portfolioSource(AppSettings settings) => settings.useMockData ? 'mock' :
      settings.dataProvider == 'direct' ? 'direct:yahoo' :
      'api:${settings.apiBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}';

  void _captureObservations(String source) {
    final previous = _observationHistory[source] ?? {};
    _observationHistory[source] = {
      for (final holding in _portfolioPositions) holding.id: {
        'peak_r': holding.peakR, 'trailing_stop': holding.trailingStop,
        if (previous[holding.id]?['observed_at_ms'] != null)
          'observed_at_ms': previous[holding.id]!['observed_at_ms']!,
      },
    };
  }

  void _restoreObservations(String source) {
    final observations = _observationHistory[source] ?? {};
    _portfolioPositions = _portfolioPositions.map((holding) {
      final observation = observations[holding.id];
      if (observation == null) return holding.withObservation(0, holding.initialStop);
      final peak = observation['peak_r']!.toDouble();
      final stop = observation['trailing_stop']!.toDouble();
      if (stop < holding.initialStop) {
        throw const FormatException('觀察歷史的停損低於初始停損。');
      }
      return holding.withObservation(peak, stop);
    }).toList();
  }

  double equityFor(StockMarket market) => market == StockMarket.tw
      ? _settings.twEquity : _settings.usEquity;

  PortfolioDiagnosis? diagnosisFor(PortfolioPosition holding) {
    final quote = _portfolioQuotes[holding.key];
    if (quote == null) return null;
    try {
      final diagnosis = ExitAdvisoryEngine.evaluate(holding, quote, equityFor(holding.market),
          euphoriaPercent: _euphoriaPercent,
          observe: !isPortfolioQuoteCached(holding.key));
      if ([diagnosis.currentR, diagnosis.unrealizedPnl, diagnosis.positionPercent,
        diagnosis.emaBoundary, diagnosis.deviationPercent, ...diagnosis.targets.values]
          .any((value) => !value.isFinite)) {
        throw const FormatException('診斷結果超出可表示的有限數值範圍。');
      }
      return diagnosis;
    } catch (error, stack) {
      // A corrupt/extreme holding must not abort observation of other stocks.
      debugPrint('持股 ${holding.symbol} 診斷失敗：$error\n$stack');
      _portfolioErrors[holding.key] = '此持股診斷失敗，保留原始風控紀錄：$error';
      return null;
    }
  }

  double get equity =>
      _market == StockMarket.tw ? _settings.twEquity : _settings.usEquity;

  List<StockCandidate> get _filtered {
    final threshold = _market == StockMarket.tw
        ? _settings.twAdrThreshold
        : _settings.usAdrThreshold;
    final result = (_snapshot?.candidates ?? <StockCandidate>[])
        .where((candidate) => candidate.market == _market && candidate.adrPercent >= threshold)
        .toList();
    double positionPercent(StockCandidate candidate) {
      try {
        return StrategyEngine.calculate(candidate, equity).positionPercent;
      } on ArgumentError {
        return 0;
      } on FormatException {
        return 0;
      }
    }

    result.sort((a, b) {
      final comparison = switch (_sort) {
        CandidateSort.rs => b.rsScore.compareTo(a.rsScore),
        CandidateSort.adr => b.adrPercent.compareTo(a.adrPercent),
        CandidateSort.position => positionPercent(b).compareTo(positionPercent(a)),
      };
      return comparison == 0 ? a.symbol.compareTo(b.symbol) : comparison;
    });
    return result;
  }

  int get filteredCount => _filtered.length;
  int get pageCount => (filteredCount / pageSize).ceil().clamp(1, 1000000).toInt();
  List<StockCandidate> get visibleCandidates =>
      _filtered.skip(_page * pageSize).take(pageSize).toList();

  Future<void> initialize({bool initializeReminders = true}) async {
    if (_disposed) return;
    String? initializationNotice;
    try {
      _preferences = await _getPreferences();
      if (_disposed) return;
      final text = _preferences?.getString(_settingsKey);
      if (text != null) {
        final decoded = jsonDecode(text) as Map<String, dynamic>;
        _settings = AppSettings.fromJson(decoded);
        if (decoded['schema_version'] != 2) {
          // Keep the original preferences key so an installed demonstration APK
          // upgrades its accounts instead of silently creating new accounts.
          await _persist();
          initializationNotice = '已切換正式連網模式；原有帳戶本金與持股資料保留。';
        }
      }
    } catch (exception) {
      initializationNotice = '設定讀取失敗，使用預設值：$exception';
    }
    if (_disposed) return;
    // Apply explicit preview intent after reading preferences, so a saved live
    // setting cannot trigger network requests on the offline phone preview.
    // Do not persist this override: opening the normal URL retains that choice.
    if (_forceMockPreview) {
      _settings = _settings.copyWith(useMockData: true);
    }
    await _loadPortfolio();
    if (_disposed) return;
    if (initializeReminders) {
      try {
        await _reminders.initialize().timeout(_scanUpdateTimeout);
        if (_disposed) return;
        if (_settings.remindersEnabled) {
          final enabled = await _reminders.setEnabled(true).timeout(_scanUpdateTimeout);
          if (_disposed) return;
          if (!enabled) {
            _settings = _settings.copyWith(remindersEnabled: false);
            initializationNotice = '通知權限未開啟，提醒維持關閉。';
          }
        }
      } catch (exception) {
        _settings = _settings.copyWith(remindersEnabled: false);
        initializationNotice = '提醒服務尚未就緒：$exception';
      }
    }
    if (_disposed) return;
    await Future.wait([refresh(forceRefresh: false), refreshPortfolio(forceRefresh: false)]);
    if (_disposed) return;
    _initialized = true;
    _syncPolling();
    if (initializationNotice != null) {
      _error = [_error, initializationNotice].whereType<String>().join('\n');
      _notify();
    }
  }

  /// Pulls bypass the TTL. A queued forced follow-up shares the FIRST scan's
  /// deadline; repeated pulls cannot extend one continuously visible spinner.
  Future<void> refresh({bool forceRefresh = true, bool refreshQuotesOnly = false}) {
    if (_disposed) return Future<void>.value();
    final key = _scanKey();
    final active = _scanOperation;
    if (active != null && active.key == key && active.version == _requestVersion) {
      if (forceRefresh && !active.force) {
        active.queuedForce ??= Completer<void>();
        active.queuedElapsed ??= Stopwatch()..start();
        active.queuedQuotesOnly = active.queuedQuotesOnly && refreshQuotesOnly;
        return active.queuedForce!.future;
      }
      return active.completion.future;
    }
    return _beginScan(forceRefresh: forceRefresh,
        refreshQuotesOnly: refreshQuotesOnly,
        budget: _marketRefreshBudget(refreshQuotesOnly: refreshQuotesOnly));
  }

  Duration _marketRefreshBudget({required bool refreshQuotesOnly}) =>
      !_settings.useMockData && _settings.dataProvider == 'direct' &&
          !refreshQuotesOnly ? _directMarketScanTimeout : _scanUpdateTimeout;

  Future<void> _beginScan({required bool forceRefresh,
      required bool refreshQuotesOnly, required Duration budget}) {
    _cancelScan();
    _cancelBackendTimer();
    _marketScanProgress = null;
    final operation = _RefreshOperation(_scanKey(), ++_requestVersion,
        forceRefresh, _boundedMarketTimeout(budget));
    // Do this BEFORE the worker's notifyListeners or repository factory: a
    // listener may synchronously call refresh again.
    _scanOperation = operation;
    operation.deadlineTimer = Timer(operation.budget,
        () => _expireMarketScan(operation));
    unawaited(_refresh(operation, refreshQuotesOnly: refreshQuotesOnly));
    return operation.completion.future;
  }

  String _scanKey() => '${_portfolioSource(_settings)}:${_market.name}:'
      '${_market == StockMarket.tw ? _settings.twAdrThreshold : _settings.usAdrThreshold}';

  bool _ownsScan(_RefreshOperation operation) => !_disposed &&
      identical(_scanOperation, operation) && operation.version == _requestVersion &&
      operation.key == _scanKey();

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
    _failBackendWaiting(reason);
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

  Future<T> _awaitUpdate<T>(Future<T> work, _RefreshOperation operation,
      Duration timeout) {
    // Attach error handlers even when the remaining budget reached zero. A
    // just-started HTTP future may otherwise deliver an unhandled late error.
    return Future.any<T>([
      work,
      operation.cancelled.future.then<T>((_) => throw const _UpdateCancelled()),
    ]).timeout(timeout > Duration.zero ? timeout : Duration.zero);
  }

  void _retireCandidate(String cacheKey, CandidateRepository repository) {
    if (identical(_candidateRepositories[cacheKey], repository)) {
      _candidateRepositories.remove(cacheKey);
    }
    try {
      if (repository is RealCandidateRepository) repository.close();
      if (repository is DirectLiveCandidateRepository) repository.close();
    } catch (error, stack) {
      debugPrint('關閉行情掃描服務失敗：$error\n$stack');
    }
  }

  void _cancelScan() {
    final active = _scanOperation;
    if (active == null) return;
    _scanOperation = null;
    active.cancel();
    _loading = false;
    final cacheKey = active.key.substring(0, active.key.lastIndexOf(':'));
    final repository = _candidateRepositories[cacheKey];
    if (repository != null) _retireCandidate(cacheKey, repository);
  }

  /// Stops this phone's status requests, not the shared server-side scan.
  /// Retiring request ownership also prevents a late HTTP reply from committing.
  void cancelMarketEvaluation() {
    if (_disposed) return;
    final operation = _scanOperation;
    if (_backendScanWaiting ||
        (_backendScanStatus?.isRunning ?? false)) {
      _backendScanWaiting = false;
      _cancelBackendTimer();
      _stopBackendWaitDeadline();
      _cancelScan();
      _error = null;
      _notify();
      return;
    }
    if (operation == null) return;
    final cacheKey = operation.key.substring(0, operation.key.lastIndexOf(':'));
    if (_snapshot == null || _snapshot!.isFallback || operation.partialSnapshot != null) {
      _publishIncompleteScan(operation, cacheKey, '市場掃描已停止');
    } else {
      _error = '市場掃描已停止；保留上次評估快照。';
    }
    _cancelScan();
    _finishMarketProgress('掃描已停止');
    _notify();
  }

  void _cancelBackendTimer() {
    _backendPollVersion++;
    _backendScanTimer?.cancel();
    _backendScanTimer = null;
  }

  void _resetBackendWaiting() {
    _cancelBackendTimer();
    _backendScanWaiting = false;
    _backendScanKey = null;
    _backendScanStatus = null;
    _stopBackendWaitDeadline();
  }

  void _stopBackendWaitDeadline() {
    _backendWaitDeadline?.cancel();
    _backendWaitDeadline = null;
    _backendWaitWatch?.stop();
    _backendWaitWatch = null;
  }

  void _syncBackendWaitDeadline() {
    _backendWaitDeadline?.cancel();
    _backendWaitDeadline = null;
    if (_disposed || !_foreground || !_backendScanWaiting) {
      _backendWaitWatch?.stop();
      return;
    }
    final watch = _backendWaitWatch ??= Stopwatch();
    watch.start();
    final remaining = _backendScanWaitTimeout - watch.elapsed;
    _backendWaitDeadline = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () {
        if (_disposed || !_foreground || !_backendScanWaiting) return;
        const reason = '等待 Python 背景掃描超過上限，已停止查詢進度。'
            '後端可能仍在執行；請稍後下拉重試。';
        _failBackendWaiting(reason);
        _cancelScan();
        final previous = _snapshot;
        if (previous != null && !previous.isFallback) {
          _snapshot = _staleSnapshot(previous, reason);
        }
        _error = reason;
        _notify();
      },
    );
  }

  void _failBackendWaiting(String reason) {
    _cancelBackendTimer();
    _stopBackendWaitDeadline();
    _backendScanWaiting = false;
    final current = _backendScanStatus;
    if (current != null && current.isRunning) {
      _backendScanStatus = current.withClientFailure(reason);
    }
  }

  void _acceptBackendStatus(CandidateSnapshot response,
      _RefreshOperation operation) {
    final status = response.backendScan;
    if (status == null) {
      _resetBackendWaiting(); // Compatibility with a completed legacy backend.
      return;
    }
    if (_settings.useMockData || _settings.dataProvider != 'backend' ||
        status.market != _market) {
      throw const RepositoryException('背景掃描進度的市場或資料來源不符。');
    }
    if (_backendScanStatus?.jobId != status.jobId) {
      _stopBackendWaitDeadline();
    }
    _backendScanStatus = status;
    _backendScanKey = operation.key;
    _backendScanWaiting = status.isRunning;
    if (!status.isRunning) {
      _cancelBackendTimer();
      _stopBackendWaitDeadline();
    } else {
      _syncBackendWaitDeadline();
    }
    if (status.isFailed) {
      _error = 'Python 背景掃描失敗：${status.error ?? '請檢查後端服務後重試。'}';
    }
  }

  /// Every tick makes exactly one bounded HTTP request. A 202 response settles
  /// its RefreshIndicator immediately; the independent timer asks again later.
  void _scheduleBackendStatusPoll({bool immediately = false}) {
    _cancelBackendTimer();
    final status = _backendScanStatus;
    final key = _backendScanKey;
    if (_disposed || !_foreground || !_backendScanWaiting ||
        status == null || !status.isRunning || key != _scanKey() ||
        _settings.useMockData || _settings.dataProvider != 'backend' ||
        _scanOperation != null) return;
    final version = _backendPollVersion;
    final delay = immediately ? Duration.zero :
        Duration(seconds: status.retryAfterSeconds.clamp(1, 60).toInt());
    _backendScanTimer = Timer(delay, () {
      _backendScanTimer = null;
      if (_disposed || !_foreground || !_backendScanWaiting ||
          version != _backendPollVersion || key != _scanKey() ||
          _scanOperation != null) return;
      unawaited(refresh(forceRefresh: false, refreshQuotesOnly: true));
    });
  }

  void _finishMarketProgress(String stage) {
    final current = _marketScanProgress;
    if (current == null) return;
    _marketScanProgress = MarketScanProgress(
      market: current.market, universeCount: current.universeCount,
      poolSize: current.poolSize, attemptedCount: current.attemptedCount,
      completedCount: current.completedCount, evaluatedCount: current.evaluatedCount,
      adrMatchCount: current.adrMatchCount, confirmedCount: current.confirmedCount,
      failedCount: current.failedCount, finished: true, stage: stage,
      partialSnapshot: current.partialSnapshot,
    );
  }

  void _acceptMarketProgress(_RefreshOperation operation,
      StockMarket market, MarketScanProgress progress) {
    if (!_scanWithinDeadline(operation) || progress.market != market || market != _market) return;
    // Progress is presentation only. Reject inconsistent or backwards counts
    // without turning them into successful evaluations or trade signals.
    if (progress.universeCount < 0 || progress.poolSize < 0 ||
        progress.poolSize > progress.universeCount || progress.attemptedCount < 0 ||
        progress.attemptedCount > progress.poolSize || progress.completedCount < 0 ||
        progress.completedCount > progress.attemptedCount || progress.evaluatedCount < 0 ||
        progress.evaluatedCount > progress.completedCount || progress.adrMatchCount < 0 ||
        progress.adrMatchCount > progress.evaluatedCount || progress.confirmedCount < 0 ||
        progress.confirmedCount > progress.adrMatchCount || progress.failedCount < 0 ||
        progress.failedCount > progress.completedCount ||
        (_marketScanProgress != null &&
          progress.completedCount < _marketScanProgress!.completedCount)) {
      debugPrint('[MarketEvaluation] 已忽略不一致的掃描進度。');
      return;
    }
    final partial = progress.partialSnapshot;
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
    _marketScanProgress = progress;
    _notify();
  }

  Future<void> _refresh(_RefreshOperation operation,
      {required bool refreshQuotesOnly}) async {
    final requestMarket = _market;
    final currentSettings = _settings;
    final cacheKey = '${_portfolioSource(currentSettings)}:${requestMarket.name}';
    CandidateRepository? repository;
    var committed = false;
    var pending = false;
    var timedOut = false;
    try {
      if (!_ownsScan(operation)) return;
      _loading = true;
      _error = null;
      _notify();
      if (!_ownsScan(operation)) return;
      repository = _candidateRepositories.putIfAbsent(cacheKey,
          () => _repositoryFactory(currentSettings));
      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描已達全域硬逾時。', operation.budget);
      }
      final threshold = requestMarket == StockMarket.tw
          ? currentSettings.twAdrThreshold : currentSettings.usAdrThreshold;
      final work = repository is ProgressiveCandidateRepository
          ? repository.fetchWithProgress(requestMarket,
              adrThreshold: threshold, forceRefresh: operation.force,
              refreshQuotesOnly: refreshQuotesOnly,
              onProgress: (progress) =>
                  _acceptMarketProgress(operation, requestMarket, progress))
          : repository.fetch(requestMarket, adrThreshold: threshold,
              forceRefresh: operation.force, refreshQuotesOnly: refreshQuotesOnly);
      final response = await _awaitUpdate(work, operation, operation.remaining);
      if (!_ownsScan(operation)) return;
      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描已達全域硬逾時。', operation.budget);
      }
      if (response.isPending) {
        final status = response.backendScan;
        if (status == null || !status.isRunning ||
            response.candidates.isNotEmpty) {
          throw const RepositoryException('等待中的背景掃描回應格式無效。');
        }
        _acceptBackendStatus(response, operation);
        // Do not persist a progress timestamp as quote data, create a fake
        // empty successful scan, or replace a genuine previous snapshot.
        if (_snapshot?.isFallback ?? false) _snapshot = null;
        pending = true;
        return;
      }
      final checked = _checkedCandidates(response, requestMarket,
          allowMock: currentSettings.useMockData);
      if (!_scanWithinDeadline(operation)) {
        throw TimeoutException('市場掃描驗證已達全域硬逾時。', operation.budget);
      }
      if (checked.isFallback) {
        throw const RepositoryException('行情來源回傳兜底快照，市場評估尚未完成。');
      }
      _acceptBackendStatus(response, operation);
      _snapshot = checked;
      _candidateSnapshots[cacheKey] = checked;
      _page = _page.clamp(0, pageCount - 1).toInt();
      committed = true;
    } on _UpdateCancelled {
      // Cancellation settles the public future; it is not a failed new source.
    } catch (exception, stack) {
      if (!_ownsScan(operation)) return;
      timedOut = exception is TimeoutException;
      if (exception is TimeoutException && repository != null) {
        // Retrying must get a fresh client, not the expired repository's pending
        // future. Late completion is consumed by _awaitUpdate and cannot commit.
        _retireCandidate(cacheKey, repository);
      }
      _failBackendWaiting('$exception');
      debugPrint('行情更新失敗：$exception\n$stack');
      final reason = exception is TimeoutException
          ? '行情更新逾時（本次最長 ${operation.budget.inMilliseconds / 1000} 秒）' : '$exception';
      _publishIncompleteScan(operation, cacheKey, reason);
    } finally {
      final owned = _ownsScan(operation);
      if (owned) {
        if (_snapshot == null && !pending) {
          _publishIncompleteScan(operation, cacheKey, '市場評估尚未取得可驗證結果');
        }
        final progress = _marketScanProgress;
        final incomplete =
            (_snapshot?.scanPoolSize != null && _snapshot?.scanCompletedAt == null) ||
            (progress != null && progress.completedCount < progress.poolSize);
        final stage = !committed
            ? (timedOut ? '評估未完成（已達硬逾時）' : '更新失敗')
            : (_snapshot?.stale ?? false) ? '顯示上次快取'
            : incomplete ? '本次評估已結束（部分完成）' : '評估已完成';
        if (!pending) _finishMarketProgress(stage);
      }
      if (identical(_scanOperation, operation)) {
        _scanOperation = null;
        _loading = false;
      }
      operation.finish();
      // The next owner is installed before any notification can re-enter us.
      if (owned && committed && operation.queuedForce != null && !_disposed &&
          operation.key == _scanKey()) {
        try {
          // A forced follow-up inherits the original operation's remaining
          // deadline. It can never add another 10 seconds to this spinner.
          final queuedBudget = operation.budget;
          final remaining = operation.remaining;
          if (remaining > Duration.zero) {
            await _beginScan(forceRefresh: true,
                refreshQuotesOnly: operation.queuedQuotesOnly, budget: remaining);
          } else {
            _error ??= '行情更新已達 ${queuedBudget.inMilliseconds / 1000} 秒總時限，請重試。';
          }
        } finally {
          operation.finishQueued();
        }
      } else {
        operation.finishQueued();
      }
      if (owned && !_disposed && _scanOperation == null) {
        _scheduleBackendStatusPoll();
        _notify();
      }
    }
  }

  bool _demoSource(String source) => RegExp(
      r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(source);

  CandidateSnapshot _checkedCandidates(CandidateSnapshot response,
      StockMarket market, {required bool allowMock}) {
    if (response.isPending) {
      throw const RepositoryException('背景掃描進度不是已完成的行情快照。');
    }
    final evaluated = response.evaluatedCount;
    final poolSize = response.scanPoolSize;
    final adrMatches = response.adrMatchCount;
    if (response.source.trim().isEmpty || response.universeCount < 0 ||
        (evaluated != null && (evaluated < 0 || evaluated > response.universeCount)) ||
        (poolSize != null && (poolSize < 0 || poolSize > response.universeCount ||
            (evaluated != null && evaluated > poolSize))) ||
        (adrMatches != null && (adrMatches < 0 ||
            adrMatches > (evaluated ?? poolSize ?? response.universeCount))) ||
        (!allowMock && _demoSource(response.source))) {
      throw const RepositoryException('掃描回應的來源或股票池統計無效；未載入該回應。');
    }
    if (!response.stale && response.universeCount > 0 && evaluated == 0) {
      throw const RepositoryException('本次股票池未成功評估任何股票；這並非「沒有符合條件的候選」，請檢查行情來源後重試。');
    }
    final accepted = <StockCandidate>[];
    final seenSymbols = <String>{};
    final seenIds = <String>{};
    final missing = {...response.missingSymbols};
    final warnings = [...response.warnings];
    for (final candidate in response.candidates) {
      String? reason;
      final canonical = (market == StockMarket.tw
          ? RegExp(r'^\d{4}\.(?:TW|TWO)$') : RegExp(r'^[A-Z][A-Z0-9-]{0,14}$'))
          .hasMatch(candidate.symbol);
      if (candidate.market != market || !canonical) {
        reason = '市場或標準股票代碼不符';
      } else if (seenSymbols.contains(candidate.symbol) || seenIds.contains(candidate.id)) {
        reason = '重複代碼或識別碼';
      } else if (candidate.isConfirmed && (!candidate.hasValidStopRange ||
          (candidate.stopSource == 'day_low' && candidate.dayLow != null &&
              candidate.dayLow != candidate.stopPrice) ||
          (candidate.stopSource == 'entry_bar_low' &&
              (candidate.entryBarLow != candidate.stopPrice || candidate.dayLow == null ||
               (candidate.entryPrice - candidate.dayLow!) / candidate.entryPrice <= 0.05 ||
               candidate.dayLow! > candidate.stopPrice!)))) {
        reason = '已確認訊號的實際低點或停損距離不符風控規則';
      }
      if (reason != null) {
        missing.add(candidate.symbol);
        warnings.add('已排除 ${candidate.symbol}：$reason；其他有效候選照常顯示。');
        continue;
      }
      accepted.add(candidate);
      seenSymbols.add(candidate.symbol);
      seenIds.add(candidate.id);
    }
    if (accepted.length > response.universeCount ||
        (evaluated != null && accepted.length > evaluated)) {
      throw const RepositoryException('有效候選數量超過股票池或成功評估數量。');
    }
    if (response.candidates.isNotEmpty && accepted.isEmpty) {
      throw const RepositoryException('回應中的候選資料全部無效，保留上次可驗證快取。');
    }
    // An actually successful empty scan is valid. It must replace an old list,
    // rather than masquerading as a request failure or inventing recommendations.
    missing.removeAll(seenSymbols);
    return CandidateSnapshot(candidates: accepted, fetchedAt: response.fetchedAt,
      warnings: warnings, source: response.source, universeCount: response.universeCount,
      stale: response.stale, missingSymbols: missing.toList()..sort(),
      evaluatedCount: evaluated, scanPoolSize: poolSize, adrMatchCount: adrMatches,
      universeIsComplete: response.universeIsComplete,
      universeAsOf: response.universeAsOf, scanCompletedAt: response.scanCompletedAt,
      isFallback: response.isFallback, attemptedAt: response.attemptedAt,
      backendScan: response.backendScan, isPending: response.isPending,
      coverageTotalCount: response.coverageTotalCount,
      coverageScannedCount: response.coverageScannedCount,
      coverageEvaluatedCount: response.coverageEvaluatedCount,
      coverageRemainingCount: response.coverageRemainingCount,
      coverageRound: response.coverageRound,
      scanPageStart: response.scanPageStart,
      scanPageSize: response.scanPageSize,
      universeFingerprint: response.universeFingerprint);
  }

  Future<void> setMarket(StockMarket value) async {
    if (_disposed || _market == value) return;
    _cancelScan();
    _resetBackendWaiting();
    _marketScanProgress = null;
    _market = value;
    _page = 0;
    final saved = _candidateSnapshots['${_portfolioSource(_settings)}:${value.name}'];
    _snapshot = saved == null ? null : _staleSnapshot(saved, '市場切換中，暫顯示上次快取。');
    await refresh(forceRefresh: false);
  }

  CandidateSnapshot _staleSnapshot(CandidateSnapshot value, String warning) =>
      CandidateSnapshot(candidates: value.candidates, fetchedAt: value.fetchedAt,
        warnings: {...value.warnings, warning}.toList(), source: value.source,
        universeCount: value.universeCount, stale: true,
        missingSymbols: value.missingSymbols, evaluatedCount: value.evaluatedCount,
        scanPoolSize: value.scanPoolSize, adrMatchCount: value.adrMatchCount,
        universeIsComplete: value.universeIsComplete, universeAsOf: value.universeAsOf,
        scanCompletedAt: value.scanCompletedAt, isFallback: value.isFallback,
        attemptedAt: _now().toUtc(), backendScan: value.backendScan,
        isPending: value.isPending,
        coverageTotalCount: value.coverageTotalCount,
        coverageScannedCount: value.coverageScannedCount,
        coverageEvaluatedCount: value.coverageEvaluatedCount,
        coverageRemainingCount: value.coverageRemainingCount,
        coverageRound: value.coverageRound,
        scanPageStart: value.scanPageStart,
        scanPageSize: value.scanPageSize,
        universeFingerprint: value.universeFingerprint);

  /// The Flutter lifecycle owner explicitly enables polling only while visible.
  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    if (!value) {
      _cancelBackendTimer();
      _syncBackendWaitDeadline();
      // Stop this phone's in-flight status request on backgrounding. The
      // server continues independently; its job is not cancelled by the phone.
      if (!_settings.useMockData && _settings.dataProvider == 'backend') {
        _cancelScan();
      }
    }
    _syncPolling();
    if (value && _backendScanWaiting) {
      _syncBackendWaitDeadline();
      _scheduleBackendStatusPoll(immediately: true);
    } else if (value && _initialized && _settings.autoRefreshEnabled &&
        !_settings.useMockData && (_lastAutoRefreshAt == null ||
          _now().difference(_lastAutoRefreshAt!) >= _pollingInterval)) {
      unawaited(pollNow());
    }
  }

  void _syncPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_disposed && _initialized && _foreground &&
        _settings.autoRefreshEnabled && !_settings.useMockData) {
      _pollTimer = Timer.periodic(_pollingInterval, (_) => unawaited(pollNow()));
    }
    _notify();
  }

  /// Public for lifecycle tests and a manual foreground update. Concurrent
  /// ticks and pull-to-refresh requests never start overlapping poll batches.
  Future<void> pollNow() async {
    if (_disposed || !_initialized || !_foreground ||
        !_settings.autoRefreshEnabled || _settings.useMockData ||
        _pollBusy || _loading || _portfolioLoading || _backendScanWaiting ||
        (_backendScanStatus?.isRunning ?? false) ||
        (_backendScanStatus?.isFailed ?? false)) return;
    _pollBusy = true;
    final version = ++_pollVersion;
    try {
      _notify();
      final scan = _snapshot;
      // Partial direct scans have a genuine quote timestamp but no completed
      // scan timestamp. They must retry the full scan instead of polling only
      // their partial quote list forever. Legacy responses without pool counts
      // retain their historical fetchedAt compatibility.
      final completed = scan?.scanCompletedAt ??
          (scan?.scanPoolSize == null ? scan?.fetchedAt : null);
      final age = completed == null ? null : _now().toUtc().difference(completed);
      // A hot poll must stay small, but a failed cold start or expired full
      // scan must still recover automatically. Never treat a clock anomaly or
      // a stale fallback as a recent successful universe scan.
      final quotesOnly = scan != null && !scan.stale && age != null &&
          !age.isNegative && age < const Duration(minutes: 15);
      await Future.wait([
        refresh(forceRefresh: false, refreshQuotesOnly: quotesOnly),
        refreshPortfolio(forceRefresh: false),
      ]);
      if (!_disposed && version == _pollVersion) {
        _lastAutoRefreshAt = _now().toUtc();
      }
    } catch (error, stack) {
      // Timer callbacks are deliberately unawaited by the lifecycle owner, so
      // never leak an exception into the zone and strand the polling lock.
      debugPrint('定時行情更新失敗：$error\n$stack');
      if (!_disposed && version == _pollVersion) {
        _error = '自動更新失敗：$error。請下拉重試；保留上次可驗證行情。';
      }
    } finally {
      if (version == _pollVersion) {
        _pollBusy = false;
        _notify();
      }
    }
  }

  void setSort(CandidateSort value) {
    _sort = value;
    _page = 0;
    _notify();
  }

  void setPage(int value) {
    _page = value.clamp(0, pageCount - 1).toInt();
    _notify();
  }

  Future<void> setEquity(StockMarket market, double value) async {
    if (!value.isFinite || value <= 0) throw ArgumentError('淨值必須為有限正數。');
    _settings = market == StockMarket.tw
        ? _settings.copyWith(twEquity: value)
        : _settings.copyWith(usEquity: value);
    await _persist();
    _notify();
  }

  Future<void> updateSettings(AppSettings value) async {
    for (final amount in [value.twEquity, value.usEquity,
      value.twAdrThreshold, value.usAdrThreshold]) {
      if (!amount.isFinite || amount <= 0) throw ArgumentError('設定數值必須為有限正數。');
    }
    final uri = Uri.tryParse(value.apiBaseUrl);
    if (!['direct', 'backend'].contains(value.dataProvider)) {
      throw ArgumentError('資料來源必須為 direct 或 backend。');
    }
    if (!value.useMockData && value.dataProvider == 'backend' && (uri == null ||
        !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment)) {
      throw ArgumentError('請提供完整 HTTP／HTTPS API URL。');
    }
    var next = value;
    final previousSettings = _settings;
    final oldSource = _portfolioSource(previousSettings);
    final nextSource = _portfolioSource(next);
    _cancelScan();
    _resetBackendWaiting();
    _cancelPortfolio();
    _pollVersion++;
    _pollBusy = false;
    if (oldSource != nextSource) {
      // Invalidate BEFORE any reminder/persistence await. An old mock request
      // must never update the real-data observation history after a switch.
      _portfolioRequestVersion++;
      _portfolioLoading = false;
      _portfolioQuotes.clear();
      _portfolioErrors.clear();
      _portfolioDataWarnings.clear();
      _cachedQuoteKeys.clear();
      _captureObservations(oldSource);
      _restoreObservations(nextSource);
      _portfolioNotice = '行情來源已切換，最高 R／追蹤停損依來源分開保存；庫存與固定初始風險保留。';
    }
    _requestVersion++;
    _snapshot = null;
    _marketScanProgress = null;
    _loading = false;
    _page = 0;
    _settings = next;
    _syncPolling();
    _notify();
    String? reminderError;
    if (next.remindersEnabled != previousSettings.remindersEnabled) {
      try {
        final allowed = await _reminders.setEnabled(next.remindersEnabled)
            .timeout(_scanUpdateTimeout);
        if (next.remindersEnabled && !allowed) {
          next = next.copyWith(remindersEnabled: false);
          reminderError = '通知權限未開啟，提醒維持關閉。';
        }
      } catch (exception) {
        next = next.copyWith(remindersEnabled: false);
        reminderError = '提醒設定失敗：$exception';
      }
    }
    _settings = next;
    _portfolioRequestVersion++;
    _portfolioLoading = false;
    _portfolioQuotes.clear();
    _portfolioErrors.clear();
    _portfolioDataWarnings.clear();
    _cachedQuoteKeys.clear();
    _snapshot = null;
    _page = 0;
    await _persist();
    await _persistPortfolio();
    await refresh();
    await refreshPortfolio();
    _syncPolling();
    if (reminderError != null) {
      _error = reminderError;
      _notify();
    }
  }

  Future<SharedPreferences> _getPreferences() async {
    final existing = _preferences;
    if (existing != null) return existing;
    final preferences = await SharedPreferences.getInstance().timeout(_storageTimeout);
    if (!_disposed) _preferences = preferences;
    return preferences;
  }

  Future<bool> _writePreference(String key, String value,
      {bool Function()? isCurrent}) async {
    if (_disposed || (isCurrent != null && !isCurrent())) return true;
    final writer = _preferenceWriter;
    if (writer != null) return writer(key, value).timeout(_storageTimeout);
    final preferences = await _getPreferences();
    if (_disposed || (isCurrent != null && !isCurrent())) return true;
    return preferences.setString(key, value).timeout(_storageTimeout);
  }

  Future<void> _persist() async {
    if (_disposed) return;
    final saved = await _writePreference(_settingsKey, jsonEncode(_settings.toJson()));
    if (!saved) throw StateError('本機設定儲存失敗。');
  }

  Future<void> _loadPortfolio() async {
    String? storedPayload;
    try {
      final text = _preferences?.getString(_portfolioKey);
      storedPayload = text;
      if (text == null) {
        _portfolioPositions = _settings.useMockData ? demoPortfolioPositions() : [];
        await _persistPortfolio();
        return;
      }
      final data = jsonDecode(text);
      if (data is! Map<String, dynamic> || data['positions'] is! List) {
        throw const FormatException('持股儲存格式無效。');
      }
      final holdings = <PortfolioPosition>[];
      final keys = <String>{};
      final ids = <String>{};
      for (final row in data['positions'] as List) {
        if (row is! Map<String, dynamic>) throw const FormatException('持股資料格式無效。');
        final holding = PortfolioPosition.fromJson(row);
        if (!keys.add(holding.key) || !ids.add(holding.id)) {
          throw const FormatException('庫存含重複代碼或識別碼。');
        }
        holdings.add(holding);
      }
      final threshold = data['euphoria_percent'];
      if (threshold is num && threshold.isFinite && threshold >= 15 && threshold <= 20) {
        _euphoriaPercent = threshold.toDouble();
      }
      _portfolioPositions = holdings;
      if (!_settings.useMockData && holdings.any((p) => p.id.startsWith('demo-'))) {
        // Never silently delete an edited demonstration holding. Instead make
        // its origin explicit so a sample inventory cannot pass as user input.
        _portfolioNotice = '保留先前示範版本的 demo 庫存；請確認成本與股數，或刪除示範持股。'
            '示範行情的最高 R／移動停損不會帶入正式行情。';
      }
      final histories = data['observations'];
      if (histories != null) {
        if (histories is! Map<String, dynamic>) throw const FormatException('行情來源歷史格式無效。');
        for (final sourceEntry in histories.entries) {
          if (sourceEntry.value is! Map<String, dynamic>) throw const FormatException('持股觀察歷史格式無效。');
          final sourceHistory = <String, Map<String, num>>{};
          for (final holdingEntry in (sourceEntry.value as Map<String, dynamic>).entries) {
            final observation = holdingEntry.value;
            if (observation is! Map<String, dynamic>) throw const FormatException('持股觀察格式無效。');
            final peak = observation['peak_r'];
            final stop = observation['trailing_stop'];
            final observedAt = observation['observed_at_ms'];
            if (peak is! num || !peak.isFinite || peak < 0 ||
                stop is! num || !stop.isFinite || stop <= 0 ||
                (observedAt != null && (observedAt is! int || observedAt < 0))) {
              throw const FormatException('持股最高 R 或追蹤停損歷史無效。');
            }
            sourceHistory[holdingEntry.key] = {
              'peak_r': peak, 'trailing_stop': stop,
              if (observedAt is int) 'observed_at_ms': observedAt,
            };
          }
          _observationHistory[sourceEntry.key] = sourceHistory;
        }
      }
      // Legacy data had no source marker. Preserve it only for mock mode;
      // unlabelled demo observations cannot activate a live breakeven stop.
      final activeSource = data['active_source'];
      if (activeSource is String && !_observationHistory.containsKey(activeSource)) {
        _captureObservations(activeSource);
      } else if (activeSource == null && _settings.useMockData &&
          !_observationHistory.containsKey('mock')) {
        _captureObservations('mock');
      }
      _restoreObservations(_portfolioSource(_settings));
      final overrides = data['mock_quotes'];
      if (overrides is List) {
        for (final row in overrides) {
          if (row is! Map<String, dynamic>) throw const FormatException('示範行情格式無效。');
          final quote = PortfolioQuote.fromJson(row);
          _mockQuoteOverrides[quote.key] = quote;
        }
      }
    } catch (error) {
      if (storedPayload == null) {
        // A transient disk timeout while creating a first inventory is not
        // corrupt user data, and must not permanently block later CRUD retries.
        if (!_disposed) _portfolioNotice = '持股本機快取暫無法儲存：$error。請稍後重試。';
        return;
      }
      // Preserve the corrupt payload for recovery; do not overwrite it with demos.
      _portfolioNotice = '持股讀取失敗，請先備份本機資料：$error';
      _portfolioPositions = [];
      _portfolioStorageCorrupt = true;
      try {
        final original = _preferences?.getString(_portfolioKey);
        if (original != null && _preferences?.getString(_portfolioRecoveryKey) == null) {
          await _writePreference(_portfolioRecoveryKey, original);
        }
      } catch (_) {
        // The original primary payload is still protected from replacement.
      }
    }
  }

  bool _portfolioCurrent(int version, String source) => !_disposed &&
      version == _portfolioRequestVersion && _portfolioSource(_settings) == source;

  Future<void> _persistPortfolio({int? version, String? source}) async {
    final expectedVersion = version ?? _portfolioRequestVersion;
    final expectedSource = source ?? _portfolioSource(_settings);
    bool current() => _portfolioCurrent(expectedVersion, expectedSource);
    // Keep the original unreadable payload; an unrelated Settings save must
    // never replace a corrupt inventory with an empty list.
    if (!current()) return;
    if (_portfolioStorageCorrupt) {
      _portfolioNotice = '持股儲存資料損毀；原始資料保留，設定更新不會覆寫庫存。'
          '請先備份並修復本機資料。';
      return;
    }
    _captureObservations(expectedSource);
    final payload = jsonEncode({
      'positions': _portfolioPositions.map((p) => p.toJson()).toList(),
      'mock_quotes': _mockQuoteOverrides.values.map((q) => q.toJson()).toList(),
      'euphoria_percent': _euphoriaPercent,
      'active_source': expectedSource,
      'observations': _observationHistory,
    });
    final saved = await _writePreference(_portfolioKey, payload, isCurrent: current);
    if (!current()) return;
    if (!saved) throw StateError('本機持股儲存失敗。');
  }

  Future<void> refreshPortfolio({bool forceRefresh = true}) {
    if (_disposed) return Future<void>.value();
    final source = _portfolioSource(_settings);
    final active = _portfolioOperation;
    if (active != null && active.key == source &&
        active.version == _portfolioRequestVersion) {
      if (forceRefresh && !active.force) {
        active.queuedForce ??= Completer<void>();
        active.queuedElapsed ??= Stopwatch()..start();
        return active.queuedForce!.future;
      }
      return active.completion.future;
    }
    return _beginPortfolio(forceRefresh: forceRefresh, budget: _portfolioUpdateTimeout);
  }

  Future<void> _beginPortfolio({required bool forceRefresh, required Duration budget}) {
    _cancelPortfolio();
    final operation = _RefreshOperation(_portfolioSource(_settings),
        ++_portfolioRequestVersion, forceRefresh, budget);
    _portfolioOperation = operation;
    unawaited(_refreshPortfolio(operation));
    return operation.completion.future;
  }

  bool _ownsPortfolio(_RefreshOperation operation) => !_disposed &&
      identical(_portfolioOperation, operation) &&
      _portfolioCurrent(operation.version, operation.key);

  void _retirePortfolio(String source, PortfolioRepository repository) {
    if (identical(_portfolioRepositories[source], repository)) {
      _portfolioRepositories.remove(source);
    }
    try {
      repository.close();
    } catch (error, stack) {
      debugPrint('關閉持股行情服務失敗：$error\n$stack');
    }
  }

  void _cancelPortfolio() {
    final active = _portfolioOperation;
    if (active == null) return;
    _portfolioOperation = null;
    active.cancel();
    _portfolioLoading = false;
    final repository = _portfolioRepositories[active.key];
    if (repository != null) _retirePortfolio(active.key, repository);
  }

  void _quoteFailure(List<String> symbols, StockMarket market, Object error) {
    for (final symbol in symbols) {
      final key = '${market.name}:$symbol';
      final previous = _portfolioQuotes[key];
      if (previous != null) _cachedQuoteKeys.add(key);
      _portfolioErrors[key] = previous == null
          ? '無法取得可驗證行情：$error'
          : '更新失敗：$error；顯示 ${previous.quoteTimestamp.toLocal()} 的快取行情。';
    }
  }

  Future<void> _refreshPortfolio(_RefreshOperation operation) async {
    final settings = _settings;
    final holdings = List<PortfolioPosition>.of(_portfolioPositions);
    Duration remaining() => operation.remaining;
    try {
      if (!_ownsPortfolio(operation)) return;
      _portfolioLoading = true;
      // A failed production request retains only the previous verified quote,
      // with an explicit cached marker. It never substitutes mock prices.
      final holdingKeys = holdings.map((p) => p.key).toSet();
      _portfolioQuotes.removeWhere((key, _) => !holdingKeys.contains(key));
      _cachedQuoteKeys.removeWhere((key) => !holdingKeys.contains(key));
      _portfolioErrors.clear();
      _portfolioDataWarnings.clear();
      _notify();
      for (final market in StockMarket.values) {
        if (!_ownsPortfolio(operation)) return;
        final symbols = holdings.where((p) => p.market == market)
            .map((p) => p.symbol).toList();
        if (symbols.isEmpty) continue;
        PortfolioRepository? repository;
        try {
          // A single absolute budget covers both markets and every chunk;
          // adding more holdings must not extend the spinner indefinitely.
          if (remaining() <= Duration.zero) {
            throw TimeoutException('持股行情更新已達 ${_portfolioUpdateTimeout.inSeconds} 秒總時限。');
          }
          repository = _portfolioRepositories.putIfAbsent(operation.key,
              () => _portfolioRepositoryFactory(settings));
          final snapshot = await _awaitUpdate(repository.fetch(market, symbols,
              forceRefresh: operation.force), operation, remaining());
          if (!_ownsPortfolio(operation)) return;
          if (snapshot.source.trim().isEmpty ||
              (!settings.useMockData && _demoSource(snapshot.source))) {
            throw const FormatException('持股行情回應的來源無效，未採用該市場回應。');
          }
          for (final warning in snapshot.warnings) {
            if (_portfolioDataWarnings.length >= 8) break;
            final text = warning.trim();
            if (text.isEmpty) continue;
            final bounded = String.fromCharCodes(text.runes.take(240));
            _portfolioDataWarnings.add('${market.label}：$bounded');
          }
          final accepted = <String>{};
          for (final entry in snapshot.quotes.entries) {
            if (!symbols.contains(entry.key)) {
              // Never attach an unsolicited symbol to a user's inventory.
              continue;
            }
            final key = '${market.name}:${entry.key}';
            final quote = entry.value;
            if (quote.market != market || quote.symbol != entry.key ||
                (!settings.useMockData && _demoSource(quote.source))) {
              _quoteFailure([entry.key], market,
                  const FormatException('此股票的市場、代碼或行情來源不符，已拒絕該筆資料。'));
              continue;
            }
            accepted.add(entry.key);
            _portfolioQuotes[key] = quote;
            if (quote.isCached || quote.isStale) {
              _cachedQuoteKeys.add(key);
            } else {
              _cachedQuoteKeys.remove(key);
            }
          }
          for (final entry in snapshot.errors.entries) {
            if (!symbols.contains(entry.key) || accepted.contains(entry.key)) continue;
            _portfolioErrors['${market.name}:${entry.key}'] = entry.value.trim().isEmpty
                ? '此股票未取得可驗證行情。' : entry.value;
          }
          for (final symbol in symbols) {
            final key = '${market.name}:$symbol';
            if (!accepted.contains(symbol)) {
              _portfolioErrors.putIfAbsent(key, () => '資料來源未回傳可驗證行情。');
              if (_portfolioQuotes.containsKey(key)) _cachedQuoteKeys.add(key);
            }
          }
        } on _UpdateCancelled {
          return;
        } catch (error, stack) {
          if (!_ownsPortfolio(operation)) return;
          if (error is TimeoutException && repository != null) {
            _retirePortfolio(operation.key, repository);
          }
          debugPrint('持股行情更新失敗：$error\n$stack');
          _quoteFailure(symbols, market, error);
        }
      }
      if (!_ownsPortfolio(operation)) return;
      if (settings.useMockData) {
        for (final holding in holdings) {
          final manual = _mockQuoteOverrides[holding.key];
          if (manual != null) {
            _portfolioQuotes[holding.key] = manual;
            _portfolioErrors.remove(holding.key);
            _cachedQuoteKeys.remove(holding.key);
          }
        }
      }
      // Record a verified first market's observed 2R peak even when a later
      // market exhausted the budget. Only persistence may be deferred.
      await _observePortfolio(version: operation.version, source: operation.key,
          persistenceBudget: remaining());
    } on _UpdateCancelled {
      // The source owner cancelled this operation; no notice in the new source.
    } catch (error, stack) {
      debugPrint('持股診斷更新失敗：$error\n$stack');
      if (_ownsPortfolio(operation)) {
        _portfolioNotice = '持股更新失敗：$error。請下拉重試；保留上次可驗證行情。';
      }
    } finally {
      final owned = _ownsPortfolio(operation);
      if (identical(_portfolioOperation, operation)) {
        _portfolioOperation = null;
        _portfolioLoading = false;
      }
      operation.finish();
      if (owned && operation.queuedForce != null && !_disposed &&
          _portfolioSource(_settings) == operation.key) {
        try {
          final remaining = _portfolioUpdateTimeout - operation.queuedElapsed!.elapsed;
          if (remaining > Duration.zero) {
            await _beginPortfolio(forceRefresh: true, budget: remaining);
          } else {
            _portfolioNotice = '持股更新已達 ${_portfolioUpdateTimeout.inSeconds} 秒總時限，請重試。';
          }
        } finally {
          operation.finishQueued();
        }
      } else {
        operation.finishQueued();
      }
      if (!_disposed && _portfolioOperation == null) _notify();
    }
  }

  Future<void> _observePortfolio({int? version, String? source,
      Duration? persistenceBudget}) async {
    final expectedVersion = version ?? _portfolioRequestVersion;
    final expectedSource = source ?? _portfolioSource(_settings);
    bool current() => _portfolioCurrent(expectedVersion, expectedSource);
    if (!current()) return;
    var changed = false;
    final sourceHistory = _observationHistory.putIfAbsent(expectedSource, () => {});
    _portfolioPositions = _portfolioPositions.map((holding) {
      // Cached data may be inspected, but cannot create a newly observed peak
      // or arm a breakeven stop. Only fresh verified quotes alter live history.
      if (isPortfolioQuoteCached(holding.key)) return holding;
      final quote = _portfolioQuotes[holding.key];
      if (quote == null) return holding;
      final observedAt = sourceHistory[holding.id]?['observed_at_ms'];
      final timestamp = quote.quoteTimestamp.millisecondsSinceEpoch;
      if (observedAt != null && timestamp < observedAt) {
        _cachedQuoteKeys.add(holding.key);
        _portfolioErrors[holding.key] = '行情時間早於上次已驗證觀察，僅顯示舊報價；最高 R 與停損保持不變。';
        return holding;
      }
      final diagnosis = diagnosisFor(holding);
      if (diagnosis == null) return holding;
      final next = diagnosis.position;
      changed = changed || next.peakR != holding.peakR ||
          next.trailingStop != holding.trailingStop || timestamp != observedAt;
      sourceHistory[holding.id] = {'peak_r': next.peakR,
        'trailing_stop': next.trailingStop, 'observed_at_ms': timestamp};
      return next;
    }).toList();
    if (changed) _dirtyObservationSources.add(expectedSource);
    if (_dirtyObservationSources.contains(expectedSource)) {
      if (persistenceBudget != null && persistenceBudget <= Duration.zero) {
        _portfolioNotice = '本次行情更新已達總時限；已保留取得行情的診斷，觀察紀錄將於下次更新儲存。';
        return;
      }
      try {
        await _persistPortfolio(version: expectedVersion, source: expectedSource)
            .timeout(persistenceBudget ?? _storageTimeout);
        if (current()) _dirtyObservationSources.remove(expectedSource);
      } catch (error, stack) {
        debugPrint('最高 R 與移動停損儲存失敗：$error\n$stack');
        if (current()) _portfolioNotice = '最高 R 與移動停損儲存失敗：$error';
      }
    }
  }

  Future<void> savePortfolioPosition(PortfolioPosition value) async {
    if (_portfolioStorageCorrupt) throw StateError('持股資料損毀，請先備份並修復本機庫存。');
    if (_portfolioLoading) throw StateError('行情更新中，請稍後儲存。');
    if (_portfolioPositions.any((p) => p.id != value.id && p.key == value.key)) {
      throw ArgumentError('同市場代碼已存在，請編輯原持股合併股數與成本。');
    }
    final index = _portfolioPositions.indexWhere((p) => p.id == value.id);
    var next = value;
    if (index >= 0) {
      final previous = _portfolioPositions[index];
      if (previous.key == value.key && previous.entryPrice == value.entryPrice &&
          previous.initialStop == value.initialStop) {
        next = value.withObservation(previous.peakR, previous.trailingStop);
      } else {
        // Entry and initial stop define a new fixed R basis.
        next = value.withObservation(0, value.initialStop);
      }
    }
    final previousList = _portfolioPositions;
    _captureObservations(_portfolioSource(_settings));
    final previousHistory = {
      for (final source in _observationHistory.entries)
        source.key: Map<String, Map<String, num>>.of(source.value),
    };
    if (index < 0 || previousList[index].key != value.key ||
        previousList[index].entryPrice != value.entryPrice ||
        previousList[index].initialStop != value.initialStop) {
      for (final source in _observationHistory.values) { source.remove(value.id); }
    }
    _portfolioPositions = List<PortfolioPosition>.of(previousList);
    if (index >= 0) { _portfolioPositions[index] = next; }
    else { _portfolioPositions.add(next); }
    try { await _persistPortfolio(); }
    catch (_) {
      _portfolioPositions = previousList;
      _observationHistory..clear()..addAll(previousHistory);
      rethrow;
    }
    await refreshPortfolio();
  }

  Future<void> deletePortfolioPosition(String id) async {
    if (_portfolioStorageCorrupt) throw StateError('持股資料損毀，請先備份並修復本機庫存。');
    if (_portfolioLoading) throw StateError('行情更新中，請稍後刪除。');
    final previous = _portfolioPositions;
    final previousHistory = {
      for (final source in _observationHistory.entries)
        source.key: Map<String, Map<String, num>>.of(source.value),
    };
    final previousOverrides = Map<String, PortfolioQuote>.of(_mockQuoteOverrides);
    for (final source in _observationHistory.values) { source.remove(id); }
    for (final holding in previous.where((p) => p.id == id)) {
      _mockQuoteOverrides.remove(holding.key);
    }
    _portfolioPositions = previous.where((p) => p.id != id).toList();
    try { await _persistPortfolio(); }
    catch (_) {
      _portfolioPositions = previous;
      _observationHistory..clear()..addAll(previousHistory);
      _mockQuoteOverrides..clear()..addAll(previousOverrides);
      rethrow;
    }
    for (final holding in previous.where((p) => p.id == id)) {
      _portfolioQuotes.remove(holding.key);
      _portfolioErrors.remove(holding.key);
      _cachedQuoteKeys.remove(holding.key);
    }
    _notify();
  }

  Future<void> setMockPortfolioQuote(PortfolioQuote quote) async {
    if (!_settings.useMockData) throw StateError('實際行情模式禁止手動更改市價。');
    _mockQuoteOverrides[quote.key] = quote;
    _portfolioQuotes[quote.key] = quote;
    _portfolioErrors.remove(quote.key);
    _cachedQuoteKeys.remove(quote.key);
    await _observePortfolio();
    await _persistPortfolio();
    _notify();
  }

  Future<void> setEuphoriaPercent(double value) async {
    if (!value.isFinite || value < 15 || value > 20) throw ArgumentError('正乖離門檻必須為 15%～20%。');
    _euphoriaPercent = value;
    await _persistPortfolio();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _resetBackendWaiting();
    _cancelScan();
    _cancelPortfolio();
    _pollVersion++;
    _pollBusy = false;
    _requestVersion++;
    _portfolioRequestVersion++;
    _reminders.dispose();
    for (final repository in _candidateRepositories.values.toSet()) {
      try {
        if (repository is RealCandidateRepository) repository.close();
        if (repository is DirectLiveCandidateRepository) repository.close();
      } catch (error, stack) {
        debugPrint('關閉行情掃描服務失敗：$error\n$stack');
      }
    }
    for (final repository in _portfolioRepositories.values.toSet()) {
      try {
        repository.close();
      } catch (error, stack) {
        debugPrint('關閉持股行情服務失敗：$error\n$stack');
      }
    }
    super.dispose();
  }
}
