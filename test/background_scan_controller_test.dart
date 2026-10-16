import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/background_scan_service.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Deterministic lifecycle/ownership fixtures, never live-market evidence.
final _now = DateTime.utc(2026, 10, 16, 5);

class _Call {
  _Call(this.market, this.quotesOnly);
  final StockMarket market;
  final bool quotesOnly;
}

class _Scans implements ProgressiveCandidateRepository {
  final calls = <_Call>[];
  Future<CandidateSnapshot> Function(_Call)? reply;
  void Function(MarketScanProgress)? onProgress;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) => fetchWithProgress(market, adrThreshold: adrThreshold,
      forceRefresh: forceRefresh, refreshQuotesOnly: refreshQuotesOnly);

  @override
  Future<CandidateSnapshot> fetchWithProgress(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
    void Function(MarketScanProgress)? onProgress,
  }) {
    this.onProgress = onProgress;
    final call = _Call(market, refreshQuotesOnly);
    calls.add(call);
    return reply?.call(call) ?? Future.value(_snapshot(
      market, scanned: calls.where((item) => item.market == market).length * 30));
  }
}

CandidateSnapshot _snapshot(StockMarket market, {int scanned = 30,
    int universe = 300, int evaluated = 30, int? pageStart,
    bool usRolling = false}) =>
    CandidateSnapshot(
      candidates: const [], fetchedAt: _now, warnings: const [],
      source: 'Yahoo Finance lifecycle fixture', universeCount: universe,
      stale: false, evaluatedCount: evaluated, scanPoolSize: 30, adrMatchCount: 0,
      universeIsComplete: false, universeAsOf: _now, scanCompletedAt: _now,
      candidatesAreCumulative: market == StockMarket.tw || usRolling,
      coverageTotalCount: market == StockMarket.tw || usRolling ? universe : null,
      coverageScannedCount: market == StockMarket.tw || usRolling ? scanned : null,
      coverageEvaluatedCount: market == StockMarket.tw || usRolling ? scanned : null,
      coverageRemainingCount: market == StockMarket.tw || usRolling ? universe - scanned : null,
      coverageRound: market == StockMarket.tw || usRolling ? 1 : null,
      scanPageStart: market == StockMarket.tw || usRolling ? pageStart ?? scanned - 30 : null,
      scanPageSize: market == StockMarket.tw || usRolling ? 30 : null,
      universeFingerprint: market == StockMarket.tw || usRolling ? 'background-fixture' : null,
    );

class _Background implements BackgroundScanService {
  _Background({this.supported = true});
  @override
  final bool supported;
  @override
  BackgroundScanState state = BackgroundScanState.inactive;
  final _events = StreamController<BackgroundScanState>.broadcast(sync: true);
  int starts = 0;
  int stops = 0;
  bool disposed = false;
  Future<BackgroundScanState> Function()? onStart;
  final updates = <String>[];
  @override
  Stream<BackgroundScanState> get states => _events.stream;

  void emit(BackgroundScanState value) {
    if (disposed) return;
    state = value;
    _events.add(value);
  }

  @override
  Future<BackgroundScanState> synchronize() async => state;
  @override
  Future<BackgroundScanState> start() async {
    starts++;
    final value = await (onStart?.call() ?? Future.value(
        const BackgroundScanState(active: true, paused: false)));
    emit(value);
    return value;
  }
  @override
  Future<BackgroundScanState> stop() async {
    stops++;
    emit(BackgroundScanState.inactive);
    return state;
  }
  @override
  Future<BackgroundScanState> pause() async {
    emit(const BackgroundScanState(active: true, paused: true));
    return state;
  }
  @override
  Future<BackgroundScanState> resume() async {
    emit(const BackgroundScanState(active: true, paused: false));
    return state;
  }
  @override
  Future<void> update({required String title, required String text,
    String? market, int? attempted, int? total, int? evaluated,
    int? remaining}) async {
    updates.add(text);
  }
  @override
  void dispose() {
    disposed = true;
    unawaited(_events.close());
  }
}

void _seed({bool autoRefresh = false, bool mock = false,
    String provider = 'direct'}) {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: mock, dataProvider: provider,
      apiBaseUrl: 'https://example.invalid', autoRefreshEnabled: autoRefresh,
    ).toJson()),
  });
}

AppController _controller(_Scans scans, _Background background,
    {DateTime Function()? now}) => AppController(
  forceMockPreview: false, repositoryFactory: (_) => scans,
  backgroundScanService: background, now: now ?? () => _now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_seed);

  testWidgets('explicit service keeps one Taiwan page owner across background',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      expect(service.starts, 0, reason: 'Initialization must not start Android.');
      controller.setForeground(true);
      scans.reply = (_) => pending.future;
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      expect(service.starts, 1);
      expect(controller.backgroundScanActive, isTrue);
      expect(controller.settings.autoRefreshEnabled, isFalse,
          reason: 'Service opt-in must not rewrite the ordinary polling setting.');
      expect(scans.calls.length, 2);
      expect(controller.loading, isTrue);
      controller.setForeground(false);
      expect(controller.loading, isTrue,
          reason: 'The same active page retains ownership when Android is running.');
      expect(controller.autoRefreshActive, isTrue);
      await controller.pollNow();
      expect(scans.calls.length, 2, reason: 'No overlapping poll batch is allowed.');
      pending.complete(_snapshot(StockMarket.tw, scanned: 60));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 60);
      expect(controller.loading, isFalse);
      scans.reply = (_) async => _snapshot(StockMarket.tw, scanned: 90);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(scans.calls.length, 3);
      expect(scans.calls.last.quotesOnly, isFalse);
      expect(controller.snapshot!.coverageScannedCount, 90);
      expect(service.updates.first, contains('已嘗試 30/300'));
    } finally {
      controller.dispose();
    }
    expect(service.disposed, isTrue);
    expect(controller.autoRefreshActive, isFalse);
  });

  testWidgets('without service the existing background cancellation stays intact',
      (tester) async {
    _seed(autoRefresh: true);
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      final original = controller.snapshot;
      scans.reply = (_) => pending.future;
      controller.setForeground(true);
      await tester.pump();
      expect(controller.loading, isTrue);
      controller.setForeground(false);
      expect(controller.loading, isFalse);
      expect(controller.autoRefreshActive, isFalse);
      pending.complete(_snapshot(StockMarket.tw, scanned: 60));
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      expect(controller.snapshot, same(original));
      expect(scans.calls.length, 2);
      expect(service.starts, 0);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('notification pause and stop retire hidden requests then allow explicit resume',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      controller.setForeground(false);
      scans.reply = (_) => pending.future;
      final inFlight = controller.pollNow();
      expect(controller.loading, isTrue);
      final original = controller.snapshot;
      service.emit(const BackgroundScanState(active: true, paused: true));
      await tester.pump();
      await inFlight;
      expect(controller.backgroundScanPaused, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.polling, isFalse);
      expect(controller.autoRefreshActive, isFalse);
      pending.complete(_snapshot(StockMarket.tw, scanned: 90));
      await tester.pump();
      expect(controller.snapshot, same(original));
      final stoppedCount = scans.calls.length;
      await tester.pump(const Duration(minutes: 2));
      expect(scans.calls.length, stoppedCount);
      scans.reply = (_) async => _snapshot(StockMarket.tw, scanned: 90);
      service.emit(const BackgroundScanState(active: true, paused: false));
      await tester.pump();
      expect(scans.calls.length, stoppedCount + 1);
      expect(controller.autoRefreshActive, isTrue);
      service.emit(BackgroundScanState.inactive);
      await tester.pump();
      expect(controller.backgroundScanActive, isFalse);
      expect(controller.autoRefreshActive, isFalse);
      await tester.pump(const Duration(minutes: 2));
      expect(scans.calls.length, stoppedCount + 1);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('start permission failure clears busy and permits a real retry',
      (tester) async {
    final scans = _Scans();
    final service = _Background()..onStart = () async =>
        throw StateError('notification permission denied');
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      final failed = controller.startBackgroundScan();
      await tester.pump();
      await failed;
      expect(controller.backgroundScanBusy, isFalse);
      expect(controller.backgroundScanActive, isFalse);
      expect(controller.backgroundScanError, contains('permission denied'));
      service.onStart = null;
      final retried = controller.startBackgroundScan();
      await tester.pump();
      await retried;
      expect(service.starts, 2);
      expect(controller.backgroundScanActive, isTrue);
      expect(controller.backgroundScanError, isNull);
      expect(controller.backgroundScanBusy, isFalse);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('dispose ignores a delayed start and clears polling ownership',
      (tester) async {
    final scans = _Scans();
    final pending = Completer<BackgroundScanState>();
    final service = _Background()..onStart = () => pending.future;
    final controller = _controller(scans, service);
    await tester.runAsync(() => controller.initialize(initializeReminders: false));
    controller.setForeground(true);
    final started = controller.startBackgroundScan();
    await tester.pump();
    expect(controller.backgroundScanBusy, isTrue);
    final count = scans.calls.length;
    controller.dispose();
    pending.complete(const BackgroundScanState(active: true, paused: false));
    await tester.pump();
    await started;
    await tester.pump(const Duration(minutes: 2));
    expect(controller.backgroundScanActive, isFalse);
    expect(controller.backgroundScanBusy, isFalse);
    expect(service.stops, 1,
        reason: 'A pending permission/start must also receive native stop.');
    expect(controller.autoRefreshActive, isFalse);
    expect(scans.calls.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source changes stop Android before changing configuration',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      final changed = controller.updateSettings(controller.settings.copyWith(
        useMockData: true));
      await tester.pump();
      await tester.runAsync(() => changed);
      expect(service.stops, 1);
      expect(controller.backgroundScanActive, isFalse);
      expect(controller.settings.useMockData, isTrue);
      final count = scans.calls.length;
      controller.setForeground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(scans.calls.length, count);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('legacy US background responses without coverage retain bounded hot-quote scope',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      controller.setForeground(false);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(scans.calls.last.market, StockMarket.us);
      expect(scans.calls.last.quotesOnly, isTrue,
          reason: 'Legacy responses without rolling coverage must not claim a full-US scan.');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('service pause while visible returns to ordinary configured polling',
      (tester) async {
    _seed(autoRefresh: true);
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      await tester.pump();
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      service.emit(const BackgroundScanState(active: true, paused: true));
      final count = scans.calls.length;
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(controller.autoRefreshActive, isTrue);
      expect(scans.calls.length, count + 1);
      controller.setForeground(false);
      expect(controller.autoRefreshActive, isFalse);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('successful native messages are information rather than command errors',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      service.emit(const BackgroundScanState(active: true, paused: true,
        message: '已從通知暫停背景更新。'));
      expect(controller.backgroundScanMessage, '已從通知暫停背景更新。');
      expect(controller.backgroundScanError, isNull);
      service.emit(const BackgroundScanState(active: false, paused: false,
        message: '已停止背景更新。'));
      expect(controller.backgroundScanMessage, '已停止背景更新。');
      expect(controller.backgroundScanError, isNull);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('US notification denominator is the evaluated pool not five thousand identities',
      (tester) async {
    final scans = _Scans()..reply = (call) async => _snapshot(call.market,
      universe: call.market == StockMarket.us ? 5000 : 300);
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      expect(controller.snapshot!.universeCount, 5000);
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      expect(service.updates, isNotEmpty);
      expect(service.updates.first, contains('美股核心精選池'));
      expect(service.updates.first, contains('已嘗試 30/30'));
      expect(service.updates.every((text) => !text.contains('/5000')), isTrue,
          reason: 'Search identities must never be presented as scanned stocks.');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('Taiwan notification uses validated current partial cumulative coverage',
      (tester) async {
    final scans = _Scans();
    final service = _Background();
    var instant = _now;
    final controller = _controller(scans, service, now: () => instant);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      expect(controller.snapshot!.coverageScannedCount, 30);
      scans.reply = (_) => pending.future;
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      expect(controller.loading, isTrue);
      instant = instant.add(const Duration(seconds: 2));
      scans.onProgress!(MarketScanProgress(
        market: StockMarket.tw, universeCount: 300, poolSize: 30,
        attemptedCount: 5, completedCount: 5, evaluatedCount: 5,
        adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
        finished: false, stage: '第二頁分批評估中',
        partialSnapshot: _snapshot(StockMarket.tw,
          scanned: 35, evaluated: 5, pageStart: 30),
      ));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 30,
          reason: 'An in-flight partial must not become a completed snapshot.');
      expect(service.updates.last, contains('已嘗試 35/300'));
      expect(service.updates.last, contains('已評估 35'));
      expect(service.updates.last, contains('剩餘 265'));
      pending.complete(_snapshot(StockMarket.tw, scanned: 60));
      await tester.pump();
    } finally {
      controller.dispose();
    }
  });

  testWidgets('full US service advances pages in background and reports the actual round coverage',
      (tester) async {
    final scans = _Scans();
    scans.reply = (call) async => _snapshot(call.market,
      universe: call.market == StockMarket.us ? 5000 : 300,
      scanned: scans.calls.where((item) => item.market == call.market).length * 30,
      usRolling: call.market == StockMarket.us);
    final service = _Background();
    final controller = _controller(scans, service);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      expect(controller.snapshot!.coverageScannedCount, 30);
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      expect(controller.snapshot!.coverageScannedCount, 60);
      controller.setForeground(false);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 90);
      expect(scans.calls.last.quotesOnly, isFalse);
      expect(controller.autoRefreshActive, isTrue);
      expect(service.updates.first, contains('美股三大交易所輪掃'));
      expect(service.updates.first, contains('已嘗試 30/5000'));
      expect(service.updates.first, contains('剩餘 4970'));
      expect(service.updates.every((text) => !text.contains('核心精選池')), isTrue);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('full US notification prefers validated current partial coverage over the old page',
      (tester) async {
    final scans = _Scans()..reply = (call) async => _snapshot(call.market,
      universe: call.market == StockMarket.us ? 5000 : 300,
      usRolling: call.market == StockMarket.us);
    final service = _Background();
    var instant = _now;
    final controller = _controller(scans, service, now: () => instant);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      scans.reply = (_) => pending.future;
      controller.setForeground(true);
      final started = controller.startBackgroundScan();
      await tester.pump();
      await started;
      expect(controller.loading, isTrue);
      instant = instant.add(const Duration(seconds: 2));
      scans.onProgress!(MarketScanProgress(
        market: StockMarket.us, universeCount: 5000, poolSize: 30,
        attemptedCount: 5, completedCount: 5, evaluatedCount: 5,
        adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
        finished: false, stage: 'US second page',
        partialSnapshot: _snapshot(StockMarket.us, universe: 5000,
          scanned: 35, evaluated: 5, pageStart: 30, usRolling: true),
      ));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 30);
      expect(service.updates.last, contains('美股三大交易所輪掃'));
      expect(service.updates.last, contains('已嘗試 35/5000'));
      expect(service.updates.last, contains('已評估 35'));
      expect(service.updates.last, contains('剩餘 4965'));
      pending.complete(_snapshot(StockMarket.us,
        universe: 5000, scanned: 60, usRolling: true));
      await tester.pump();
    } finally {
      controller.dispose();
    }
  });
}
