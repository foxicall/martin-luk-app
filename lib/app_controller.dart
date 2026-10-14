import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'models/app_settings.dart';
import 'models/stock_candidate.dart';
import 'models/portfolio_position.dart';
import 'services/candidate_repository.dart';
import 'services/exit_advisory_engine.dart';
import 'services/live_candidate_repository.dart';
import 'services/live_portfolio_repository.dart';
import 'services/portfolio_repository.dart';
import 'services/reminder_service.dart';
import 'services/strategy_engine.dart';

enum CandidateSort { rs, adr, position }

typedef RepositoryFactory = CandidateRepository Function(AppSettings settings);
typedef PortfolioRepositoryFactory = PortfolioRepository Function(AppSettings settings);

/// 將設定、來源、分頁與行情请求集中管理；過期请求不覆蓋最新市場。
class AppController extends ChangeNotifier {
  AppController({
    RepositoryFactory? repositoryFactory,
    PortfolioRepositoryFactory? portfolioRepositoryFactory,
    ReminderService? reminders,
    bool? forceMockPreview,
    Duration pollingInterval = const Duration(seconds: 60),
    DateTime Function()? now,
  })
      : _repositoryFactory = repositoryFactory ?? _defaultRepository,
        _portfolioRepositoryFactory = portfolioRepositoryFactory ?? _defaultPortfolioRepository,
        _reminders = reminders ?? ReminderService(),
        _forceMockPreview = forceMockPreview ?? AppConfig.forceMockPreview,
        _pollingInterval = pollingInterval,
        _now = now ?? DateTime.now {
    if (pollingInterval <= Duration.zero) {
      throw ArgumentError('自動更新間隔必須大於零。');
    }
  }

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
  final DateTime Function() _now;
  final Map<String, CandidateRepository> _candidateRepositories = {};
  final Map<String, PortfolioRepository> _portfolioRepositories = {};
  final Map<String, CandidateSnapshot> _candidateSnapshots = {};
  Timer? _pollTimer;
  bool _foreground = false;
  bool _initialized = false;
  bool _pollBusy = false;
  DateTime? _lastAutoRefreshAt;
  bool get autoRefreshActive => _pollTimer != null;
  bool get polling => _pollBusy;
  DateTime? get lastAutoRefreshAt => _lastAutoRefreshAt;
  bool get isSnapshotCached => _snapshot?.stale ?? false;
  DateTime? get lastUpdated => _snapshot?.generatedAt;
  Future<void>? _activeScanFuture;
  String? _activeScanKey;
  int _activeScanVersion = -1;
  bool _activeScanForce = false;
  Future<void>? _activePortfolioFuture;
  String? _activePortfolioSource;
  int _activePortfolioVersion = -1;
  bool _activePortfolioForce = false;
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
  bool _portfolioLoading = false;
  bool get portfolioLoading => _portfolioLoading;
  int _portfolioRequestVersion = 0;
  double _euphoriaPercent = 20;
  double get euphoriaPercent => _euphoriaPercent;
  String? _portfolioNotice;
  String? get portfolioNotice => _portfolioNotice;

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
      return ExitAdvisoryEngine.evaluate(holding, quote, equityFor(holding.market),
          euphoriaPercent: _euphoriaPercent,
          observe: !isPortfolioQuoteCached(holding.key));
    } on ArgumentError catch (error) {
      _portfolioErrors[holding.key] = '診斷數值超出有效範圍：$error';
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
      _preferences = await SharedPreferences.getInstance();
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
        await _reminders.initialize();
        if (_disposed) return;
        if (_settings.remindersEnabled) {
          final enabled = await _reminders.setEnabled(true);
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

  /// User refreshes bypass a quote TTL. A foreground poll reuses historical
  /// candles and only refreshes the limited candidate/holding quote set.
  Future<void> refresh({bool forceRefresh = true, bool refreshQuotesOnly = false}) {
    if (_disposed) return Future<void>.value();
    final key = '${_portfolioSource(_settings)}:${_market.name}:'
        '${_market == StockMarket.tw ? _settings.twAdrThreshold : _settings.usAdrThreshold}';
    if (_activeScanKey == key && _activeScanVersion == _requestVersion &&
        _activeScanFuture != null) {
      if (forceRefresh && !_activeScanForce) {
        // A pull during a TTL-based poll must still force a network refresh.
        // Queue it after the current work rather than overlap both requests.
       return _activeScanFuture!.then<void>((_) async {
          if (_disposed || currentKey != key) {
            return;
          }
          await refresh(forceRefresh: true, refreshQuotesOnly: refreshQuotesOnly);
        });
      return _activeScanFuture!;
    }
    final future = _refresh(forceRefresh: forceRefresh, refreshQuotesOnly: refreshQuotesOnly);
    _activeScanKey = key;
    _activeScanVersion = _requestVersion;
    _activeScanForce = forceRefresh;
    _activeScanFuture = future;
    unawaited(future.whenComplete(() {
      if (identical(_activeScanFuture, future)) {
        _activeScanFuture = null;
        _activeScanKey = null;
      }
    }));
    return future;
  }

  Future<void> _refresh({required bool forceRefresh, required bool refreshQuotesOnly}) async {
    final version = ++_requestVersion;
    final requestMarket = _market;
    final currentSettings = _settings;
    _loading = true;
    _error = null;
    _notify();
    final cacheKey = '${_portfolioSource(currentSettings)}:${requestMarket.name}';
    try {
      final repository = _candidateRepositories.putIfAbsent(cacheKey,
          () => _repositoryFactory(currentSettings));
      final response = await repository.fetch(
        requestMarket,
        adrThreshold: requestMarket == StockMarket.tw
            ? currentSettings.twAdrThreshold
            : currentSettings.usAdrThreshold,
        forceRefresh: forceRefresh,
        refreshQuotesOnly: refreshQuotesOnly,
      );
      if (_disposed || version != _requestVersion) return;
      _snapshot = response;
      _candidateSnapshots[cacheKey] = response;
      _page = _page.clamp(0, pageCount - 1).toInt();
    } catch (exception) {
      if (_disposed || version != _requestVersion) return;
      final previous = _candidateSnapshots[cacheKey];
      _snapshot = previous == null ? null : _staleSnapshot(previous,
          '更新失敗，顯示上次快取；不可視為當前突破訊號。');
      _error = previous == null
          ? '無法取得評估資料：$exception。請檢查連線後重試。'
          : '資料更新失敗：$exception；保留 ${previous.generatedAt.toLocal()} 的快取。';
    } finally {
      if (!_disposed && version == _requestVersion) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> setMarket(StockMarket value) async {
    if (_market == value) return;
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
        universeIsComplete: value.universeIsComplete, universeAsOf: value.universeAsOf,
        scanCompletedAt: value.scanCompletedAt);

  /// The Flutter lifecycle owner explicitly enables polling only while visible.
  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _syncPolling();
    if (value && _initialized && _settings.autoRefreshEnabled &&
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
        _pollBusy || _loading || _portfolioLoading) return;
    _pollBusy = true;
    _notify();
    try {
      await Future.wait([
        refresh(forceRefresh: false, refreshQuotesOnly: true),
        refreshPortfolio(forceRefresh: false),
      ]);
      _lastAutoRefreshAt = _now().toUtc();
    } finally {
      _pollBusy = false;
      _notify();
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
    if (oldSource != nextSource) {
      // Invalidate BEFORE any reminder/persistence await. An old mock request
      // must never update the real-data observation history after a switch.
      _portfolioRequestVersion++;
      _portfolioLoading = false;
      _portfolioQuotes.clear();
      _portfolioErrors.clear();
      _cachedQuoteKeys.clear();
      _captureObservations(oldSource);
      _restoreObservations(nextSource);
      _portfolioNotice = '行情來源已切換，最高 R／追蹤停損依來源分開保存；庫存與固定初始風險保留。';
    }
    _requestVersion++;
    _snapshot = null;
    _loading = false;
    _page = 0;
    _settings = next;
    _syncPolling();
    _notify();
    String? reminderError;
    if (next.remindersEnabled != previousSettings.remindersEnabled) {
      try {
        final allowed = await _reminders.setEnabled(next.remindersEnabled);
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

  Future<void> _persist() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final saved = await preferences.setString(_settingsKey, jsonEncode(_settings.toJson()));
    if (!saved) throw StateError('本機設定儲存失敗。');
  }

  Future<void> _loadPortfolio() async {
    try {
      final text = _preferences?.getString(_portfolioKey);
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
      // Preserve the corrupt payload for recovery; do not overwrite it with demos.
      _portfolioNotice = '持股讀取失敗，請先備份本機資料：$error';
      _portfolioPositions = [];
      _portfolioStorageCorrupt = true;
      try {
        final original = _preferences?.getString(_portfolioKey);
        if (original != null && _preferences?.getString(_portfolioRecoveryKey) == null) {
          await _preferences?.setString(_portfolioRecoveryKey, original);
        }
      } catch (_) {
        // The original primary payload is still protected from replacement.
      }
    }
  }

  Future<void> _persistPortfolio() async {
    // Saving unrelated Settings must not erase an unreadable inventory. CRUD
    // requires a repaired payload; retain a recovery copy and the primary data.
    if (_disposed) return;
    if (_portfolioStorageCorrupt) {
      _portfolioNotice = '持股儲存資料損毀；原始資料保留，設定更新不會覆寫庫存。'
          '請先備份並修復本機資料。';
      return;
    }
    _captureObservations(_portfolioSource(_settings));
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final saved = await preferences.setString(_portfolioKey, jsonEncode({
      'positions': _portfolioPositions.map((p) => p.toJson()).toList(),
      'mock_quotes': _mockQuoteOverrides.values.map((q) => q.toJson()).toList(),
      'euphoria_percent': _euphoriaPercent,
      'active_source': _portfolioSource(_settings),
      'observations': _observationHistory,
    }));
    if (!saved) throw StateError('本機持股儲存失敗。');
  }

  Future<void> refreshPortfolio({bool forceRefresh = true}) {
    if (_disposed) return Future<void>.value();
    final source = _portfolioSource(_settings);
    if (_activePortfolioSource == source &&
        _activePortfolioVersion == _portfolioRequestVersion &&
        _activePortfolioFuture != null) {
      if (forceRefresh && !_activePortfolioForce) {
        return _activePortfolioFuture!.then<void>((_) {
         if (_disposed || _portfolioSource(_settings) != source) return;
if (_disposed || _portfolioSource(_settings) != source) {
          return;
        }
    final future = _refreshPortfolio(forceRefresh: forceRefresh);
    _activePortfolioSource = source;
    _activePortfolioVersion = _portfolioRequestVersion;
    _activePortfolioForce = forceRefresh;
    _activePortfolioFuture = future;
    unawaited(future.whenComplete(() {
      if (identical(_activePortfolioFuture, future)) {
        _activePortfolioFuture = null;
        _activePortfolioSource = null;
      }
    }));
    return future;
  }

  Future<void> _refreshPortfolio({required bool forceRefresh}) async {
    final version = ++_portfolioRequestVersion;
    final settings = _settings;
    final holdings = List<PortfolioPosition>.of(_portfolioPositions);
    _portfolioLoading = true;
    // Keep the last real quote visible while updating; never substitute a
    // demonstration quote on a failed production request.
    final holdingKeys = holdings.map((p) => p.key).toSet();
    _portfolioQuotes.removeWhere((key, _) => !holdingKeys.contains(key));
    _cachedQuoteKeys.removeWhere((key) => !holdingKeys.contains(key));
    _portfolioErrors.clear();
    _notify();
    try {
      for (final market in StockMarket.values) {
        final symbols = holdings.where((p) => p.market == market).map((p) => p.symbol).toList();
        if (symbols.isEmpty) continue;
        try {
          final source = _portfolioSource(settings);
          final repository = _portfolioRepositories.putIfAbsent(source,
              () => _portfolioRepositoryFactory(settings));
          final snapshot = await repository.fetch(market, symbols, forceRefresh: forceRefresh);
          if (_disposed || version != _portfolioRequestVersion) return;
          for (final entry in snapshot.quotes.entries) {
            final key = '${market.name}:${entry.key}';
            final quote = entry.value;
            _portfolioQuotes[key] = quote;
            if (quote.isCached || quote.isStale) {
              _cachedQuoteKeys.add(key);
            } else {
              _cachedQuoteKeys.remove(key);
            }
          }
          for (final entry in snapshot.errors.entries) {
            _portfolioErrors['${market.name}:${entry.key}'] = entry.value;
          }
          for (final symbol in symbols) {
            final key = '${market.name}:$symbol';
            if (!snapshot.quotes.containsKey(symbol)) {
              _portfolioErrors.putIfAbsent(key, () => '資料來源未回傳可驗證行情。');
              if (_portfolioQuotes.containsKey(key)) _cachedQuoteKeys.add(key);
            }
          }
        } catch (error) {
          if (_disposed || version != _portfolioRequestVersion) return;
          for (final symbol in symbols) {
            final key = '${market.name}:$symbol';
            final previous = _portfolioQuotes[key];
            if (previous != null) _cachedQuoteKeys.add(key);
            _portfolioErrors[key] = previous == null
                ? '無法取得可驗證行情：$error'
                : '更新失敗：$error；顯示 ${previous.quoteTimestamp.toLocal()} 的快取行情。';
          }
        }
      }
      if (_disposed || version != _portfolioRequestVersion) return;
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
      await _observePortfolio();
    } finally {
      if (!_disposed && version == _portfolioRequestVersion) {
        _portfolioLoading = false;
        _notify();
      }
    }
  }

  Future<void> _observePortfolio() async {
    var changed = false;
    final sourceHistory = _observationHistory.putIfAbsent(
        _portfolioSource(_settings), () => {});
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
    if (changed) {
      try { await _persistPortfolio(); }
      catch (error) { _portfolioNotice = '最高 R 與移動停損儲存失敗：$error'; }
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
    _requestVersion++;
    _portfolioRequestVersion++;
    _reminders.dispose();
    for (final repository in _candidateRepositories.values.toSet()) {
      if (repository is RealCandidateRepository) repository.close();
      if (repository is DirectLiveCandidateRepository) repository.close();
    }
    for (final repository in _portfolioRepositories.values.toSet()) {
      repository.close();
    }
    super.dispose();
  }
}
