import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/calculator_screen.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/screens/portfolio_screen.dart';
import 'package:martin_luk_app/screens/settings_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';

final _timestamp = DateTime.utc(2026, 10, 14, 2, 3, 4);

StockCandidate _candidate() => StockCandidate(
      id: 'tw:2330.TW', symbol: '2330.TW', name: '台積電', sector: '半導體',
      market: StockMarket.tw, adrPercent: 6, rsScore: 95, rsRank: 1,
      patterns: const ['PDH 突破'], entryPrice: 100, stopPrice: 98,
      isLargeLiquid: true, status: 'confirmed', dataTimestamp: _timestamp,
      signalTimestamp: _timestamp, triggerType: 'PDH', dayLow: 98,
      ema9: 99, ema21: 98.5, ema50: 98, quotePrice: 101,
    );

/// Injected fixtures exercise production presentation without hitting Yahoo
/// during ordinary widget tests. The separate live smoke test makes HTTP calls.
class _LiveFixtureRepository implements CandidateRepository {
  _LiveFixtureRepository({this.stale = false, this.fail = false});
  final bool stale;
  final bool fail;
  int calls = 0;
  bool lastForceRefresh = false;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    calls++;
    lastForceRefresh = forceRefresh;
    if (fail) throw const RepositoryException('測試網路中斷');
    return CandidateSnapshot(
      candidates: [_candidate()], fetchedAt: _timestamp,
      warnings: const [], source: 'Yahoo Finance · 測試回應',
      universeCount: 284, stale: stale, evaluatedCount: 1,
      universeIsComplete: false, missingSymbols: const ['2603.TW'],
      universeAsOf: _timestamp, scanCompletedAt: _timestamp,
    );
  }
}

class _QuoteFixtureRepository implements PortfolioRepository {
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) async => PortfolioQuoteSnapshot(
        quotes: {
          for (final symbol in symbols) symbol: PortfolioQuote(
            symbol: symbol, name: '台積電', market: market,
            currentPrice: 104, ema9: 101, ema21: 100, ema50: 99,
            lastClose: null, closeConfirmed: false,
            quoteTimestamp: _timestamp, closeTimestamp: null,
            source: 'Yahoo Finance · 測試回應', isLargeLiquid: true,
            isCached: true, isStale: true,
          ),
        }, errors: const {}, source: 'Yahoo Finance · 測試回應',
      );

  @override
  void close() {}
}

AppController _controller(_LiveFixtureRepository repository) => AppController(
      forceMockPreview: false,
      repositoryFactory: (_) => repository,
      portfolioRepositoryFactory: (_) => _QuoteFixtureRepository(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'martin_luk_settings_v1': jsonEncode(const AppSettings(
          useMockData: false, dataProvider: 'direct',
          autoRefreshEnabled: false,
        ).toJson()),
      }));

  testWidgets('direct production settings save without a backend URL',
      (tester) async {
    final controller = _controller(_LiveFixtureRepository());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-data-provider')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-backend-url')), findsNothing);
    expect(find.byKey(const ValueKey('settings-auto-refresh')), findsOneWidget);
    final save = find.text('儲存設定並更新');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.settings.useMockData, isFalse);
    expect(controller.settings.dataProvider, 'direct');
    expect(controller.settings.apiBaseUrl, isEmpty);
    expect(controller.settings.usEquity, 50000);
    expect(controller.settings.twEquity, 1000000);
    expect(find.text('設定已儲存，候選清單已更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached partial scan retains its timestamp and honest coverage',
      (tester) async {
    final repository = _LiveFixtureRepository(stale: true);
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('YAHOO · 連網行情'), findsOneWidget);
    expect(find.text('OFFLINE MOCK · 離線示範'), findsNothing);
    expect(find.textContaining('2026-10-14 10:03:04 · 台北 UTC+08'), findsWidgets);
    expect(find.text('已評估'), findsOneWidget);
    expect(find.text('顯示上次快取'), findsOneWidget);
    expect(find.textContaining('尚未確認完整最新上市成分'), findsOneWidget);
    expect(find.textContaining('排名僅涵蓋可用資料'), findsOneWidget);
    final before = repository.calls;
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pumpAndSettle();
    expect(repository.calls, before + 1);
    expect(repository.lastForceRefresh, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network failure offers a forced retry and no demonstration card',
      (tester) async {
    final repository = _LiveFixtureRepository(fail: true);
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.textContaining('測試網路中斷'), findsOneWidget);
    expect(controller.visibleCandidates, isEmpty);
    final before = repository.calls;
    final retry = find.text('重試');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(repository.calls, before + 1);
    expect(repository.lastForceRefresh, isTrue);
    expect(find.text('2330.TW'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale recommendation card retains quote time and withholds sizing',
      (tester) async {
    final controller = _controller(_LiveFixtureRepository(stale: true));
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(controller: controller)));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('tw:2330.TW'));
    await tester.scrollUntilVisible(card, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('快取觀察')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('已確認')), findsNothing);
    expect(find.descendant(of: card,
        matching: find.textContaining('建議部位 ')), findsNothing);
    expect(find.descendant(of: card, matching: find.text('部位待更新')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text(
        '行情時間：2026-10-14 10:03:04 · 台北 UTC+08')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached detail shows real fixture indicators but no new sizing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: _candidate(), initialEquity: 1000000,
      isCached: true, dataSource: 'Yahoo Finance · 測試回應',
    )));
    await tester.pumpAndSettle();
    expect(find.text('顯示上次快取'), findsOneWidget);
    expect(find.text('最新可用市價'), findsOneWidget);
    expect(find.text('建議買進股數'), findsNothing);
    expect(find.text('日線 9 EMA'), findsOneWidget);
    expect(find.text('日線 21 EMA'), findsOneWidget);
    expect(find.text('日線 50 EMA'), findsOneWidget);
    expect(find.text('Yahoo Finance · 測試回應'), findsOneWidget);
    expect(find.text('2026-10-14 10:03:04 · 台北 UTC+08'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('production holdings label prior demo inventory and stale quotes',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('martin_luk_portfolio_v1', jsonEncode({
      'positions': [PortfolioPosition(
        id: 'demo-prior', symbol: '2330.TW', name: '台積電',
        market: StockMarket.tw, entryPrice: 100, initialStop: 98, shares: 100,
      ).toJson()],
    }));
    final controller = _controller(_LiveFixtureRepository());
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MaterialApp(home: PortfolioScreen(controller: controller)));
    await tester.pumpAndSettle();
    // Ensure lower cards are built in the scrollable list before inspecting.
    await tester.ensureVisible(find.text('先前示範庫存，請確認成本與股數或刪除。'));
    expect(find.textContaining('顯示上次快取行情'), findsOneWidget);
    expect(find.text('調整示範市價／收盤'), findsNothing);
    expect(find.textContaining('2026-10-14 10:03:04 · 台北 UTC+08'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
