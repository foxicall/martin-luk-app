import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/mock_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/calculator_screen.dart';
import 'package:martin_luk_app/screens/settings_screen.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';

StockCandidate _candidate(StockMarket market) => StockCandidate(
      id: '${market.name}:capital-test',
      symbol: market == StockMarket.tw ? '2330.TW' : 'NVDA',
      name: 'Capital test',
      sector: 'Test',
      market: market,
      adrPercent: 6,
      rsScore: 99,
      rsRank: 1,
      patterns: const ['PDH 突破'],
      entryPrice: 100,
      stopPrice: 98,
      dayLow: 98,
      triggerType: 'PDH',
      isLargeLiquid: true,
      status: 'confirmed',
      dataTimestamp: DateTime.utc(2026, 10, 13),
    );

Finder _settingsCapital(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

void main() {
  setUp(seedMockPreferences);

  test('native account defaults size USD and TWD risk independently', () async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final us = StrategyEngine.calculate(
        _candidate(StockMarket.us), controller.equityFor(StockMarket.us));
    final tw = StrategyEngine.calculate(
        _candidate(StockMarket.tw), controller.equityFor(StockMarket.tw));
    expect(controller.equityFor(StockMarket.us), 50000);
    expect(controller.equityFor(StockMarket.tw), 1000000);
    expect(us.riskBudget, 250);
    expect(tw.riskBudget, 5000);
    expect(us.shares, 125);
    expect(tw.shares, 2500);
  });

  testWidgets('Settings saves a USD edit without changing the TWD account',
      (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    final tw = _settingsCapital('台股帳戶總資金（Capital）');
    final us = _settingsCapital('美股帳戶總資金（Capital）');
    final twField = tester.widget<TextField>(tw);
    final usField = tester.widget<TextField>(us);
    expect(twField.controller!.text, '1000000');
    expect(usField.controller!.text, '50000');
    expect(twField.decoration!.prefixText, 'NT\$ ');
    expect(usField.decoration!.suffixText, 'USD');
    expect(twField.decoration!.helperText, contains('NT\$5,000.00 TWD'));
    expect(usField.decoration!.helperText, contains('US\$250.00 USD'));

    await tester.ensureVisible(us);
    await tester.enterText(us, '75000.25');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(us).decoration!.helperText,
        contains('US\$375.00 USD'));
    final save = find.text('儲存設定並更新');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.equityFor(StockMarket.us), 75000.25);
    expect(controller.equityFor(StockMarket.tw), 1000000);

    // A second controller reads persistence rather than the first screen's
    // editable fields, so this checks both account isolation and saved cents.
    final restored = AppController();
    addTearDown(restored.dispose);
    await restored.initialize(initializeReminders: false);
    expect(restored.equityFor(StockMarket.us), 75000.25);
    expect(restored.equityFor(StockMarket.tw), 1000000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reused calculator resets capital and risk when market changes',
      (tester) async {
    const screenKey = ValueKey('same-calculator-state');
    final edits = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: CalculatorScreen(
        key: screenKey,
        candidate: _candidate(StockMarket.us),
        initialEquity: 50000,
        onEquityChanged: edits.add,
      ),
    ));
    await tester.pumpAndSettle();
    var field = find.byKey(const ValueKey('calculator-capital-us'));
    expect(tester.widget<TextField>(field).controller!.text, '50000');
    expect(tester.widget<TextField>(field).decoration!.helperText,
        contains('US\$250.00 USD'));
    await tester.enterText(field, '0');
    await tester.pumpAndSettle();
    expect(find.text('請輸入大於 0 的有效帳戶淨值'), findsWidgets);

    await tester.pumpWidget(MaterialApp(
      home: CalculatorScreen(
        key: screenKey,
        candidate: _candidate(StockMarket.tw),
        initialEquity: 1000000.75,
        onEquityChanged: edits.add,
      ),
    ));
    await tester.pumpAndSettle();
    field = find.byKey(const ValueKey('calculator-capital-tw'));
    final twField = tester.widget<TextField>(field);
    expect(twField.controller!.text, '1000000.75');
    expect(twField.decoration!.labelText, '台股帳戶總資金（Capital）');
    expect(twField.decoration!.prefixText, 'NT\$ ');
    expect(twField.decoration!.suffixText, 'TWD');
    expect(twField.decoration!.helperText, contains('NT\$5,000.00 TWD'));
    expect(find.text('請輸入大於 0 的有效帳戶淨值'), findsNothing);
    expect(find.text('US\$250.00 USD'), findsNothing);
    expect(find.text('2,500 股'), findsOneWidget);
    expect(edits, isEmpty); // Seeding the next market is not a user edit.
    expect(tester.takeException(), isNull);
  });

  testWidgets('external saved capital updates preserve decimal units',
      (tester) async {
    const screenKey = ValueKey('same-us-calculator-state');
    final stock = _candidate(StockMarket.us);
    Future<void> show(double equity) async {
      await tester.pumpWidget(MaterialApp(
        home: CalculatorScreen(
          key: screenKey,
          candidate: stock,
          initialEquity: equity,
        ),
      ));
      await tester.pumpAndSettle();
    }

    await show(50000.75);
    final field = find.byKey(const ValueKey('calculator-capital-us'));
    expect(tester.widget<TextField>(field).controller!.text, '50000.75');
    await show(90000.75);
    expect(tester.widget<TextField>(field).controller!.text, '90000.75');
    expect(tester.widget<TextField>(field).decoration!.helperText,
        contains('US\$450.00 USD'));
    expect(find.text('225 股'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard opens calculators with the selected native account',
      (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.pumpAndSettle();
    final taiwanStock = find.text('2330.TW');
    // The overview/search header can place lazily built cards below the first
    // viewport. Scroll until they exist before asking Flutter to reveal them.
    await tester.scrollUntilVisible(taiwanStock, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(taiwanStock);
    await tester.pumpAndSettle();
    final twField = find.byKey(const ValueKey('calculator-capital-tw'));
    expect(tester.widget<TextField>(twField).controller!.text, '1000000');
    await tester.enterText(twField, '1200000.25');
    await tester.pumpAndSettle();
    expect(controller.equityFor(StockMarket.tw), 1200000.25);
    expect(controller.equityFor(StockMarket.us), 50000);

    await tester.pageBack();
    await tester.pumpAndSettle();
    final usTab = find.text('美股三大交易所 · US');
    await tester.ensureVisible(usTab);
    await tester.tap(usTab);
    await tester.pumpAndSettle();
    final usStock = find.text('NVDA');
    await tester.scrollUntilVisible(usStock, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(usStock);
    await tester.pumpAndSettle();
    final usField = find.byKey(const ValueKey('calculator-capital-us'));
    expect(tester.widget<TextField>(usField).controller!.text, '50000');
    expect(tester.widget<TextField>(usField).decoration!.helperText,
        contains('US\$250.00 USD'));
    await tester.enterText(usField, '60000.5');
    await tester.pumpAndSettle();
    expect(controller.equityFor(StockMarket.us), 60000.5);
    expect(controller.equityFor(StockMarket.tw), 1200000.25);
    expect(tester.takeException(), isNull);
  });
}
