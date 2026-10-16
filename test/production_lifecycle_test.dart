import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Flutter restores a paused app through hidden and inactive before resumed.
// Keep this sequence valid for AppLifecycleListener as well as the controller.
void _resumeApp(WidgetsBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

class _LifecycleScans implements CandidateRepository {
  int calls = 0;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls++;
    return CandidateSnapshot(candidates: [], fetchedAt: DateTime.utc(2026, 10, 14),
        warnings: [], source: 'Yahoo Finance 測試回應', universeCount: 0,
        stale: false);
  }
}

void main() {
  testWidgets('the app starts updates on resume and cancels them while hidden',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scans = _LifecycleScans();
    final controller = AppController(repositoryFactory: (_) => scans,
        pollingInterval: const Duration(seconds: 60));
    final binding = tester.binding;
    addTearDown(() {
      controller.dispose();
      _resumeApp(binding);
    });
    await controller.initialize(initializeReminders: false);
    _resumeApp(binding);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.autoRefreshActive, isTrue);
    final foregroundCalls = scans.calls;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(controller.autoRefreshActive, isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 61));
    expect(scans.calls, foregroundCalls);
    _resumeApp(binding);
    await tester.pumpAndSettle();
    expect(controller.autoRefreshActive, isTrue);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(scans.calls, greaterThan(foregroundCalls));
    await tester.pumpWidget(const SizedBox());
    expect(controller.autoRefreshActive, isFalse);
    expect(tester.takeException(), isNull);
  });
}
