import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/mock_preferences.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/screens/calculator_screen.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

void main() {
  setUp(seedMockPreferences);

  testWidgets('dashboard switches market and opens persisted settings', (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('OFFLINE MOCK · 離線示範'), findsOneWidget);
    expect(find.text('動能觀測站'), findsOneWidget);
    await tester.tap(find.text('美股三大交易所 · US'));
    await tester.pumpAndSettle();
    expect(controller.market, StockMarket.us);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('設定與提醒'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid equity removes preceding recommended share results', (tester) async {
    final snapshot = await MockCandidateRepository().fetch(StockMarket.tw, adrThreshold: 3.5);
    final candidate = snapshot.candidates.first;
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(candidate: candidate, initialEquity: 1000000)));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.enterText(field, '0');
    await tester.pumpAndSettle();
    expect(find.text('請輸入大於 0 的有效帳戶淨值'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
