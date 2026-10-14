import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ScanCall {
  const _ScanCall(this.force, this.quotesOnly);
  final bool force;
  final bool quotesOnly;
}

class _Scans implements CandidateRepository {
  final calls = <_ScanCall>[];
  bool fail = false;
  Completer<CandidateSnapshot>? deferred;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls.add(_ScanCall(forceRefresh, refreshQuotesOnly));
    if (fail) throw const RepositoryException('HTTP 503 測試失敗');
    if (deferred != null) return deferred!.future;
    return _snapshot(market);
  }
}

class _Quotes implements PortfolioRepository {
  final calls = <bool>[];
  bool fail = false;
  bool cached = false;
  double price = 101;
  DateTime timestamp = DateTime.utc(2026, 10, 14, 15);
  int closes = 0;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) async {
    calls.add(forceRefresh);
    if (fail) throw StateError('HTTP 503 行情測試失敗');
    return PortfolioQuoteSnapshot(quotes: {
      for (final symbol in symbols) symbol: PortfolioQuote(
        symbol: symbol, name: symbol, market: market,
        currentPrice: price, ema9: 100, ema21: 99, ema50: 95,
        lastClose: 101, closeConfirmed: true,
        quoteTimestamp: timestamp,
        closeTimestamp: DateTime.utc(2026, 10, 13, 20),
        source: 'Yahoo Finance 真實來源測試固定回應', isLargeLiquid: true,
        isCached: cached, isStale: cached,
        cacheWarning: cached ? '網路失敗，使用上次行情' : null,
      ),
    }, errors: {}, source: 'Yahoo Finance');
  }

  @override
  void close() => closes++;
}

CandidateSnapshot _snapshot(StockMarket market) => CandidateSnapshot(
  candidates: [], fetchedAt: DateTime.utc(2026, 10, 14, 15),
  warnings: [], source: 'Yahoo Finance', universeCount: 500, stale: false,
  evaluatedCount: 480, universeIsComplete: true,
  universeAsOf: DateTime.utc(2026, 10, 14),
  scanCompletedAt: DateTime.utc(2026, 10, 14, 15),
);

PortfolioPosition _holding({String id = 'own-nvda'}) => PortfolioPosition(
  id: id, symbol: 'NVDA', market: StockMarket.us,
  entryPrice: 100, shares: 80, initialStop: 98,
);

Map<String, Object> _stored({AppSettings settings = const AppSettings(),
    List<PortfolioPosition> holdings = const []}) => {
  'martin_luk_settings_v1': jsonEncode(settings.toJson()),
  'martin_luk_portfolio_v1': jsonEncode({
    'positions': holdings.map((holding) => holding.toJson()).toList(),
    'observations': <String, Object>{},
  }),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('production defaults require neither a mock flag nor a backend URL', () {
    expect(AppConfig.useMockData, isFalse);
    const settings = AppSettings();
    expect(settings.useMockData, isFalse);
    expect(settings.dataProvider, 'direct');
    expect(settings.apiBaseUrl, isEmpty);
    expect(settings.autoRefreshEnabled, isTrue);
    expect(settings.twEquity, 1000000);
    expect(settings.usEquity, 50000);
  });

  test('legacy mock preference migrates once without mixing account currencies', () {
    final migrated = AppSettings.fromJson({
      'use_mock_data': true, 'api_base_url': 'http://10.0.2.2:8000',
      'tw_equity': 1234567.89, 'us_equity': 67890.12,
      'tw_adr_threshold': 4.0, 'dark_mode': false,
    });
    expect(migrated.useMockData, isFalse);
    expect(migrated.dataProvider, 'direct');
    expect(migrated.twEquity, 1234567.89);
    expect(migrated.usEquity, 67890.12);
    expect(migrated.twAdrThreshold, 4);
    expect(migrated.darkMode, isFalse);
    expect(migrated.toJson()['schema_version'], 2);
    final chosenMock = migrated.copyWith(useMockData: true);
    expect(AppSettings.fromJson(chosenMock.toJson()).useMockData, isTrue);
  });

  test('fresh production installation starts with an empty user inventory', () async {
    final scans = _Scans();
    final modes = <bool>[];
    final controller = AppController(repositoryFactory: (settings) {
      modes.add(settings.useMockData);
      return scans;
    }, portfolioRepositoryFactory: (_) => _Quotes());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(modes, [false]);
    expect(controller.portfolioPositions, isEmpty);
    expect(controller.portfolioQuotes, isEmpty);
    expect(controller.snapshot!.source, 'Yahoo Finance');
    expect(scans.calls.single.force, isFalse);
  });

  test('migration preserves edited demo inventory but never imports mock peaks', () async {
    final saved = _holding(id: 'demo-us-nvda').withObservation(8, 100);
    SharedPreferences.setMockInitialValues({
      'martin_luk_settings_v1': jsonEncode({
        'use_mock_data': true, 'tw_equity': 2000000, 'us_equity': 75000,
      }),
      'martin_luk_portfolio_v1': jsonEncode({
        'positions': [saved.toJson()], 'active_source': 'mock',
        'observations': {'mock': {saved.id: {'peak_r': 8, 'trailing_stop': 100}}},
      }),
    });
    final quotes = _Quotes()..fail = true;
    final controller = AppController(repositoryFactory: (_) => _Scans(),
        portfolioRepositoryFactory: (_) => quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.settings.useMockData, isFalse);
    expect(controller.settings.usEquity, 75000);
    expect(controller.settings.twEquity, 2000000);
    final position = controller.portfolioPositions.single;
    expect(position.id, saved.id);
    expect(position.entryPrice, saved.entryPrice);
    expect(position.shares, saved.shares);
    expect(position.peakR, 0);
    expect(position.trailingStop, 98);
    expect(controller.portfolioNotice, contains('示範'));
    final preferences = await SharedPreferences.getInstance();
    final persisted = jsonDecode(preferences.getString('martin_luk_settings_v1')!) as Map;
    expect(persisted['schema_version'], 2);
    expect(persisted['use_mock_data'], isFalse);
  });

  test('failed refresh retains timestamped scan and never introduces mock rows', () async {
    final scans = _Scans();
    final controller = AppController(repositoryFactory: (_) => scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final timestamp = controller.snapshot!.generatedAt;
    scans.fail = true;
    await controller.refresh();
    expect(controller.snapshot!.source, 'Yahoo Finance');
    expect(controller.snapshot!.generatedAt, timestamp);
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.snapshot!.evaluatedCount, 480);
    expect(controller.snapshot!.warnings.join(), contains('快取'));
    expect(controller.error, contains('HTTP 503'));
    expect(controller.visibleCandidates, isEmpty);
    expect(scans.calls.last.force, isTrue);
  });

  test('cached quote can show R but cannot observe a peak or arm breakeven', () async {
    final holding = _holding();
    SharedPreferences.setMockInitialValues(_stored(holdings: [holding]));
    final quotes = _Quotes();
    final controller = AppController(repositoryFactory: (_) => _Scans(),
        portfolioRepositoryFactory: (_) => quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.portfolioPositions.single.peakR, 0.5);
    expect(controller.portfolioPositions.single.trailingStop, 98);
    quotes..cached = true..price = 110;
    await controller.refreshPortfolio();
    final cached = controller.portfolioPositions.single;
    expect(controller.isPortfolioQuoteCached(cached.key), isTrue);
    expect(cached.peakR, 0.5);
    expect(cached.trailingStop, 98);
    final diagnosis = controller.diagnosisFor(cached)!;
    expect(diagnosis.currentR, 5);
    expect(diagnosis.position.peakR, 0.5);
    expect(diagnosis.position.trailingStop, 98);
    quotes.fail = true;
    await controller.refreshPortfolio();
    expect(controller.portfolioQuotes[cached.key]!.currentPrice, 110);
    expect(controller.portfolioErrors[cached.key], contains('快取'));
    expect(controller.portfolioPositions.single.peakR, 0.5);
    quotes..fail = false..cached = false..price = 104;
    await controller.refreshPortfolio();
    expect(controller.isPortfolioQuoteCached(cached.key), isFalse);
    expect(controller.portfolioPositions.single.peakR, 2);
    expect(controller.portfolioPositions.single.trailingStop, 100);
  });

  test('foreground poll uses hot quote refresh and stops when app is hidden', () async {
    final scans = _Scans();
    final controller = AppController(repositoryFactory: (_) => scans,
        portfolioRepositoryFactory: (_) => _Quotes(),
        pollingInterval: const Duration(hours: 1));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.autoRefreshActive, isFalse);
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.autoRefreshActive, isTrue);
    expect(scans.calls.last.force, isFalse);
    expect(scans.calls.last.quotesOnly, isTrue);
    expect(controller.lastAutoRefreshAt, isNotNull);
    controller.setForeground(false);
    final count = scans.calls.length;
    await controller.pollNow();
    expect(controller.autoRefreshActive, isFalse);
    expect(scans.calls.length, count);
  });

  test('an older delivered quote never overrides a later observed R history', () async {
    final holding = _holding();
    SharedPreferences.setMockInitialValues(_stored(holdings: [holding]));
    final quotes = _Quotes();
    final controller = AppController(repositoryFactory: (_) => _Scans(),
        portfolioRepositoryFactory: (_) => quotes);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    quotes..price = 120..timestamp = DateTime.utc(2026, 10, 14, 14);
    await controller.refreshPortfolio();
    expect(controller.portfolioQuotes[holding.key]!.currentPrice, 120);
    expect(controller.isPortfolioQuoteCached(holding.key), isTrue);
    expect(controller.portfolioPositions.single.peakR, 0.5);
    expect(controller.portfolioPositions.single.trailingStop, 98);
    expect(controller.portfolioErrors[holding.key], contains('早於'));
    final reloaded = AppController(repositoryFactory: (_) => _Scans(),
        portfolioRepositoryFactory: (_) => quotes);
    addTearDown(reloaded.dispose);
    await reloaded.initialize(initializeReminders: false);
    expect(reloaded.portfolioPositions.single.peakR, 0.5);
    expect(reloaded.isPortfolioQuoteCached(holding.key), isTrue);
  });

  test('overlapping poll ticks deduplicate and a forced pull queues after the poll', () async {
    final scans = _Scans();
    final controller = AppController(repositoryFactory: (_) => scans,
        pollingInterval: const Duration(hours: 1));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = Completer<CandidateSnapshot>();
    controller.setForeground(true);
    expect(controller.polling, isTrue);
    final pull = controller.refresh();
    await controller.pollNow();
    expect(scans.calls.length, 2);
    scans.deferred!.complete(_snapshot(StockMarket.tw));
    await pull;
    await Future<void>.delayed(Duration.zero);
    expect(controller.polling, isFalse);
    expect(scans.calls.length, 3);
    expect(scans.calls.last.force, isTrue);
  });

  test('explicit disabled auto-refresh and mock mode never start polling', () async {
    SharedPreferences.setMockInitialValues(_stored(
        settings: const AppSettings(autoRefreshEnabled: false)));
    final scans = _Scans();
    final controller = AppController(repositoryFactory: (_) => scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    controller.setForeground(true);
    await controller.pollNow();
    expect(controller.autoRefreshActive, isFalse);
    expect(scans.calls.length, 1);
    await controller.updateSettings(controller.settings.copyWith(
        useMockData: true, autoRefreshEnabled: true));
    expect(controller.autoRefreshActive, isFalse);
    final calls = scans.calls.length;
    await controller.pollNow();
    expect(scans.calls.length, calls);
  });

  test('backend URL is validated only when the backend is explicitly selected', () async {
    final controller = AppController(repositoryFactory: (_) => _Scans());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await controller.updateSettings(controller.settings.copyWith(apiBaseUrl: ''));
    await expectLater(controller.updateSettings(controller.settings.copyWith(
        dataProvider: 'backend', apiBaseUrl: '')), throwsArgumentError);
    expect(controller.settings.dataProvider, 'direct');
  });

  test('saving Settings never replaces a corrupt inventory with an empty list', () async {
    const original = '{"positions": [{"broken": true}]}';
    SharedPreferences.setMockInitialValues({
      'martin_luk_portfolio_v1': original,
    });
    final controller = AppController(repositoryFactory: (_) => _Scans());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.portfolioPositions, isEmpty);
    await controller.updateSettings(controller.settings.copyWith(usEquity: 75000));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('martin_luk_portfolio_v1'), original);
    expect(preferences.getString('martin_luk_portfolio_recovery_v1'), original);
    expect(controller.settings.usEquity, 75000);
    await expectLater(controller.savePortfolioPosition(_holding()), throwsStateError);
    expect(controller.portfolioNotice, contains('不會覆寫'));
  });

  test('disposing during initialization prevents orphan repositories and HTTP work', () async {
    var factories = 0;
    final controller = AppController(repositoryFactory: (_) {
      factories++;
      return _Scans();
    }, portfolioRepositoryFactory: (_) {
      factories++;
      return _Quotes();
    });
    final initialization = controller.initialize(initializeReminders: false);
    controller.dispose();
    await initialization;
    await controller.refresh();
    await controller.refreshPortfolio();
    expect(factories, 0);
    expect(controller.autoRefreshActive, isFalse);
  });
}
