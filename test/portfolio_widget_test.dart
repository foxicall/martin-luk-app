import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('390px portfolio shows targets and supports live scenario editing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    await tester.pumpWidget(MartinLukApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的持股'));
    await tester.pumpAndSettle();
    expect(find.text('我的持股庫存'), findsOneWidget);
    expect(find.text('2330.TW'), findsOneWidget);
    expect(find.text('3R · 1060.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final button = find.text('調整示範市價／收盤').first;
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final priceField = find.widgetWithText(TextFormField, '目前市價');
    await tester.enterText(priceField, '1000');
    await tester.tap(find.text('套用並診斷'));
    await tester.pumpAndSettle();
    final held = controller.portfolioPositions.firstWhere((p) => p.symbol == '2330.TW');
    expect(controller.diagnosisFor(held)!.label, contains('建議全數平倉'));
    expect(held.peakR, 3);
    expect(held.trailingStop, 1000);
    expect(tester.takeException(), isNull);
  });
}
