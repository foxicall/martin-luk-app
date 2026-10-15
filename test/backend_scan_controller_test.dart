import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/backend_scan_status.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _quoteTime = DateTime.utc(2026, 10, 15, 1);
final _progressTime = DateTime.utc(2026, 10, 15, 1, 5);

BackendScanStatus _status({StockMarket market = StockMarket.tw,
    String status = 'running', int completed = 0, String job = 'scan-1'}) =>
    BackendScanStatus(
      market: market, jobId: job, status: status,
      stage: status == 'completed' ? 'completed' : 'evaluating',
      startedAt: _progressTime.subtract(const Duration(seconds: 10)),
      updatedAt: _progressTime, completedCount: completed,
      totalCount: 30, evaluatedCount: completed, adrMatchCount: 0,
      failedCount: 0, universeCount: market == StockMarket.tw ? 900 : 500,
      completedAt: status == 'completed' ? _progressTime : null,
    );

CandidateSnapshot _pending({StockMarket market = StockMarket.tw,
    int completed = 0, String job = 'scan-1'}) => CandidateSnapshot(
      candidates: const [], fetchedAt: _progressTime, warnings: const [],
      source: 'Python API 背景掃描進度',
      universeCount: market == StockMarket.tw ? 900 : 500,
      stale: true, isPending: true,
      backendScan: _status(market: market, completed: completed, job: job),
    );

CandidateSnapshot _completed({StockMarket market = StockMarket.tw,
    bool running = false, bool stale = false}) => CandidateSnapshot(
      candidates: const [], fetchedAt: _quoteTime, warnings: const [],
      source: 'Yahoo Finance via Python API',
      universeCount: market == StockMarket.tw ? 900 : 500,
      scanPoolSize: 30, evaluatedCount: 30, adrMatchCount: 0,
      stale: stale, scanCompletedAt: _quoteTime,
      backendScan: _status(market: market,
          status: running ? 'running' : 'completed',
          completed: running ? 5 : 30),
    );

class _Call {
  _Call(this.market, this.force, this.quotesOnly);
  final StockMarket market;
  final bool force;
  final bool quotesOnly;
}

class _Repository implements CandidateRepository {
  final calls = <_Call>[];
  Future<CandidateSnapshot> Function(_Call call)? reply;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) {
    final call = _Call(market, forceRefresh, refreshQuotesOnly);
    calls.add(call);
    return reply?.call(call) ?? Future.value(_pending(market: market));
  }
}

void _seed({bool autoRefresh = false}) {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: false, dataProvider: 'backend',
      apiBaseUrl: 'https://example.invalid', autoRefreshEnabled: autoRefresh,
    ).toJson()),
  });
}

AppController _controller(_Repository repository, {
    Duration timeout = const Duration(seconds: 8),
    Duration waitTimeout = const Duration(minutes: 3)}) => AppController(
      forceMockPreview: false, repositoryFactory: (_) => repository,
      scanUpdateTimeout: timeout, backendScanWaitTimeout: waitTimeout,
    );

// Polling test fixture v2: dispose foreground timers inside widget callbacks.
// Foreground resumption schedules Timer(Duration.zero), an event timer.
// In testWidgets, pump() without a duration only flushes microtasks: it does
// NOT elapse fake timers. Use pump(Duration.zero) after setForeground(true)
// so requests actually start before testing timeout, cancellation or disposal.
// Keep initialization inside runAsync for SharedPreferences platform setup;
// lifecycle changes and timer advancement stay in the widget test's fake zone.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_seed);

  test('202 ends refresh immediately without a fake successful snapshot', () async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.loading, isFalse);
    expect(controller.snapshot, isNull);
    expect(controller.lastUpdated, isNull);
    expect(controller.waitingForBackendScan, isTrue);
    expect(controller.backendScanStatus!.completedCount, 0);
    expect(controller.error, isNull);
    await controller.refresh().timeout(const Duration(seconds: 1));
    expect(repository.calls.length, 2);
    expect(controller.snapshot, isNull);
    expect(controller.loading, isFalse);
  });

  test('warm background scan preserves actual quote time and stale flag', () async {
    final repository = _Repository()
      ..reply = (_) async => _completed(running: true, stale: true);
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final kept = controller.snapshot;
    expect(kept!.generatedAt, _quoteTime);
    expect(kept.stale, isTrue);
    expect(controller.backendScanStatus!.updatedAt, _progressTime);
    repository.reply = (_) async => _pending(completed: 10);
    await controller.refresh();
    expect(controller.snapshot, same(kept));
    expect(controller.lastUpdated, _quoteTime);
    expect(controller.backendScanStatus!.completedCount, 10);
  });

  testWidgets('foreground polls every three seconds until a real empty scan finishes', (tester) async {
    final repository = _Repository();
    repository.reply = (call) async => repository.calls.length < 3
        ? _pending(completed: repository.calls.length == 2 ? 5 : 0)
        : _completed();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(repository.calls.length, 2);
    expect(repository.calls.last.force, isFalse);
    expect(repository.calls.last.quotesOnly, isTrue);
    expect(controller.backendScanStatus!.completedCount, 5);
    expect(controller.loading, isFalse);
    // No polling before the advertised three-second retry interval.
    await tester.pump(const Duration(milliseconds: 2999));
    expect(repository.calls.length, 2);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(repository.calls.length, 3);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.snapshot!.candidates, isEmpty);
    expect(controller.snapshot!.isFallback, isFalse);
    expect(controller.lastUpdated, _quoteTime);
    expect(controller.error, isNull);
  });

  testWidgets('one slow status request cannot create overlapping timer requests', (tester) async {
    final delayed = Completer<CandidateSnapshot>();
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    repository.reply = (_) => delayed.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    expect(repository.calls.length, 2);
    expect(controller.loading, isTrue);
    final joined = controller.refresh(forceRefresh: false, refreshQuotesOnly: true);
    await tester.pump(const Duration(seconds: 3));
    expect(repository.calls.length, 2);
    delayed.complete(_completed());
    await tester.pump();
    await joined;
    expect(controller.loading, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
  });

  testWidgets('server failure stops polling and manual retry recovers', (tester) async {
    _seed(autoRefresh: true);
    final repository = _Repository();
    final controller = _controller(repository);
    // Flutter verifies pending timers before package-level addTearDown.
    // Release this foreground controller before the widget callback returns,
    // including when an assertion fails; leave no periodic/status/deadline timer.
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      repository.reply = (_) async => throw const RepositoryException('HTTP 503 upstream unavailable');
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(controller.loading, isFalse);
      expect(controller.waitingForBackendScan, isFalse);
      expect(controller.backendScanStatus!.isFailed, isTrue);
      expect(controller.error, contains('503'));
      final calls = repository.calls.length;
      await tester.pump(const Duration(minutes: 1));
      expect(repository.calls.length, calls);
      repository.reply = (_) async => _completed();
      final retry = controller.refresh();
      await tester.pump();
      await retry;
      expect(controller.error, isNull);
      expect(controller.snapshot!.isFallback, isFalse);
      expect(controller.backendScanStatus!.status, 'completed');
    } finally {
      controller.dispose();
    }
    expect(controller.autoRefreshActive, isFalse);
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.loading, isFalse);
  });

  testWidgets('bounded status timeout releases loading and ignores its late reply', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository, timeout: const Duration(milliseconds: 20));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final delayed = Completer<CandidateSnapshot>();
    repository.reply = (_) => delayed.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 25));
    expect(controller.loading, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.error, contains('逾時'));
    final kept = controller.snapshot;
    delayed.complete(_completed());
    await tester.pump();
    expect(controller.snapshot, same(kept));
  });

  testWidgets('background cancels status ownership and resumes only on foreground', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final delayed = Completer<CandidateSnapshot>();
    repository.reply = (_) => delayed.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    controller.setForeground(false);
    delayed.complete(_completed());
    await tester.pump(const Duration(seconds: 10));
    expect(controller.loading, isFalse);
    expect(controller.snapshot, isNull);
    expect(controller.waitingForBackendScan, isTrue);
    expect(repository.calls.length, 2);
    repository.reply = (_) async => _completed();
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(repository.calls.length, 3);
    expect(controller.snapshot!.isFallback, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
  });

  testWidgets('stop only stops this client and a manual pull can resume', (tester) async {
    _seed(autoRefresh: true);
    final repository = _Repository();
    final controller = _controller(repository);
    // Flutter verifies pending timers before package-level addTearDown.
    // Release this foreground controller before the widget callback returns,
    // including when an assertion fails; leave no periodic/status/deadline timer.
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      controller.cancelMarketEvaluation();
      expect(controller.waitingForBackendScan, isFalse);
      expect(controller.backendStatusPollingActive, isFalse);
      expect(controller.backendScanStatus!.isRunning, isTrue);
      final calls = repository.calls.length;
      await tester.pump(const Duration(minutes: 1));
      expect(repository.calls.length, calls);
      final retry = controller.refresh();
      await tester.pump();
      await retry;
      expect(controller.waitingForBackendScan, isTrue);
      expect(controller.backendStatusPollingActive, isTrue);
    } finally {
      controller.dispose();
    }
    expect(controller.autoRefreshActive, isFalse);
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.loading, isFalse);
  });

  testWidgets('market switch rejects an old pending reply and keeps the new market', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final oldReply = Completer<CandidateSnapshot>();
    repository.reply = (call) => call.market == StockMarket.tw
        ? oldReply.future : Future.value(_completed(market: StockMarket.us));
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    final switched = controller.setMarket(StockMarket.us);
    await tester.pump();
    await switched;
    oldReply.complete(_pending(completed: 15));
    await tester.pump();
    expect(controller.market, StockMarket.us);
    expect(controller.backendScanStatus!.market, StockMarket.us);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.error, isNull);
  });

  testWidgets('source change clears pending status and rejects old HTTP results', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final oldReply = Completer<CandidateSnapshot>();
    repository.reply = (_) => oldReply.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    repository.reply = (_) async => CandidateSnapshot(
      candidates: const [], fetchedAt: _quoteTime, warnings: const [],
      source: 'Yahoo Finance direct', universeCount: 900,
      scanPoolSize: 30, evaluatedCount: 30, adrMatchCount: 0,
      stale: false, scanCompletedAt: _quoteTime,
    );
    await tester.runAsync(() => controller.updateSettings(
        controller.settings.copyWith(dataProvider: 'direct')));
    oldReply.complete(_pending(completed: 15));
    await tester.pump();
    expect(controller.settings.dataProvider, 'direct');
    expect(controller.backendScanStatus, isNull);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.snapshot!.source, 'Yahoo Finance direct');
  });

  testWidgets('ADR change starts a new job and rejects the previous threshold reply', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final oldReply = Completer<CandidateSnapshot>();
    repository.reply = (_) => oldReply.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    repository.reply = (_) async => _pending(job: 'new-threshold');
    await tester.runAsync(() => controller.updateSettings(
        controller.settings.copyWith(twAdrThreshold: 4)));
    oldReply.complete(_pending(completed: 25));
    await tester.pump();
    expect(controller.settings.twAdrThreshold, 4);
    expect(controller.backendScanStatus!.jobId, 'new-threshold');
    expect(controller.backendScanStatus!.completedCount, 0);
    expect(controller.waitingForBackendScan, isTrue);
    expect(controller.loading, isFalse);
  });

  testWidgets('foreground status wait has its own finite overall budget', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository,
        waitTimeout: const Duration(milliseconds: 20));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 25));
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.loading, isFalse);
    expect(controller.backendScanStatus!.isFailed, isTrue);
    expect(controller.error, contains('超過上限'));
  });

  testWidgets('dispose prevents late HTTP callbacks and clears status timers', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    var disposed = false;
    addTearDown(() {
      if (!disposed) controller.dispose();
    });
    var notifications = 0;
    controller.addListener(() => notifications++);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    final delayed = Completer<CandidateSnapshot>();
    repository.reply = (_) => delayed.future;
    controller.setForeground(true);
    await tester.pump(Duration.zero);
    // Prove the delayed request really started and its error handler is
    // attached before completing it with an error after disposal.
    expect(repository.calls.length, 2);
    expect(controller.loading, isTrue);
    expect(controller.waitingForBackendScan, isTrue);
    controller.dispose();
    disposed = true;
    final notificationsAtDispose = notifications;
    expect(controller.backendStatusPollingActive, isFalse);
    expect(controller.autoRefreshActive, isFalse);
    expect(controller.waitingForBackendScan, isFalse);
    expect(controller.loading, isFalse);
    delayed.completeError(StateError('late disposed failure must be consumed'));
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
    expect(repository.calls.length, 2);
    expect(notifications, notificationsAtDispose);
  });

  testWidgets('dashboard shows nonblocking progress instead of no snapshot text', (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pump();
    expect(find.byKey(const ValueKey('backend-scan-progress')), findsOneWidget);
    expect(find.text('尚未取得評估快照'), findsNothing);
    expect(find.text('Python 背景掃描進行中'), findsWidgets);
    expect(find.byKey(const ValueKey('market-scan-progress')), findsNothing);
    expect(controller.loading, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
