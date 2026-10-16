import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/background_scan_service.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

// Lifecycle fixtures test ownership only, never real quotes or live-gate proof.
class _Pages implements CandidateRepository {
  _Pages(this.now);
  final DateTime Function() now;
  int calls = 0;
  int attempted = 0;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls++;
    final start = attempted;
    attempted = (attempted + 30).clamp(0, 300).toInt();
    final size = attempted - start;
    return CandidateSnapshot(
      candidates: const [], fetchedAt: now(), warnings: const [],
      source: 'Explicit lifecycle fixture, not live market data',
      universeCount: 300, evaluatedCount: size, scanPoolSize: size,
      adrMatchCount: 0, universeIsComplete: false, universeAsOf: now(),
      scanCompletedAt: now(), candidatesAreCumulative: true,
      coverageTotalCount: 300, coverageScannedCount: attempted,
      coverageEvaluatedCount: attempted, coverageRemainingCount: 300 - attempted,
      coverageRound: 1, scanPageStart: start, scanPageSize: size,
    );
  }
}

class _NativeService implements BackgroundScanService {
  final _events = StreamController<BackgroundScanState>.broadcast(sync: true);
  BackgroundScanState _value = BackgroundScanState.inactive;
  int starts = 0;

  void event(BackgroundScanState value) {
    _value = value;
    if (!_events.isClosed) _events.add(value);
  }

  @override
  bool get supported => true;
  @override
  BackgroundScanState get state => _value;
  @override
  Stream<BackgroundScanState> get states => _events.stream;
  @override
  Future<BackgroundScanState> synchronize() async => _value;
  @override
  Future<BackgroundScanState> start() async {
    starts++;
    event(const BackgroundScanState(active: true, paused: false));
    return _value;
  }
  @override
  Future<BackgroundScanState> stop() async {
    event(BackgroundScanState.inactive);
    return _value;
  }
  @override
  Future<BackgroundScanState> pause() async {
    event(const BackgroundScanState(active: true, paused: true));
    return _value;
  }
  @override
  Future<BackgroundScanState> resume() async {
    event(const BackgroundScanState(active: true, paused: false));
    return _value;
  }
  @override
  Future<void> update({required String title, required String text,
    String? market, int? attempted, int? total, int? evaluated,
    int? remaining}) async {}
  @override
  void dispose() { unawaited(_events.close()); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opt-in service keeps the same scanner across actual app lifecycle transitions',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'martin_luk_settings_v1': jsonEncode(const AppSettings(
        useMockData: false, dataProvider: 'direct', autoRefreshEnabled: false,
      ).toJson()),
    });
    var now = DateTime.utc(2026, 10, 16, 5);
    final pages = _Pages(() => now);
    final native = _NativeService();
    var repositoryCreations = 0;
    final controller = AppController(
      forceMockPreview: false, backgroundScanService: native,
      now: () => now,
      repositoryFactory: (_) { repositoryCreations++; return pages; },
    );
    final binding = tester.binding;
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MartinLukApp(controller: controller));
      await tester.pumpAndSettle();
      expect(controller.autoRefreshActive, isFalse);
      expect(native.starts, 0, reason: 'Opening the app never starts Android work.');

      await controller.startBackgroundScan();
      await tester.pumpAndSettle();
      expect(controller.backgroundScanActive, isTrue);
      expect(controller.autoRefreshActive, isTrue);
      expect(find.byKey(const ValueKey('dashboard-background-scan-status')), findsOneWidget);
      final callsBeforeHidden = pages.calls;
      final factoriesBeforeHidden = repositoryCreations;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(controller.autoRefreshActive, isTrue);
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(pages.calls, greaterThan(callsBeforeHidden));
      expect(repositoryCreations, factoriesBeforeHidden,
          reason: 'A hidden activity must not construct a second scanner.');

      native.event(const BackgroundScanState(active: true, paused: true));
      await tester.pumpAndSettle();
      expect(controller.autoRefreshActive, isFalse);
      final pausedCalls = pages.calls;
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(pages.calls, pausedCalls);

      native.event(const BackgroundScanState(active: true, paused: false));
      await tester.pumpAndSettle();
      expect(controller.autoRefreshActive, isTrue);
      final resumedCalls = pages.calls;
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(pages.calls, greaterThan(resumedCalls));

      native.event(BackgroundScanState.inactive);
      await tester.pumpAndSettle();
      expect(controller.autoRefreshActive, isFalse);
      final stoppedCalls = pages.calls;
      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(pages.calls, stoppedCalls);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(native.starts, 1, reason: 'Returning to the UI does not silently restart the service.');
      expect(controller.backgroundScanActive, isFalse);
      expect(controller.autoRefreshActive, isFalse,
          reason: 'The independent foreground-auto-refresh setting was off.');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}
