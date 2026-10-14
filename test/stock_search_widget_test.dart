import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/stock_search_service.dart';
import 'package:martin_luk_app/widgets/stock_search_field.dart';

import 'stock_search_service_test.dart' show searchFixtures;

void main() {
  testWidgets('200ms debounce replaces stale text and choosing fills canonical symbol', (tester) async {
    StockItem? selected;
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StockSearchField(
      controller: text, service: StockSearchService(searchFixtures()),
      onSelected: (stock) => selected = stock,
    ))));
    await tester.pump();
    final field = find.byType(TextFormField);
    await tester.enterText(field, '台積電');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('stock-search-suggestions')), findsNothing);
    await tester.enterText(field, '輝達');
    await tester.pump(const Duration(milliseconds: 199));
    expect(find.byKey(const ValueKey('stock-search-suggestions')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('stock-suggestion-us:NVDA')), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-suggestion-tw:2330.TW')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('stock-suggestion-us:NVDA')));
    await tester.pump();
    expect(selected?.symbol, 'NVDA');
    expect(selected?.marketTag, 'US');
    expect(text.text, 'NVDA');
    expect(find.byKey(const ValueKey('stock-search-suggestions')), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing cancels pending search and disposed fields cancel timers', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StockSearchField(
      service: StockSearchService(searchFixtures()), onSelected: (_) {},
    ))));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), '2330');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('清除搜尋'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('stock-search-suggestions')), findsNothing);
    await tester.enterText(find.byType(TextFormField), 'TSMC');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown stock leaves typed manual symbol available to holding form', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StockSearchField(
      controller: text, service: StockSearchService(searchFixtures()), onSelected: (_) {},
    ))));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), 'UNKNOWNX');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('未找到相符股票；可手動輸入標準代碼。'), findsOneWidget);
    expect(text.text, 'UNKNOWNX');
    expect(tester.takeException(), isNull);
  });

  testWidgets('search action selects the active autocomplete option', (tester) async {
    StockItem? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StockSearchField(
      service: StockSearchService(searchFixtures()), onSelected: (stock) => selected = stock,
    ))));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), '2330');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 100));
    expect(selected?.symbol, '2330.TW');
    expect(selected?.marketTag, 'TW');
    expect(find.byKey(const ValueKey('stock-search-suggestions')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
