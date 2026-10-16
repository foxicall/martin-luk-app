import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/settings_screen.dart';
import 'package:martin_luk_app/services/background_scan_service.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

/// Native service actions are replaced here, not market data or strategy
/// assertions in the real networking gate. No Android permission popup is
/// needed to exercise the settings screen's explicit action contract.
class _BackgroundService implements BackgroundScanService {
  _BackgroundService({this.supported = true});

  @override
  final bool supported;
  final _changes = StreamController<BackgroundScanState>.broadcast(sync: true);
  BackgroundScanState _state = BackgroundScanState.inactive;
  int starts = 0;
  int stops = 0;
  int pauses = 0;
  int resumes = 0;
  bool denyNextStart = false;
  bool disposed = false;

  @override
  BackgroundScanState get state => _state;
  @override
  Stream<BackgroundScanState> get states => _changes.stream;

  void notificationState(BackgroundScanState value) {
    _state = value;
    _changes.add(value);
  }

  Future<BackgroundScanState> _set(BackgroundScanState value) async {
    notificationState(value);
    return value;
  }

  @override
  Future<BackgroundScanState> start() async {
    starts++;
    if (denyNextStart) {
      denyNextStart = false;
      throw PlatformException(
        code: 'notification_permission_denied',
        message: '請允許通知權限後重試。',
      );
    }
    return _set(const BackgroundScanState(active: true, paused: false));
  }

  @override
  Future<BackgroundScanState> stop() {
    stops++;
    return _set(BackgroundScanState.inactive);
  }

  @override
  Future<BackgroundScanState> pause() {
    pauses++;
    return _set(const BackgroundScanState(active: true, paused: true));
  }

  @override
  Future<BackgroundScanState> resume() {
    resumes++;
    return _set(const BackgroundScanState(active: true, paused: false));
  }

  @override
  Future<BackgroundScanState> synchronize() async => _state;

  @override
  Future<void> update({
    required String title,
    required String text,
    String? market,
    int? attempted,
    int? total,
    int? evaluated,
    int? remaining,
  }) async {}

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    unawaited(_changes.close());
  }
}

class _Repository implements CandidateRepository {
  int calls = 0;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls++;
    return CandidateSnapshot(
      candidates: const [],
      fetchedAt: DateTime.utc(2026, 10, 16),
      warnings: const [],
      source: 'Deterministic settings transport',
      universeCount: 1979,
      stale: false,
    );
  }
}

Future<AppController> _mount(
  WidgetTester tester,
  _BackgroundService service, {
  String provider = 'direct',
  bool mock = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: mock,
      dataProvider: provider,
      apiBaseUrl: provider == 'backend' ? 'https://example.invalid' : '',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final repository = _Repository();
  final controller = AppController(
    forceMockPreview: false,
    repositoryFactory: (_) => repository,
    backgroundScanService: service,
  );
  await tester.runAsync(() =>
      controller.initialize(initializeReminders: false));
  // The real app owns visibility through its WidgetsBindingObserver. This
  // isolated settings route has no lifecycle owner, so make its visible
  // activity explicit before exercising native foreground-service commands.
  controller.setForeground(true);
  await tester.pumpWidget(MaterialApp(home: SettingsScreen(
    controller: controller,
  )));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _cleanup(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('background service starts only on an explicit action and retries permission errors',
      (tester) async {
    final service = _BackgroundService()..denyNextStart = true;
    final controller = await _mount(tester, service);
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('martin_luk_settings_v1');
      expect(service.starts, 0);
      expect(controller.settings.autoRefreshEnabled, isFalse);
      expect(find.text('背景服務未啟動'), findsOneWidget);

      await _tap(tester, 'settings-background-start');
      expect(service.starts, 1);
      expect(controller.backgroundScanActive, isFalse);
      expect(controller.backgroundScanBusy, isFalse);
      expect(find.byKey(const ValueKey('settings-background-error')),
          findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(
          const ValueKey('settings-background-start'))).onPressed, isNotNull);

      await _tap(tester, 'settings-background-start');
      expect(service.starts, 2);
      expect(controller.backgroundScanActive, isTrue);
      expect(find.text('背景持續更新中'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-background-error')),
          findsNothing);
      expect(preferences.getString('martin_luk_settings_v1'), saved);
      expect(controller.settings.autoRefreshEnabled, isFalse);
    } finally {
      await _cleanup(tester, controller);
    }
  });

  testWidgets('compact settings offers pause resume and stop without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _BackgroundService();
    final controller = await _mount(tester, service);
    try {
      await _tap(tester, 'settings-background-start');
      await _tap(tester, 'settings-background-pause-resume');
      expect(service.pauses, 1);
      expect(find.text('已暫停背景更新'), findsOneWidget);
      expect(find.text('繼續更新'), findsOneWidget);
      await _tap(tester, 'settings-background-pause-resume');
      expect(service.resumes, 1);
      expect(find.text('背景持續更新中'), findsOneWidget);
      await _tap(tester, 'settings-background-stop');
      expect(service.stops, 1);
      expect(find.text('背景服務未啟動'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _cleanup(tester, controller);
    }
  });

  testWidgets('notification actions refresh visible settings without saving',
      (tester) async {
    final service = _BackgroundService();
    final controller = await _mount(tester, service);
    try {
      await _tap(tester, 'settings-background-start');
      service.notificationState(
          const BackgroundScanState(active: true, paused: true,
              message: '已從常駐通知暫停更新。'));
      await tester.pumpAndSettle();
      expect(find.text('已暫停背景更新'), findsOneWidget);
      expect(find.text('已從常駐通知暫停更新。'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-background-message')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings-background-error')),
          findsNothing);
      service.notificationState(BackgroundScanState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('背景服務未啟動'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-background-start')),
          findsOneWidget);
      expect(service.stops, 0);
    } finally {
      await _cleanup(tester, controller);
    }
  });

  testWidgets('unsupported platforms explain availability and cannot start',
      (tester) async {
    final service = _BackgroundService(supported: false);
    final controller = await _mount(tester, service);
    try {
      expect(find.byKey(const ValueKey('settings-background-unavailable')),
          findsOneWidget);
      final start = find.byKey(const ValueKey('settings-background-start'));
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      expect(service.starts, 0);
    } finally {
      await _cleanup(tester, controller);
    }
  });

  testWidgets('an unsaved source change cannot start a mismatched service',
      (tester) async {
    final service = _BackgroundService();
    final controller = await _mount(tester, service);
    try {
      final mockSwitch = find.ancestor(
        of: find.text('離線示範資料'), matching: find.byType(SwitchListTile));
      await tester.ensureVisible(mockSwitch);
      await tester.pump();
      await tester.tap(mockSwitch);
      await tester.pumpAndSettle();
      expect(controller.settings.useMockData, isFalse);
      expect(find.byKey(const ValueKey('settings-background-requires-direct')),
          findsOneWidget);
      final start = find.byKey(const ValueKey('settings-background-start'));
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      expect(service.starts, 0);
    } finally {
      await _cleanup(tester, controller);
    }
  });

  for (final mode in ['backend', 'mock']) {
    testWidgets('$mode mode does not start a direct background service',
        (tester) async {
      final service = _BackgroundService();
      final controller = await _mount(tester, service,
          provider: mode == 'backend' ? 'backend' : 'direct',
          mock: mode == 'mock');
      try {
        expect(find.byKey(const ValueKey('settings-background-requires-direct')),
            findsOneWidget);
        final start = find.byKey(const ValueKey('settings-background-start'));
        expect(tester.widget<FilledButton>(start).onPressed, isNull);
        expect(service.starts, 0);
      } finally {
        await _cleanup(tester, controller);
      }
    });
  }
}
