import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnavailableApiRepository implements CandidateRepository {
  @override
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
  }) async {
    throw const RepositoryException('測試：離線環境無法連線 API');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const settingsKey = 'martin_luk_settings_v1';
  const savedLiveSettings = AppSettings(
    useMockData: false,
    apiBaseUrl: 'https://api.example.test',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({
      settingsKey: jsonEncode(savedLiveSettings.toJson()),
    });
  });

  test('only explicit browser mock links override initial source', () {
    final mock = Uri.parse('http://localhost:8080/index.html?preview=mock');
    expect(AppConfig.isMockPreviewUri(mock, isWeb: true), isTrue);
    expect(AppConfig.isMockPreviewUri(mock, isWeb: false), isFalse);
    for (final suffix in ['', '?preview=live', '?mode=mock', '?preview=MOCK']) {
      expect(
        AppConfig.isMockPreviewUri(
          Uri.parse('http://localhost:8080/$suffix'),
          isWeb: true,
        ),
        isFalse,
      );
    }
  });

  test('mock preview starts offline despite saved API preference', () async {
    final requestedModes = <bool>[];
    final controller = AppController(
      forceMockPreview: true,
      repositoryFactory: (settings) {
        requestedModes.add(settings.useMockData);
        return settings.useMockData
            ? MockCandidateRepository()
            : _UnavailableApiRepository();
      },
    );
    addTearDown(controller.dispose);

    await controller.initialize(initializeReminders: false);
    expect(controller.settings.useMockData, isTrue);
    expect(controller.snapshot?.source, '離線示範');
    expect(controller.error, isNull);
    expect(controller.visibleCandidates, isNotEmpty);
    expect(requestedModes, [true]);

    // Initialization changes the session only, preserving the saved API choice.
    final preferences = await SharedPreferences.getInstance();
    final persisted = jsonDecode(preferences.getString(settingsKey)!)
        as Map<String, dynamic>;
    expect(persisted['use_mock_data'], isFalse);

    final twCandidate = controller.visibleCandidates.first;
    final twPlan = StrategyEngine.calculate(twCandidate, controller.equity);
    expect(twPlan.riskBudget, controller.equity * 0.005);
    expect(twPlan.riskAmount, lessThanOrEqualTo(twPlan.riskBudget));
    expect(twPlan.positionPercent, lessThanOrEqualTo(twPlan.capPercent));
    expect(
      controller.visibleCandidates.every((row) => row.adrPercent >= 3.5),
      isTrue,
    );
    await controller.setMarket(StockMarket.us);
    expect(controller.snapshot?.source, '離線示範');
    expect(controller.equity, 50000);
    expect(
      controller.visibleCandidates.every((row) => row.adrPercent >= 5),
      isTrue,
    );
    final usPlan = StrategyEngine.calculate(
      controller.visibleCandidates.first,
      controller.equity,
    );
    expect(usPlan.riskBudget, 250);
    expect(usPlan.stopPercent, inInclusiveRange(1.5, 3));
    expect(requestedModes, [true, true]);
  });

  test('explicit API switch in preview reports failure without fake fallback',
      () async {
    final requestedModes = <bool>[];
    final controller = AppController(
      forceMockPreview: true,
      repositoryFactory: (settings) {
        requestedModes.add(settings.useMockData);
        return settings.useMockData
            ? MockCandidateRepository()
            : _UnavailableApiRepository();
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.snapshot, isNotNull);

    await controller.updateSettings(
      controller.settings.copyWith(useMockData: false),
    );
    expect(controller.settings.useMockData, isFalse);
    expect(controller.snapshot, isNull);
    expect(controller.visibleCandidates, isEmpty);
    expect(controller.error, contains('無法連線 API'));
    expect(requestedModes, [true, false]);
  });

  test('normal URL respects saved live mode even when API is unavailable',
      () async {
    final requestedModes = <bool>[];
    final controller = AppController(
      forceMockPreview: false,
      repositoryFactory: (settings) {
        requestedModes.add(settings.useMockData);
        return _UnavailableApiRepository();
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    expect(controller.settings.useMockData, isFalse);
    expect(controller.snapshot, isNull);
    expect(controller.error, contains('無法連線 API'));
    expect(requestedModes, [false]);
  });
}
