import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _timestamp = DateTime.utc(2026, 10, 14, 15);

CandidateSnapshot _snapshot(StockMarket market, {int poolSize = 30,
    int evaluated = 10, int adrMatches = 0,
    String source = 'Yahoo Finance fixture'}) => CandidateSnapshot(
  candidates: [], fetchedAt: _timestamp, warnings: [], source: source,
  universeCount: market == StockMarket.tw ? 900 : 500, stale: false,
  evaluatedCount: evaluated, scanPoolSize: poolSize, adrMatchCount: adrMatches,
  universeIsComplete: true, universeAsOf: _timestamp, scanCompletedAt: _timestamp,
);

class _Call {
  _Call(this.market, this.quotesOnly, this.onProgress);
  final StockMarket market;
  final bool quotesOnly;
  final void Function(MarketScanProgress)? onProgress;
  final completion = Completer<CandidateSnapshot>();

  void progress({int completed = 5, int evaluated = 4, int adr = 2,
      int confirmed = 1, StockMarket? marketOverride}) => onProgress?.call(
    MarketScanProgress(market: marketOverride ?? market,
      universeCount: market == StockMarket.tw ? 900 : 500,
      poolSize: 30, attemptedCount: completed, completedCount: completed,
      evaluatedCount: evaluated, adrMatchCount: adr, confirmedCount: confirmed,
      failedCount: completed - evaluated, finished: false, stage: '批次評估中'),
  );
}

/// Explicit production-shaped fixtures test controller ownership and progress.
/// They do not make real HTTP calls or loosen the separate live CI gate.
class _Scans implements ProgressiveCandidateRepository {
  final calls = <_Call>[];
  bool deferred = false;
  bool fail = false;
  Duration delay = Duration.zero;
  CandidateSnapshot? supplied;

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
    final call = _Call(market, refreshQuotesOnly, onProgress);
    calls.add(call);
    call.progress(completed: 0, evaluated: 0, adr: 0, confirmed: 0);
    if (fail) return Future<CandidateSnapshot>.error(
        const RepositoryException('所有核心股行情均無法取得'));
    if (deferred) return call.completion.future;
    if (delay > Duration.zero) return Future<CandidateSnapshot>.delayed(
        delay, () => supplied ?? _snapshot(market));
    return Future<CandidateSnapshot>.value(supplied ?? _snapshot(market));
  }
}

AppController _controller(_Scans scans, {Duration? commonTimeout,
    Duration? fullTimeout}) => AppController(
  forceMockPreview: false, repositoryFactory: (_) => scans,
  scanUpdateTimeout: commonTimeout, directMarketScanTimeout: fullTimeout,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(const AppSettings(
        useMockData: false, dataProvider: 'direct', autoRefreshEnabled: false).toJson()),
  }));

  test('batch progress notifies counts without fabricating a completed snapshot', () async {
    final scans = _Scans()..fail = true;
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot!.isFallback, isTrue);
    scans..fail = false..deferred = true;
    final running = controller.refresh();
    final call = scans.calls.last;
    var notifications = 0;
    controller.addListener(() => notifications++);
    call.progress();
    expect(controller.isEvaluatingMarket, isTrue);
    expect(controller.marketScanProgress!.completedCount, 5);
    expect(controller.marketScanProgress!.evaluatedCount, 4);
    expect(controller.marketScanProgress!.adrMatchCount, 2);
    expect(controller.marketScanProgress!.label, contains('已掃描 5/30 檔'));
    expect(controller.snapshot!.isFallback, isTrue);
    expect(notifications, greaterThan(0));
    call.completion.complete(_snapshot(StockMarket.tw));
    await running;
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.generatedAt, _timestamp);
    expect(controller.snapshot!.scanPoolSize, 30);
    expect(controller.snapshot!.adrMatchCount, 0);
    expect(controller.marketScanProgress!.finished, isTrue);
  });

  test('stop settles active and queued pulls, retains dated snapshot and ignores late progress', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final committed = controller.snapshot;
    scans.deferred = true;
    final running = controller.refresh(forceRefresh: false);
    final queued = controller.refresh();
    final call = scans.calls.last;
    call.progress();
    controller.cancelMarketEvaluation();
    await Future.wait([running, queued]);
    expect(controller.loading, isFalse);
    expect(controller.snapshot, same(committed));
    expect(controller.marketScanProgress!.stage, '掃描已停止');
    expect(controller.marketScanProgress!.finished, isTrue);
    call.progress(completed: 10, evaluated: 10, adr: 9, confirmed: 8);
    call.completion.complete(_snapshot(StockMarket.tw, evaluated: 30, adrMatches: 20));
    await Future<void>.delayed(Duration.zero);
    expect(controller.marketScanProgress!.completedCount, 5);
    expect(controller.snapshot, same(committed));
    scans.deferred = false;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
  });

  test('market switch ignores cancelled and mismatched-market progress', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = true;
    final old = controller.refresh();
    final tw = scans.calls.last;
    final changed = controller.setMarket(StockMarket.us);
    final us = scans.calls.last;
    tw.progress(completed: 10, evaluated: 10, adr: 8, confirmed: 5);
    us.progress(marketOverride: StockMarket.tw);
    expect(controller.marketScanProgress!.market, StockMarket.us);
    expect(controller.marketScanProgress!.completedCount, 0);
    us.progress();
    us.completion.complete(_snapshot(StockMarket.us));
    await changed;
    await old;
    tw.completion.complete(_snapshot(StockMarket.tw));
    await Future<void>.delayed(Duration.zero);
    expect(controller.market, StockMarket.us);
    expect(controller.snapshot!.universeCount, 500);
    expect(controller.marketScanProgress!.market, StockMarket.us);
    expect(controller.loading, isFalse);
  });

  test('inconsistent or backwards progress cannot change verified counters', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = true;
    final running = controller.refresh();
    final call = scans.calls.last;
    call.progress();
    call.progress(completed: 4, evaluated: 4);
    call.progress(completed: 10, evaluated: 11);
    expect(controller.marketScanProgress!.completedCount, 5);
    expect(controller.marketScanProgress!.evaluatedCount, 4);
    call.completion.complete(_snapshot(StockMarket.tw));
    await running;
    expect(controller.loading, isFalse);
  });

  test('source switch rejects late counts and snapshots from the old direct owner', () async {
    final direct = _Scans();
    final backend = _Scans()..supplied = _snapshot(StockMarket.tw,
        source: 'Authenticated backend fixture');
    final controller = AppController(forceMockPreview: false,
        repositoryFactory: (settings) => settings.dataProvider == 'backend' ? backend : direct);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    direct.deferred = true;
    final old = controller.refresh();
    final cancelled = direct.calls.last;
    await controller.updateSettings(controller.settings.copyWith(
        dataProvider: 'backend', apiBaseUrl: 'https://example.com'));
    expect(controller.snapshot!.source, 'Authenticated backend fixture');
    cancelled.progress(completed: 20, evaluated: 20, adr: 18, confirmed: 15);
    cancelled.completion.complete(_snapshot(StockMarket.tw));
    await old;
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot!.source, 'Authenticated backend fixture');
    expect(controller.marketScanProgress!.completedCount, 0);
    expect(controller.loading, isFalse);
  });

  test('explicit short scan timeout still releases a hung direct scan and permits retry', () async {
    final scans = _Scans();
    final controller = _controller(scans, commonTimeout: const Duration(milliseconds: 30));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final old = controller.snapshot;
    scans.deferred = true;
    final expired = scans.calls.length;
    await controller.refresh().timeout(const Duration(seconds: 1));
    expect(scans.calls.length, expired + 1);
    expect(controller.loading, isFalse);
    expect(controller.error, contains('逾時'));
    expect(controller.snapshot!.generatedAt, old!.generatedAt);
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.snapshot!.scanPoolSize, 30);
    expect(controller.marketScanProgress!.stage, contains('硬逾時'));
    scans.calls.last.completion.complete(_snapshot(StockMarket.tw));
    scans.deferred = false;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
    expect(controller.snapshot!.stale, isFalse);
  });

  test('full direct scan gets its distinct budget while hot quotes retain the short budget', () async {
    final scans = _Scans()..delay = const Duration(milliseconds: 60);
    final controller = _controller(scans, commonTimeout: const Duration(milliseconds: 20),
        fullTimeout: const Duration(milliseconds: 300));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot, isNotNull);
    expect(controller.error, isNull);
    await controller.refresh(refreshQuotesOnly: true);
    expect(controller.loading, isFalse);
    expect(controller.error, contains('逾時'));
    expect(controller.snapshot!.stale, isTrue);
    // Observe the fixture's late completion before teardown.
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  test('queued full scan cannot extend the preceding scan deadline', () async {
    final scans = _Scans();
    final controller = _controller(scans, commonTimeout: const Duration(milliseconds: 30),
        fullTimeout: const Duration(milliseconds: 300));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans.deferred = true;
    final hot = controller.refresh(forceRefresh: false, refreshQuotesOnly: true);
    final previous = scans.calls.last;
    final forced = controller.refresh(refreshQuotesOnly: false);
    scans..deferred = false..delay = const Duration(milliseconds: 60);
    previous.completion.complete(_snapshot(StockMarket.tw));
    await hot;
    await forced;
    expect(scans.calls.last.quotesOnly, isFalse);
    expect(controller.error, contains('逾時'));
    expect(controller.snapshot!.stale, isTrue);
    expect(controller.loading, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  test('invalid core-pool statistics cannot overwrite a verified snapshot', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    for (final invalid in [
      _snapshot(StockMarket.tw, poolSize: 901),
      _snapshot(StockMarket.tw, poolSize: 5, evaluated: 10),
      _snapshot(StockMarket.tw, evaluated: 10, adrMatches: 11),
    ]) {
      scans.supplied = invalid;
      await controller.refresh();
      expect(controller.loading, isFalse);
      expect(controller.error, contains('統計無效'));
      expect(controller.snapshot!.scanPoolSize, 30);
      expect(controller.snapshot!.adrMatchCount, 0);
      expect(controller.snapshot!.generatedAt, _timestamp);
    }
  });

  test('disposal suppresses late progress and settles both public pull futures', () async {
    final scans = _Scans();
    final controller = _controller(scans);
    await controller.initialize(initializeReminders: false);
    scans.deferred = true;
    final running = controller.refresh(forceRefresh: false);
    final queued = controller.refresh();
    final call = scans.calls.last;
    controller.dispose();
    await Future.wait([running, queued]);
    call.progress();
    call.completion.complete(_snapshot(StockMarket.tw));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isFalse);
    expect(controller.marketScanProgress!.completedCount, 0);
  });

  testWidgets('cold scan shows batch counts and stop action rather than static missing data', (tester) async {
    final scans = _Scans()..fail = true;
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans..fail = false..deferred = true;
    final running = controller.refresh();
    scans.calls.last.progress();
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pump();
    expect(find.text('本次核心池'), findsOneWidget);
    expect(find.text('已評估'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.textContaining('已掃描 5/30 檔'), findsOneWidget);
    expect(find.text('尚未取得評估快照'), findsNothing);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('market-scan-progress')));
    expect(bar.value, closeTo(5 / 30, 0.00001));
    await tester.tap(find.byKey(const ValueKey('stop-market-evaluation')));
    await tester.pump();
    await running;
    expect(find.byKey(const ValueKey('market-scan-progress')), findsNothing);
    expect(find.text('重試'), findsOneWidget);
    expect(find.text('市場評估未完成，請重試'), findsOneWidget);
    expect(controller.loading, isFalse);
    scans.calls.last.completion.complete(_snapshot(StockMarket.tw));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('successful empty core scan has a snapshot timestamp and no loading indicator', (tester) async {
    final scans = _Scans();
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.snapshot!.adrMatchCount, 0);
    expect(find.textContaining('資料更新時間：'), findsOneWidget);
    expect(find.text('目前沒有符合條件的標的'), findsOneWidget);
    expect(find.text('尚未取得評估快照'), findsNothing);
    expect(find.byKey(const ValueKey('market-scan-progress')), findsNothing);
    expect(find.text('重試'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed cold scan retains counts with an explicit diagnostic fallback', (tester) async {
    final scans = _Scans()..fail = true;
    final controller = _controller(scans);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    scans..fail = false..deferred = true;
    final running = controller.refresh();
    final call = scans.calls.last;
    call.progress(completed: 10, evaluated: 0, adr: 0, confirmed: 0);
    call.completion.completeError(const RepositoryException('核心股票池 HTTP 429'));
    await running;
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(controller.snapshot!.isFallback, isTrue);
    expect(controller.loading, isFalse);
    expect(find.text('—'), findsNothing);
    expect(find.textContaining('已掃描 10/30 檔'), findsOneWidget);
    expect(find.textContaining('失敗 10'), findsOneWidget);
    expect(find.textContaining('核心股票池 HTTP 429'), findsWidgets);
    expect(find.text('重試'), findsOneWidget);
    expect(find.textContaining('資料更新時間：'), findsNothing);
    expect(find.byKey(const ValueKey('market-scan-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
