import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/market_scan_progress.dart';

const _warning = '美股名單仍有無法確認的普通股，未宣稱完整交易所覆蓋。';

/// Deliberately uses a membership count different from the bundled directory.
/// These observations test scope and freshness presentation, not live prices.
class _UsRepository implements CandidateRepository {
  _UsRepository({this.withCoverage = true, this.retainedPreviousDay = false,
    this.legacyCoverage = false});
  final bool withCoverage;
  final bool retainedPreviousDay;
  final bool legacyCoverage;
  final keptAt = DateTime.now().toUtc().subtract(const Duration(days: 1));
  static const total = 6207;
  int usCalls = 0;

  StockCandidate _candidate(String symbol, DateTime quoteAt) => StockCandidate(
    id: 'us:$symbol', symbol: symbol,
    name: symbol == 'NVDA' ? '輝達' : '超微', sector: '半導體',
    market: StockMarket.us, adrPercent: 6, rsScore: 95, rsRank: 1,
    patterns: const ['PDH 突破'], entryPrice: 100, stopPrice: 98,
    isLargeLiquid: true, status: 'confirmed', dataTimestamp: quoteAt,
    signalTimestamp: quoteAt, triggerType: 'PDH', dayLow: 98,
  );

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    final now = DateTime.now().toUtc();
    if (market != StockMarket.us) {
      return CandidateSnapshot(candidates: const [], fetchedAt: now,
          warnings: const [], source: 'Injected empty TW fixture',
          universeCount: 0, stale: false);
    }
    usCalls++;
    return CandidateSnapshot(
      candidates: withCoverage ? [
        _candidate('NVDA', now),
        _candidate('AMD', retainedPreviousDay
            ? keptAt : now.subtract(const Duration(minutes: 2))),
      ] : const [],
      fetchedAt: now,
      warnings: const [
        _warning,
        '本頁已嘗試代碼：AA–ACN；下一檔：ADBE。',
      ],
      source: 'Yahoo Finance · injected US scope observations',
      universeCount: total, stale: false,
      scanPoolSize: 30, evaluatedCount: withCoverage ? 28 : 30,
      adrMatchCount: withCoverage ? 2 : 0,
      universeIsComplete: false,
      scanCompletedAt: now,
      candidatesAreCumulative: withCoverage && !legacyCoverage,
      coverageTotalCount: withCoverage ? total : null,
      coverageScannedCount: withCoverage ? 90 : null,
      coverageEvaluatedCount: withCoverage ? 88 : null,
      coverageRemainingCount: withCoverage ? total - 90 : null,
      coverageRound: withCoverage ? 2 : null,
      scanPageStart: withCoverage ? 60 : null,
      scanPageSize: withCoverage ? 30 : null,
      universeFingerprint: withCoverage ? 'test-us-pinned-members' : null,
    );
  }
}

/// The counts form a plausible progress event, but its purported live snapshot
/// has an explicitly fictitious source. The controller rejects that envelope;
/// the UI must not recover its coverage through the raw presentation event.
class _InvalidPartialRepository extends _UsRepository
    implements ProgressiveCandidateRepository {
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
    pending = Completer<CandidateSnapshot>();
    final invalid = CandidateSnapshot(
      candidates: const [], fetchedAt: DateTime.now().toUtc(),
      warnings: const [], source: 'mock fabricated partial source',
      universeCount: 9999, stale: false, evaluatedCount: 30,
      scanPoolSize: 30, adrMatchCount: 0,
      candidatesAreCumulative: true,
      coverageTotalCount: 9999, coverageScannedCount: 9999,
      coverageEvaluatedCount: 9999, coverageRemainingCount: 0,
      coverageRound: 9, scanPageStart: 9969, scanPageSize: 30,
      universeFingerprint: 'invalid-source-progress-must-not-be-coverage',
    );
    onProgress?.call(MarketScanProgress(
      market: market, universeCount: 9999, poolSize: 30,
      attemptedCount: 30, completedCount: 30, evaluatedCount: 30,
      adrMatchCount: 0, confirmedCount: 0, failedCount: 0,
      finished: false, stage: 'Invalid-source partial observation',
      partialSnapshot: invalid,
    ));
    return pending!.future;
  }
}

Future<AppController> _mount(WidgetTester tester, _UsRepository repository) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(const AppSettings(
      useMockData: false, dataProvider: 'direct',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final controller = AppController(
    forceMockPreview: false, repositoryFactory: (_) => repository,
  );
  await tester.runAsync(() async {
    await controller.initialize(initializeReminders: false);
    controller.setForeground(true);
    await controller.setMarket(StockMarket.us);
  });
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
      home: DashboardScreen(controller: controller)));
  await tester.pumpAndSettle();
  return controller;
}

String _taipei(DateTime value) =>
    '${DateFormat('yyyy-MM-dd HH:mm:ss').format(value.toUtc().add(
      const Duration(hours: 8)))} · 台北 UTC+08';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('US scope uses actual pinned membership and page counters with pause and resume',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _UsRepository();
    final controller = await _mount(tester, repository);
    expect(find.text('手機美股分批輪掃'), findsOneWidget);
    expect(find.text('本輪名單'), findsOneWidget);
    expect(find.text('6207'), findsOneWidget);
    expect(find.text('5118'), findsNothing);
    expect(find.text('股票字典'), findsNothing);
    expect(find.text('本頁掃描池'), findsOneWidget);
    expect(find.text('本頁已評估'), findsOneWidget);
    expect(find.textContaining('本輪已嘗試 90/6207 檔，成功 88 檔'),
        findsOneWidget);
    expect(find.textContaining('尚未嘗試 6117 檔'), findsWidgets);
    expect(find.textContaining('本頁範圍：第 61–90 檔'), findsOneWidget);
    expect(find.textContaining('下一頁起點：第 91 檔'), findsOneWidget);
    expect(find.textContaining('本頁已嘗試代碼：AA–ACN；下一檔：ADBE。'),
        findsOneWidget);
    expect(find.textContaining('目前股票清單覆蓋不足'), findsOneWidget);
    expect(find.textContaining('各卡保留原行情時間與原掃描頁內 RS'), findsOneWidget);
    expect(find.textContaining('全市場需先部署 Python API'), findsNothing);

    final toggle = find.byKey(const ValueKey('dashboard-mobile-scan-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    final before = repository.usCalls;
    await tester.tap(toggle.hitTestable());
    await tester.pumpAndSettle();
    expect(controller.mobileScanPaused, isTrue);
    expect(repository.usCalls, before);
    expect(find.text('繼續美股輪掃'), findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle.hitTestable());
    await tester.pumpAndSettle();
    expect(controller.mobileScanPaused, isFalse);
    expect(repository.usCalls, before + 1);
    expect(find.text('暫停美股輪掃'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy US core snapshot requires initialization and never claims the market completed',
      (tester) async {
    await _mount(tester, _UsRepository(withCoverage: false));
    expect(find.textContaining('尚未建立本輪掃描進度'), findsOneWidget);
    expect(find.textContaining('目前保留先前快照（已評估 30 檔）'), findsOneWidget);
    expect(find.text('股票字典'), findsOneWidget);
    expect(find.text('6207'), findsOneWidget);
    expect(find.text('先前掃描池'), findsOneWidget);
    expect(find.text('本輪名單'), findsNothing);
    expect(find.textContaining('本輪已嘗試'), findsNothing);
    expect(find.textContaining('本輪名單已全部嘗試'), findsNothing);
    await tester.scrollUntilVisible(find.text('本輪掃描尚未初始化'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('本輪掃描尚未初始化'), findsOneWidget);
    expect(find.textContaining('初始化完整名單分批輪掃'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy US page counters without cumulative ownership never become round coverage',
      (tester) async {
    await _mount(tester, _UsRepository(legacyCoverage: true));
    expect(find.textContaining('尚未建立本輪掃描進度'), findsOneWidget);
    expect(find.text('股票字典'), findsOneWidget);
    expect(find.text('6207'), findsOneWidget);
    expect(find.text('先前掃描池'), findsOneWidget);
    expect(find.text('本輪名單'), findsNothing);
    expect(find.textContaining('本輪已嘗試'), findsNothing);
    expect(find.textContaining('第 2 輪美股分頁輪掃'), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-mobile-page-range')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-mobile-next-start')), findsNothing);
    expect(find.text('本輪累積候選'), findsNothing);
    expect(find.text('本輪累積推薦與觀察名單'), findsNothing);
    expect(find.text('推薦與觀察名單'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rejected raw US partial snapshot cannot replace verified pinned round coverage',
      (tester) async {
    final repository = _InvalidPartialRepository();
    final controller = await _mount(tester, repository);
    final previous = controller.snapshot!;
    repository.holdNext = true;
    final refresh = controller.refresh(forceRefresh: true);
    try {
      await tester.pump();
      expect(controller.loading, isTrue);
      expect(controller.marketScanProgress!.partialSnapshot, isNotNull);
      expect(controller.verifiedMarketPartialSnapshot, isNull);
      expect(find.text('本輪名單'), findsOneWidget);
      expect(find.text('6207'), findsOneWidget);
      expect(find.text('9999'), findsNothing);
      expect(find.textContaining('本輪已嘗試 90/6207 檔，成功 88 檔'), findsOneWidget);
      expect(find.textContaining('本頁範圍：第 61–90 檔'), findsOneWidget);
      expect(find.textContaining('下一頁起點：第 91 檔'), findsOneWidget);
      expect(find.textContaining('第 9 輪'), findsNothing);
      repository.pending!.complete(previous);
      await tester.pumpAndSettle();
      await refresh;
      expect(controller.loading, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      if (repository.pending != null && !repository.pending!.isCompleted) {
        repository.pending!.complete(previous);
        await tester.pumpAndSettle();
        await refresh;
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('a fresh US page cannot renew a retained prior-day confirmed quote or its sizing',
      (tester) async {
    final repository = _UsRepository(retainedPreviousDay: true);
    final controller = await _mount(tester, repository);
    expect(controller.snapshot!.stale, isFalse);
    expect(controller.snapshot!.fetchedAt.isAfter(repository.keptAt), isTrue);
    final card = find.byKey(const ValueKey('us:AMD'));
    await tester.scrollUntilVisible(card, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('快取觀察')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('已確認')), findsNothing);
    expect(find.descendant(of: card,
        matching: find.text('行情時間：${_taipei(repository.keptAt)}')), findsOneWidget);
    expect(find.descendant(of: card,
        matching: find.text('突破確認時間：${_taipei(repository.keptAt)}')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('部位待更新')), findsOneWidget);
    expect(find.descendant(of: card,
        matching: find.textContaining('建議部位 ')), findsNothing);
    final disclosures = find.byKey(const ValueKey('dashboard-source-disclosures'));
    final disclosureHeader = find.descendant(of: disclosures,
        matching: find.text('資料來源與限制（2 則）'));
    // The tile can be laid out while its tappable header remains clipped by
    // the viewport. Scroll to the actual title, lay out the new position, and
    // prove the tap will hit it before testing expansion of the source notes.
    await tester.scrollUntilVisible(disclosureHeader, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(disclosureHeader);
    await tester.pumpAndSettle();
    expect(disclosureHeader.hitTestable(), findsOneWidget);
    expect(find.textContaining(_warning), findsNothing);
    await tester.tap(disclosureHeader.hitTestable());
    await tester.pumpAndSettle();
    expect(find.textContaining(_warning), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
