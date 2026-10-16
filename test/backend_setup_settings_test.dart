import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/settings_screen.dart';
import 'package:martin_luk_app/services/backend_connection_service.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

Map<String, Object> _contract({int limit = 0}) => {
  'service': 'martin-luk-market-api',
  'api_version': 1,
  'data_mode': 'live',
  'markets': ['tw', 'us'],
  'scan': {
    'pool_limit': limit,
    'scope': limit == 0 ? 'full_universe' : 'limited',
    'page_size': 60,
    'page_interval_seconds': 60,
    'background_jobs': true,
    'continuation': 'client_driven',
    'recommendations': 'latest_page_only',
  },
  'requires_market_data_verification': true,
};

class _Repository implements CandidateRepository {
  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async => CandidateSnapshot(
    candidates: const [], fetchedAt: DateTime.utc(2026, 10, 16),
    warnings: const [], source: 'Injected test repository', universeCount: 0,
    stale: false,
  );
}

Future<AppController> _mount(WidgetTester tester,
    BackendConnectionService service, {bool direct = false}) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: false, dataProvider: direct ? 'direct' : 'backend',
      apiBaseUrl: direct ? '' : 'https://market.provider.test',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final controller = AppController(
    forceMockPreview: false,
    repositoryFactory: (_) => _Repository(),
  );
  await tester.runAsync(() => controller.initialize(initializeReminders: false));
  await tester.pumpWidget(MaterialApp(home: SettingsScreen(
    controller: controller, connectionService: service,
  )));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tapCheck(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('settings-test-api'));
  await tester.ensureVisible(button);
  // A zero-duration scroll changes the viewport offset immediately, but the
  // button's render position is not current until the next layout frame.
  await tester.pump();
  expect(button.hitTestable(), findsOneWidget);
  expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct mode explains deployment without changing the source', (tester) async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode(_contract()), 200);
    });
    final service = BackendConnectionService(client: client);
    final controller = await _mount(tester, service, direct: true);
    try {
      expect(find.byKey(const ValueKey('settings-direct-scope')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-backend-url')), findsNothing);
      expect(controller.settings.dataProvider, 'direct');
      expect(calls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      service.close();
      client.close();
    }
  });

  testWidgets('explicit API check reports limited scope and does not save settings', (tester) async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode(_contract(limit: 30)), 200);
    });
    final service = BackendConnectionService(client: client);
    final controller = await _mount(tester, service);
    try {
      expect(find.byKey(const ValueKey('settings-backend-setup')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-api-unchecked')), findsOneWidget);
      expect(calls, 0);
      await _tapCheck(tester);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('受限股票池（每市場最多 30 檔）'), findsOneWidget);
      expect(find.textContaining('尚未驗證行情供應商或真實報價'), findsOneWidget);
      expect(controller.settings.twEquity, 1000000);
      expect(controller.settings.usEquity, 50000);
      expect(controller.settings.twAdrThreshold, 3.5);
      expect(controller.settings.usAdrThreshold, 5);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      service.close();
      client.close();
    }
  });

  testWidgets('capability timeout always stops loading and permits explicit retry', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final client = MockClient((_) {
      calls++;
      return calls == 1 ? pending.future :
          Future.value(http.Response(jsonEncode(_contract()), 200));
    });
    final service = BackendConnectionService(
      client: client, requestTimeout: const Duration(milliseconds: 40),
    );
    final controller = await _mount(tester, service);
    try {
      await _tapCheck(tester);
      expect(calls, 1);
      expect(find.text('正在測試 API…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 41));
      await tester.pump();
      expect(find.text('正在測試 API…'), findsNothing);
      expect(find.byKey(const ValueKey('settings-api-error')), findsOneWidget);
      expect(tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('settings-test-api'))).onPressed, isNotNull);
      await _tapCheck(tester);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byKey(const ValueKey('settings-api-success')), findsOneWidget);
      pending.complete(http.Response(jsonEncode(_contract(limit: 30)), 200));
      await tester.pump();
      expect(find.textContaining('API 可連線：全股票池分頁輪掃'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      service.close();
      client.close();
    }
  });

  testWidgets('editing URL rejects the old response and leaves new URL unchecked', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final client = MockClient((_) {
      calls++;
      return pending.future;
    });
    final service = BackendConnectionService(client: client);
    final controller = await _mount(tester, service);
    try {
      await _tapCheck(tester);
      // The test must invalidate an actual pending request, rather than pass
      // because the connection button was never hit.
      expect(calls, 1);
      final url = find.byKey(const ValueKey('settings-backend-url'));
      await tester.ensureVisible(url);
      await tester.pump();
      await tester.enterText(url, 'https://new.provider.test');
      pending.complete(http.Response(jsonEncode(_contract()), 200));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-api-success')), findsNothing);
      expect(find.byKey(const ValueKey('settings-api-unchecked')), findsOneWidget);
      expect(find.text('正在測試 API…'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      service.close();
      client.close();
    }
  });

  testWidgets('disposed setup screen ignores late network completion', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final client = MockClient((_) {
      calls++;
      return pending.future;
    });
    final service = BackendConnectionService(client: client);
    final controller = await _mount(tester, service);
    try {
      await _tapCheck(tester);
      // Completing an unobserved Completer with an error would test neither
      // disposal nor the service's handling of a late HTTP failure.
      expect(calls, 1);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      pending.completeError(http.ClientException('late failure'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('settings-api-error')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      service.close();
      client.close();
    }
  });
}
