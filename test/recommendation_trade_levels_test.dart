import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/calculator_screen.dart';
import 'package:martin_luk_app/screens/dashboard_screen.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

// Explicit presentation fixtures, not live quotes or evidence for the live
// scan gate. Taiwan values exercise the decimal example in the requested UI.
StockCandidate _candidate(StockMarket market, {bool missingStop = false}) {
  final tw = market == StockMarket.tw;
  final now = DateTime.now().toUtc();
  final stop = missingStop ? null : tw ? 73.5 : 98.0;
  return StockCandidate(
    id: tw ? 'tw:6269.TW' : 'us:NVDA',
    symbol: tw ? '6269.TW' : 'NVDA',
    name: tw ? '台郡' : '輝達', sector: 'Presentation fixture',
    market: market, adrPercent: 6, rsScore: 95, rsRank: 1,
    patterns: [tw ? 'PDH 突破' : 'ORH 突破'],
    entryPrice: tw ? 74.7 : 100, stopPrice: stop,
    isLargeLiquid: !tw, status: missingStop ? 'watchlist' : 'confirmed',
    dataTimestamp: now, signalTimestamp: missingStop ? null : now,
    triggerType: tw ? 'PDH' : 'ORH', dayLow: stop,
    quotePrice: tw ? 75.2 : 101,
  );
}

class _Repository implements CandidateRepository {
  _Repository({this.stale = false, this.missingStop = false});
  final bool stale, missingStop;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    final candidate = _candidate(market, missingStop: missingStop);
    return CandidateSnapshot(
      candidates: [candidate], fetchedAt: candidate.dataTimestamp,
      warnings: const [],
      source: 'Yahoo Finance · explicit presentation fixture',
      universeCount: 1, evaluatedCount: 1, scanPoolSize: 1,
      adrMatchCount: 1, universeIsComplete: false,
      universeAsOf: candidate.dataTimestamp,
      scanCompletedAt: candidate.dataTimestamp, stale: stale,
    );
  }
}

Future<AppController> _showDashboard(WidgetTester tester, {
  StockMarket market = StockMarket.tw,
  bool stale = false, bool missingStop = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(const AppSettings(
      useMockData: false, dataProvider: 'direct',
      autoRefreshEnabled: false,
    ).toJson()),
  });
  final repository = _Repository(stale: stale, missingStop: missingStop);
  final controller = AppController(
    forceMockPreview: false, repositoryFactory: (_) => repository,
  );
  try {
    await tester.runAsync(() async {
      await controller.initialize(initializeReminders: false);
      await controller.setMarket(market);
    });
    await tester.pumpWidget(MaterialApp(
      home: DashboardScreen(controller: controller),
    ));
    await tester.pumpAndSettle();
    final key = market == StockMarket.tw ? 'tw:6269.TW' : 'us:NVDA';
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    return controller;
  } catch (_) {
    controller.dispose();
    rethrow;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Taiwan recommendation displays decimal R prices and original-share exit stages',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _showDashboard(tester);
    try {
      final card = find.byKey(const ValueKey('tw:6269.TW'));
      Finder text(String value) => find.descendant(of: card,
          matching: find.textContaining(value));
      expect(text('NT\$74.70'), findsWidgets);
      expect(text('NT\$73.50'), findsWidgets);
      expect(text('1.61%'), findsWidgets);
      expect(text('NT\$78.30'), findsWidgets);
      expect(text('NT\$80.70'), findsWidgets);
      expect(text('3R'), findsWidgets);
      expect(text('5R'), findsWidgets);
      expect(text('原始股數'), findsWidgets);
      expect(text('15%'), findsWidgets);
      expect(text('70%'), findsWidgets);
      expect(text('9 EMA'), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('US recommendation uses USD and ORH trigger without mixing Taiwan capital or prices',
      (tester) async {
    final controller = await _showDashboard(tester, market: StockMarket.us);
    try {
      final card = find.byKey(const ValueKey('us:NVDA'));
      Finder text(String value) => find.descendant(of: card,
          matching: find.textContaining(value));
      expect(text('US\$100.00'), findsWidgets);
      expect(text('US\$98.00'), findsWidgets);
      expect(text('US\$106.00'), findsWidgets);
      expect(text('US\$110.00'), findsWidgets);
      expect(text('2.00%'), findsWidgets);
      expect(text('ORH'), findsWidgets);
      expect(text('NT\$'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('missing stop keeps exit targets unconfirmed instead of inventing a price',
      (tester) async {
    final controller = await _showDashboard(tester, missingStop: true);
    try {
      final card = find.byKey(const ValueKey('tw:6269.TW'));
      Finder text(String value) => find.descendant(of: card,
          matching: find.textContaining(value));
      expect(text('3R'), findsWidgets);
      expect(text('5R'), findsWidgets);
      expect(text('待確認'), findsWidgets);
      expect(text('NT\$78.30'), findsNothing);
      expect(text('NT\$80.70'), findsNothing);
      expect(text('建議部位 '), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('stale recommendation preserves dated observed targets but withholds sizing',
      (tester) async {
    final controller = await _showDashboard(tester, stale: true);
    try {
      final card = find.byKey(const ValueKey('tw:6269.TW'));
      Finder text(String value) => find.descendant(of: card,
          matching: find.textContaining(value));
      expect(text('待更新'), findsWidgets);
      expect(text('NT\$73.50'), findsWidgets);
      expect(text('NT\$78.30'), findsWidgets);
      expect(text('NT\$80.70'), findsWidgets);
      expect(text('上次確認價位（待更新）'), findsOneWidget);
      expect(text('突破確認時間：'), findsOneWidget);
      expect(text('3R 參考價'), findsWidgets);
      expect(text('5R 參考價'), findsWidgets);
      expect(text('建議部位 '), findsNothing);
      expect(text('已確認'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets('detail calculator presents the same 3R and 5R original-share plan at phone width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: _candidate(StockMarket.tw), initialEquity: 1000000,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('NT\$78.30'), findsWidgets);
    expect(find.textContaining('NT\$80.70'), findsWidgets);
    expect(find.textContaining('原始股數'), findsWidgets);
    expect(find.textContaining('15%'), findsWidgets);
    expect(find.textContaining('70%'), findsWidgets);
    expect(find.textContaining('9 EMA'), findsWidgets);
    expect(find.textContaining('約 12%'), findsNothing);
    expect(tester.takeException(), isNull);
    final capital = find.byKey(const ValueKey('calculator-capital-tw'));
    await tester.ensureVisible(capital);
    await tester.pumpAndSettle();
    await tester.enterText(capital, '0');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:6269.TW'))).data, 'NT\$78.30 TWD');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-5r-tw:6269.TW'))).data, 'NT\$80.70 TWD');
    expect(find.textContaining('NT\$78.30'), findsWidgets);
    expect(find.textContaining('NT\$80.70'), findsWidgets);
    expect(find.text('請輸入大於 0 的有效帳戶淨值'), findsOneWidget);
    expect(find.text('建議買進股數'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wide daily reference stop does not become an actionable R target',
      (tester) async {
    final now = DateTime.now().toUtc();
    final wideStop = StockCandidate(
      id: 'tw:1802.TW', symbol: '1802.TW', name: '台玻',
      sector: 'Explicit reference fixture', market: StockMarket.tw,
      adrPercent: 6, rsScore: 90, rsRank: 1,
      patterns: const ['PDH'], entryPrice: 68, stopPrice: 61.9,
      dayLow: 61.9, isLargeLiquid: false, status: 'confirmed',
      dataTimestamp: now, triggerType: 'PDH',
    );
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: wideStop, initialEquity: 1000000,
    )));
    await tester.pumpAndSettle();
    expect(find.text('等待進場確認'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:1802.TW'))).data, '待確認');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-5r-tw:1802.TW'))).data, '待確認');
    expect(find.textContaining('NT\$86.30'), findsNothing);
    expect(find.textContaining('NT\$98.50'), findsNothing);
    expect(find.text('建議買進股數'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached calculator preserves observed R prices and timestamp without a new position',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: _candidate(StockMarket.tw), initialEquity: 1000000,
      isCached: true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('上次確認價位（待更新）'), findsOneWidget);
    expect(find.text('上次突破確認時間'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-stop-tw:6269.TW'))).data, 'NT\$73.50 TWD');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:6269.TW'))).data, 'NT\$78.30 TWD');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-5r-tw:6269.TW'))).data, 'NT\$80.70 TWD');
    expect(find.text('建議買進股數'), findsNothing);
    expect(find.textContaining('更新確認前不提供買進股數'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached missing stop explains the missing input and does not fabricate automatic targets',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: _candidate(StockMarket.tw, missingStop: true),
      initialEquity: 1000000, isCached: true,
    )));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:6269.TW'))).data, '缺少停損');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-5r-tw:6269.TW'))).data, '缺少停損');
    expect(find.byKey(const ValueKey('calculator-levels-unavailable-tw:6269.TW')),
        findsOneWidget);
    expect(find.textContaining('尚未取得已確認突破的實際停損'), findsOneWidget);
    expect(find.text('手動試算 3R／5R'), findsOneWidget);
    expect(find.textContaining('NT\$78.30'), findsNothing);
    expect(find.textContaining('NT\$80.70'), findsNothing);
    expect(find.text('建議買進股數'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a newer unconfirmed candidate clears old automatic target values',
      (tester) async {
    Widget page(StockCandidate candidate) => MaterialApp(home: CalculatorScreen(
      candidate: candidate, initialEquity: 1000000,
    ));
    await tester.pumpWidget(page(_candidate(StockMarket.tw)));
    await tester.pumpAndSettle();
    expect(find.textContaining('NT\$78.30'), findsWidgets);
    await tester.pumpWidget(page(_candidate(StockMarket.tw, missingStop: true)));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:6269.TW'))).data, '缺少停損');
    expect(find.textContaining('NT\$78.30'), findsNothing);
    expect(find.text('建議買進股數'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manual assumptions cannot fill a missing automatic stop or enable a buy',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(
      candidate: _candidate(StockMarket.tw, missingStop: true),
      initialEquity: 1000000, isCached: true,
    )));
    await tester.pumpAndSettle();
    final toggle = find.text('手動試算 3R／5R');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final stopField = find.byKey(const ValueKey('manual-stop-tw:6269.TW'));
    await tester.ensureVisible(stopField);
    await tester.pumpAndSettle();
    await tester.enterText(stopField, '73.5');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('manual-3r-tw:6269.TW'))).data, 'NT\$78.30 TWD');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('manual-5r-tw:6269.TW'))).data, 'NT\$80.70 TWD');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-stop-tw:6269.TW'))).data, '缺少停損');
    expect(tester.widget<Text>(find.byKey(
        const ValueKey('calculator-3r-tw:6269.TW'))).data, '缺少停損');
    expect(find.text('假設價格試算 · 非買進建議'), findsOneWidget);
    expect(find.text('建議買進股數'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
