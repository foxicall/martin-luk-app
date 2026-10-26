import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/mock_preferences.dart';

import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/screens/calculator_screen.dart';
import 'package:martin_luk_app/services/stock_search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async { await StockSearchService.load(); });
  setUp(seedMockPreferences);

  testWidgets('Chinese cross-market search opens the matching native-currency calculator', (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.runAsync(() async {
      await StockSearchService.load();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    final search = find.descendant(
        of: find.byKey(const ValueKey('dashboard-stock-search')),
        matching: find.byType(TextFormField));
    await tester.ensureVisible(search);
    await tester.pumpAndSettle();
    await tester.enterText(search, '輝達');
    await tester.pump(); // Apply focus before advancing the debounce clock.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final result = find.byKey(const ValueKey('stock-suggestion-us:NVDA'));
    await tester.ensureVisible(result);
    await tester.pumpAndSettle();
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(controller.market, StockMarket.us);
    expect(find.byType(CalculatorScreen), findsOneWidget);
    final capital = find.byKey(const ValueKey('calculator-capital-us'));
    expect(tester.widget<TextField>(capital).controller!.text, '50000');
    expect(tester.widget<TextField>(capital).decoration!.suffixText, 'USD');
    expect(controller.equityFor(StockMarket.tw), 1000000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('metadata-only selection opens a blank holding form without inventing a signal', (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.runAsync(() async {
      await StockSearchService.load();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    final search = find.descendant(
        of: find.byKey(const ValueKey('dashboard-stock-search')),
        matching: find.byType(TextFormField));
    await tester.ensureVisible(search);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'BRK.B');
    await tester.pump(); // Apply focus before advancing the debounce clock.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final result = find.byKey(const ValueKey('stock-suggestion-us:BRK-B'));
    await tester.ensureVisible(result);
    await tester.pumpAndSettle();
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(find.byType(CalculatorScreen), findsNothing);
    expect(controller.market, StockMarket.us);
    final add = find.text('將標準代碼帶入新增持股');
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    final symbol = find.descendant(
      of: find.byKey(const ValueKey('holding-stock-search')),
      matching: find.byType(TextFormField));
    expect(tester.widget<TextFormField>(symbol).controller!.text, 'BRK-B');
    final cost = find.widgetWithText(TextFormField, '買進成本價');
    final stop = find.widgetWithText(TextFormField, '原始初始停損價');
    expect(tester.widget<TextFormField>(cost).controller!.text, isEmpty);
    expect(tester.widget<TextFormField>(stop).controller!.text, isEmpty);
    final market = find.byType(DropdownButtonFormField<StockMarket>);
    expect(tester.state<FormFieldState<StockMarket>>(market).value, StockMarket.us);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.portfolioPositions.any((row) => row.symbol == 'BRK-B'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding autocomplete fills a US symbol and market from a Chinese name', (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.runAsync(() async {
      await StockSearchService.load();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的持股'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增持股'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async { await Future<void>.delayed(Duration.zero); });
    await tester.pumpAndSettle();
    final symbol = find.descendant(
      of: find.byKey(const ValueKey('holding-stock-search')),
      matching: find.byType(TextFormField));
    await tester.enterText(symbol, '特斯拉');
    await tester.pump(); // Apply focus before advancing the debounce clock.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final result = find.byKey(const ValueKey('stock-suggestion-us:TSLA'));
    await tester.ensureVisible(result);
    await tester.pumpAndSettle();
    await tester.tap(result);
    await tester.pump();
    expect(tester.widget<TextFormField>(symbol).controller!.text, 'TSLA');
    final market = find.byType(DropdownButtonFormField<StockMarket>);
    expect(tester.state<FormFieldState<StockMarket>>(market).value, StockMarket.us);
    final name = find.widgetWithText(TextFormField, '名稱（選填）');
    expect(tester.widget<TextFormField>(name).controller!.text, '特斯拉');
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, '買進成本價')).controller!.text, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
