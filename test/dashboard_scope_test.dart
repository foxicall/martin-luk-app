import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/screens/settings_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

const _firstWarning = '美股目錄 20 筆未能確認普通股類別，已排除。';
const _secondWarning = '原始名單沒有完整 CFI；不代表百分之百分類認證。';

/// These injected prices exercise presentation, not the live API gate. The
/// ordinary widget suite never depends on a provider or an open market.
class _ScopeRepository implements CandidateRepository {
  _ScopeRepository({this.fullCoverage = false, this.stale = false});

  final bool fullCoverage;
  final bool stale;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    final now = DateTime.now().toUtc();
    final isUs = market == StockMarket.us;
    final symbol = isUs ? 'NVDA' : '2330.TW';
    final total = isUs ? 5118 : 1978;
    return CandidateSnapshot(
      candidates: [StockCandidate(
        id: '${market.name}:$symbol', symbol: symbol,
        name: isUs ? '輝達' : '台積電', sector: '半導體', market: market,
        adrPercent: 6, rsScore: 95, rsRank: 1,
        patterns: const ['PDH 突破'], entryPrice: 100, stopPrice: 98,
        isLargeLiquid: true, status: 'confirmed', dataTimestamp: now,
        signalTimestamp: now, triggerType: 'PDH', dayLow: 98,
      )],
      fetchedAt: now,
      warnings: const [_firstWarning, _secondWarning, _firstWarning],
      source: 'Yahoo Finance · widget fixture', universeCount: total,
      scanPoolSize: 30, evaluatedCount: 30, adrMatchCount: 1,
      universeIsComplete: false, stale: stale, scanCompletedAt: now,
      missingSymbols: stale ? const ['AAPL'] : const [],
      coverageTotalCount: fullCoverage ? total : null,
      coverageScannedCount: fullCoverage ? 30 : null,
      coverageEvaluatedCount: fullCoverage ? 30 : null,
      coverageRemainingCount: fullCoverage ? total - 30 : null,
      coverageRound: fullCoverage ? 1 : null,
      scanPageStart: fullCoverage ? 0 : null,
      scanPageSize: fullCoverage ? 30 : null,
      universeFingerprint: fullCoverage ? 'widget-fixture-universe' : null,
    );
  }
}

Future<AppController> _loadController(WidgetTester tester, {
  String provider = 'direct',
  bool fullCoverage = false,
  bool stale = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: false, dataProvider: provider,
      apiBaseUrl: provider == 'backend' ? 'https://example.invalid' : '',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final repository = _ScopeRepository(fullCoverage: fullCoverage, stale: stale);
  final controller = AppController(
    forceMockPreview: false, repositoryFactory: (_) => repository,
  );
  await tester.runAsync(() async {
    await controller.initialize(initializeReminders: false);
    await controller.setMarket(StockMarket.us);
  });
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: DashboardScreen(controller: controller),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct mode distinguishes dictionary from evaluated stocks and opens settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _loadController(tester);
    final scope = find.byKey(const ValueKey('dashboard-scan-scope'));
    expect(find.descendant(of: scope, matching: find.text('手機精選掃描')),
        findsOneWidget);
    expect(find.descendant(of: scope,
        matching: find.textContaining('本次精選 30 檔 · 已評估 30 檔')), findsOneWidget);
    expect(find.textContaining('股票字典不等於全部已評估'), findsOneWidget);
    expect(find.text('股票字典'), findsOneWidget);
    expect(find.text('5118'), findsOneWidget);
    expect(find.text('Python 全股票池輪掃（分頁）'), findsNothing);
    final button = find.byKey(const ValueKey('dashboard-api-settings'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(controller.settings.dataProvider, 'direct');
    expect(controller.settings.apiBaseUrl, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('source warnings are deduplicated and collapsed after the recommendation cards',
      (tester) async {
    await _loadController(tester);
    expect(find.textContaining(_firstWarning), findsNothing);
    expect(find.textContaining(_secondWarning), findsNothing);
    final card = find.byKey(const ValueKey('us:NVDA'));
    await tester.scrollUntilVisible(card, 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: card, matching: find.text('NVDA')), findsOneWidget);
    final disclosure = find.byKey(const ValueKey('dashboard-source-disclosures'));
    await tester.scrollUntilVisible(disclosure, 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('資料來源與限制（2 則）'), findsOneWidget);
    expect(find.textContaining(_firstWarning), findsNothing);
    await tester.tap(find.text('資料來源與限制（2 則）'));
    await tester.pumpAndSettle();
    expect(find.textContaining(_firstWarning), findsOneWidget);
    expect(find.textContaining(_secondWarning), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale and missing quote failures remain outside the collapsed disclosures',
      (tester) async {
    await _loadController(tester, stale: true);
    expect(find.text('顯示上次快取'), findsOneWidget);
    expect(find.text('部分標的缺少行情'), findsOneWidget);
    expect(find.textContaining('1 檔資料未完整取得：AAPL'), findsOneWidget);
    expect(find.textContaining(_firstWarning), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullCoverage in [false, true]) {
    testWidgets('backend scope label requires matching coverage: $fullCoverage',
        (tester) async {
      await _loadController(tester, provider: 'backend', fullCoverage: fullCoverage);
      expect(find.text('Python 全股票池輪掃（分頁）'),
          fullCoverage ? findsOneWidget : findsNothing);
      if (fullCoverage) {
        expect(find.textContaining('本輪成功評估 30/5118 檔'), findsOneWidget);
        expect(find.textContaining('不代表全部已完成'), findsOneWidget);
      } else {
        expect(find.text('Python 分批掃描'), findsOneWidget);
        expect(find.textContaining('不宣稱已掃描全部股票'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
