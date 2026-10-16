import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/widgets/manual_trade_levels.dart';

// Explicit presentation fixtures, not observed prices or live gate evidence.
StockCandidate _candidate({
  StockMarket market = StockMarket.us,
  String id = 'manual:stock',
  double entry = 100,
}) => StockCandidate(
  id: id,
  symbol: market == StockMarket.us ? 'NVDA' : '2330.TW',
  name: market == StockMarket.us ? '輝達' : '台積電',
  sector: 'Widget fixture',
  market: market,
  adrPercent: 6,
  rsScore: 95,
  rsRank: 1,
  patterns: const ['PDH 突破'],
  entryPrice: entry,
  stopPrice: 98,
  dayLow: 98,
  isLargeLiquid: true,
  status: 'confirmed',
  dataTimestamp: DateTime.utc(2026, 10, 16),
);

Widget _host(StockCandidate candidate) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: ManualTradeLevels(candidate: candidate),
    ),
  ),
);

Future<void> _show(WidgetTester tester, StockCandidate candidate) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host(candidate));
  await tester.tap(find.text('手動試算 3R／5R'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, value);
  await tester.pump();
}

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual panel seeds trigger only and never invents an initial stop',
      (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    expect(_fieldText(tester, 'manual-entry-${candidate.id}'), '100.0');
    expect(_fieldText(tester, 'manual-stop-${candidate.id}'), isEmpty);
    expect(find.text('自行輸入假設價格；不會變更推薦、停損或買進股數。'), findsOneWidget);
    expect(find.byKey(ValueKey('manual-result-${candidate.id}')), findsNothing);
    expect(find.byKey(ValueKey('manual-3r-${candidate.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('100 and 98 show 1R 2 and targets 106 110 120 without an order',
      (tester) async {
    final candidate = _candidate();
    final before = candidate.toJson();
    await _show(tester, candidate);
    await _enter(tester, 'manual-stop-${candidate.id}', '98');
    expect(find.text('假設價格試算 · 非買進建議'), findsOneWidget);
    expect(find.text('US\$2.00 USD'), findsOneWidget);
    expect(find.text('2.00%'), findsOneWidget);
    expect(find.text('US\$106.00 USD'), findsOneWidget);
    expect(find.text('US\$110.00 USD'), findsOneWidget);
    expect(find.text('US\$120.00 USD'), findsOneWidget);
    expect(find.textContaining('建議買進股數'), findsNothing);
    expect(find.textContaining('建議部位'), findsNothing);
    expect(candidate.toJson(), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty invalid nonfinite and nonpositive stop input clear old results',
      (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    for (final input in ['', 'abc', 'NaN', 'Infinity', '0', '-1']) {
      await _enter(tester, 'manual-stop-${candidate.id}', '98');
      expect(find.byKey(ValueKey('manual-3r-${candidate.id}')), findsOneWidget);
      await _enter(tester, 'manual-stop-${candidate.id}', input);
      expect(find.byKey(ValueKey('manual-result-${candidate.id}')), findsNothing);
      expect(find.byKey(ValueKey('manual-3r-${candidate.id}')), findsNothing);
      expect(find.byKey(ValueKey('manual-error-${candidate.id}')), findsOneWidget);
      expect(find.text(input.isEmpty
          ? '請輸入假設停損價。' : '假設停損價必須為大於 0 的有限數字。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('stop equal to or above entry is rejected without stale targets',
      (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    for (final input in ['100', '101']) {
      await _enter(tester, 'manual-stop-${candidate.id}', '98');
      await _enter(tester, 'manual-stop-${candidate.id}', input);
      expect(find.text('假設停損價必須低於假設買進價。'), findsOneWidget);
      expect(find.byKey(ValueKey('manual-3r-${candidate.id}')), findsNothing);
      expect(find.byKey(ValueKey('manual-5r-${candidate.id}')), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid entry and overflowing targets clear prior output', (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    await _enter(tester, 'manual-stop-${candidate.id}', '98');
    await _enter(tester, 'manual-entry-${candidate.id}', '');
    expect(find.text('請輸入假設買進價。'), findsOneWidget);
    expect(find.byKey(ValueKey('manual-3r-${candidate.id}')), findsNothing);
    await _enter(tester, 'manual-entry-${candidate.id}', 'NaN');
    expect(find.text('假設買進價必須為大於 0 的有限數字。'), findsOneWidget);
    await _enter(tester, 'manual-entry-${candidate.id}', '1e308');
    expect(find.text('輸入數值超出可計算範圍，請調整假設價格。'), findsOneWidget);
    expect(find.byKey(ValueKey('manual-result-${candidate.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide hypothetical stops show targets with an explicit nonqualifying warning',
      (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    await _enter(tester, 'manual-stop-${candidate.id}', '90');
    expect(find.text('US\$130.00 USD'), findsOneWidget);
    expect(find.text('10.00%'), findsOneWidget);
    expect(find.text('假設停損幅度超過 5%；此試算不代表通過策略進場條件，不會產生買進建議。'),
        findsOneWidget);
    expect(find.byKey(ValueKey('manual-wide-stop-${candidate.id}')), findsOneWidget);
    expect(find.textContaining('建議買進股數'), findsNothing);
    expect(candidate.stopPrice, 98);
    expect(tester.takeException(), isNull);
  });

  testWidgets('market and identity changes reset fields and use the new currency',
      (tester) async {
    final us = _candidate();
    await _show(tester, us);
    await _enter(tester, 'manual-stop-${us.id}', '98');
    final tw = _candidate(market: StockMarket.tw, entry: 200);
    // Keep the same id deliberately: market changes alone must reset state.
    await tester.pumpWidget(_host(tw));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'manual-entry-${tw.id}'), '200.0');
    expect(_fieldText(tester, 'manual-stop-${tw.id}'), isEmpty);
    expect(find.byKey(ValueKey('manual-result-${tw.id}')), findsNothing);
    await _enter(tester, 'manual-stop-${tw.id}', '196');
    expect(find.text('NT\$212.00 TWD'), findsOneWidget);
    expect(find.text('NT\$220.00 TWD'), findsOneWidget);
    expect(find.text('US\$106.00 USD'), findsNothing);
    final next = _candidate(market: StockMarket.tw, id: 'manual:other', entry: 300);
    await tester.pumpWidget(_host(next));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'manual-entry-${next.id}'), '300.0');
    expect(_fieldText(tester, 'manual-stop-${next.id}'), isEmpty);
    expect(find.byKey(ValueKey('manual-result-${next.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-stock background refresh preserves locally edited assumptions',
      (tester) async {
    final candidate = _candidate();
    await _show(tester, candidate);
    await _enter(tester, 'manual-entry-${candidate.id}', '101');
    await _enter(tester, 'manual-stop-${candidate.id}', '99');
    await tester.pumpWidget(_host(_candidate(entry: 120)));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'manual-entry-${candidate.id}'), '101');
    expect(_fieldText(tester, 'manual-stop-${candidate.id}'), '99');
    expect(find.text('US\$107.00 USD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
