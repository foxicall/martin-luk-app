import 'dart:async';
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
import 'package:martin_luk_app/services/market_scan_progress.dart';

const _firstWarning = '美股目錄 20 筆未能確認普通股類別，已排除。';
const _secondWarning = '原始名單沒有完整 CFI；不代表百分之百分類認證。';

/// These injected prices exercise presentation, not the live API gate. The
/// ordinary widget suite never depends on a provider or an open market.
class _ScopeRepository implements CandidateRepository {
  _ScopeRepository({this.fullCoverage = false, this.stale = false,
    this.mobileRolling = false});

  final bool fullCoverage;
  final bool stale;
  final bool mobileRolling;
  int calls = 0;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls++;
    final now = DateTime.now().toUtc();
    final isUs = market == StockMarket.us;
    final isMobileRolling = !isUs && mobileRolling;
    final hasCoverage = fullCoverage || isMobileRolling;
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
      ), if (isMobileRolling) StockCandidate(
        id: 'tw:6488.TWO', symbol: '6488.TWO', name: '環球晶', sector: '半導體',
        market: market, adrPercent: 6, rsScore: 90, rsRank: 2,
        patterns: const ['均線收斂'], entryPrice: 110, stopPrice: null,
        isLargeLiquid: false, status: 'watchlist',
        dataTimestamp: now.subtract(const Duration(minutes: 2)),
      )],
      fetchedAt: now,
      warnings: const [_firstWarning, _secondWarning, _firstWarning],
      source: 'Yahoo Finance · widget fixture', universeCount: total,
      scanPoolSize: isMobileRolling ? 10 : 30,
      evaluatedCount: isMobileRolling ? 8 : 30, adrMatchCount: 1,
      universeIsComplete: false, stale: stale,
      scanCompletedAt: isMobileRolling ? null : now,
      missingSymbols: stale ? const ['AAPL'] : const [],
      candidatesAreCumulative: isMobileRolling,
      coverageTotalCount: hasCoverage ? total : null,
      coverageScannedCount: hasCoverage ? (isMobileRolling ? 70 : 30) : null,
      coverageEvaluatedCount: hasCoverage ? (isMobileRolling ? 68 : 30) : null,
      coverageRemainingCount: hasCoverage ? total - (isMobileRolling ? 70 : 30) : null,
      coverageRound: hasCoverage ? 1 : null,
      scanPageStart: hasCoverage ? (isMobileRolling ? 60 : 0) : null,
      scanPageSize: hasCoverage ? (isMobileRolling ? 10 : 30) : null,
      universeFingerprint: hasCoverage ? 'widget-fixture-universe' : null,
    );
  }
}

/// An interim directory probe is deliberately smaller than the current round.
/// Its count must not replace the pinned total while the next page is pending.
class _PendingScopeRepository extends _ScopeRepository
    implements ProgressiveCandidateRepository {
  _PendingScopeRepository() : super(mobileRolling: true);
  bool holdNext = false;
  Completer<CandidateSnapshot>? pending;

  @override
  Future<CandidateSnapshot> fetchWithProgress(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
    void Function(MarketScanProgress)? onProgress,
  }) {
    if (!holdNext) {
      return super.fetch(market, adrThreshold: adrThreshold,
          forceRefresh: forceRefresh, refreshQuotesOnly: refreshQuotesOnly);
    }
    holdNext = false;
    calls++;
    pending = Completer<CandidateSnapshot>();
    onProgress?.call(MarketScanProgress(
      market: market, universeCount: 894, poolSize: 0,
      attemptedCount: 0, completedCount: 0, evaluatedCount: 0,
      adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
      finished: false, stage: 'Explicit partial-directory fixture',
    ));
    return pending!.future;
  }
}

Future<AppController> _loadController(WidgetTester tester, {
  String provider = 'direct',
  bool fullCoverage = false,
  bool stale = false,
  StockMarket market = StockMarket.us,
  _ScopeRepository? fixtureRepository,
  bool registerCleanup = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: false, dataProvider: provider,
      apiBaseUrl: provider == 'backend' ? 'https://example.invalid' : '',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final repository = fixtureRepository ??
      _ScopeRepository(fullCoverage: fullCoverage, stale: stale);
  final controller = AppController(
    forceMockPreview: false, repositoryFactory: (_) => repository,
  );
  await tester.runAsync(() async {
    await controller.initialize(initializeReminders: false);
    await controller.setMarket(market);
  });
  if (registerCleanup) addTearDown(controller.dispose);
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
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button.hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(controller.settings.dataProvider, 'direct');
    expect(controller.settings.apiBaseUrl, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TW mobile scan exposes cumulative coverage and pauses between pages without an API',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _ScopeRepository(mobileRolling: true);
    final controller = await _loadController(tester,
        market: StockMarket.tw, fixtureRepository: repository);
    expect(controller.error, isNull);
    expect(controller.loading, isFalse);
    expect(controller.settings.dataProvider, 'direct');
    expect(controller.settings.apiBaseUrl, isEmpty);
    expect(find.text('手機全台股分批輪掃'), findsOneWidget);
    expect(find.textContaining('本輪已嘗試 70/1978 檔，成功 68 檔'), findsOneWidget);
    expect(find.textContaining('尚未嘗試 1908 檔'), findsWidgets);
    expect(find.text('本頁掃描池'), findsOneWidget);
    expect(find.text('本輪名單'), findsOneWidget);
    expect(find.textContaining('本頁範圍：第 61–70 檔'), findsOneWidget);
    expect(find.textContaining('下一頁起點：第 71 檔'), findsOneWidget);
    expect(find.text('本頁已評估'), findsOneWidget);
    expect(find.text('本輪累積候選'), findsOneWidget);
    expect(find.text('本輪累積推薦與觀察名單'), findsOneWidget);
    expect(find.textContaining('各卡保留原行情時間與原掃描頁內 RS'), findsOneWidget);
    expect(find.text('市場評估僅部分完成'), findsNothing);
    expect(find.textContaining('全市場需先部署 Python API'), findsNothing);
    final pause = find.byKey(const ValueKey('dashboard-mobile-scan-toggle'));
    await tester.ensureVisible(pause);
    await tester.pumpAndSettle();
    expect(pause.hitTestable(), findsOneWidget);
    final callsBeforePause = repository.calls;
    await tester.tap(pause.hitTestable());
    await tester.pumpAndSettle();
    expect(controller.mobileScanPaused, isTrue);
    expect(repository.calls, callsBeforePause);
    expect(controller.visibleCandidates.length, 2);
    expect(find.text('繼續台股輪掃'), findsOneWidget);
    await tester.ensureVisible(pause);
    await tester.pumpAndSettle();
    await tester.tap(pause.hitTestable());
    await tester.pumpAndSettle();
    expect(controller.mobileScanPaused, isFalse);
    expect(repository.calls, callsBeforePause + 1);
    expect(controller.visibleCandidates.length, 2);
    expect(find.text('暫停台股輪掃'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TW pinned total stays stable during a smaller directory progress report',
      (tester) async {
    final repository = _PendingScopeRepository();
    final controller = await _loadController(tester,
        market: StockMarket.tw, fixtureRepository: repository,
        registerCleanup: false);
    try {
      final previous = controller.snapshot!;
      repository.holdNext = true;
      final refresh = controller.refresh(forceRefresh: true);
      await tester.pump();
      expect(controller.loading, isTrue);
      expect(repository.pending, isNotNull);
      expect(find.text('本輪名單'), findsOneWidget);
      expect(find.text('1978'), findsOneWidget);
      expect(find.text('894'), findsNothing);
      expect(find.textContaining('本輪已嘗試 70/1978 檔'), findsOneWidget);
      expect(find.textContaining('本頁範圍：第 61–70 檔'), findsOneWidget);
      expect(find.textContaining('下一頁起點：第 71 檔'), findsOneWidget);
      repository.pending!.complete(previous);
      await tester.pumpAndSettle();
      await refresh;
      expect(controller.loading, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
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
