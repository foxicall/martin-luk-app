import 'dart:async';
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
