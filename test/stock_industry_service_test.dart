import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/main.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_industry_service.dart';
import 'support/mock_preferences.dart';

class RetryBundle extends CachingAssetBundle {
  int reads = 0;
  bool fail = true;
  @override
  Future<ByteData> load(String key) async {
    reads++;
    if (fail) throw StateError('missing asset');
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'NVDA': {
              'symbol': 'NVDA',
              'market': 'US',
              'sector': 'Technology',
              'industry': 'Semiconductors',
              'themes': [],
            },
          }),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real bundled snapshot covers both markets and preserves Unknown',
    () async {
      final service = StockIndustryService();
      await service.load();
      expect(service.length, 7091);
      expect(service.sector(StockMarket.tw, '2330.TW'), '半導體業');
      expect(service.label(StockMarket.us, 'nvda'), contains('Semiconductors'));
      expect(service.sector(StockMarket.us, 'TVC'), 'Unknown');
      expect(service.lookup(StockMarket.tw, 'NVDA'), isNull);
      expect(service.lookup(StockMarket.tw, '2330.TWO'), isNull);
      expect(service.sector(StockMarket.us, 'NONEXISTENT'), 'Unknown');
    },
  );

  test(
    'failed reads retry; concurrent successful reads share one index',
    () async {
      final service = StockIndustryService();
      final bundle = RetryBundle();
      await expectLater(service.load(bundle: bundle), throwsStateError);
      bundle.fail = false;
      await Future.wait([
        service.load(bundle: bundle),
        service.load(bundle: bundle),
      ]);
      expect(bundle.reads, 2);
      expect(service.sector(StockMarket.us, 'NVDA'), 'Technology');
    },
  );

  testWidgets('startup waits for classification before creating the App', (
    tester,
  ) async {
    seedMockPreferences();
    final ready = Completer<void>();
    await tester.pumpWidget(
      IndustryBootstrap(loadIndustries: () => ready.future),
    );
    expect(find.text('載入產業分類…'), findsOneWidget);
    expect(find.byType(MartinLukApp), findsNothing);
    ready.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(MartinLukApp), findsOneWidget);
    // Dispose the controller before any background refresh completes.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'startup failure is visible and retry opens App only after success',
    (tester) async {
      seedMockPreferences();
      final first = Completer<void>(), retry = Completer<void>();
      var attempts = 0;
      await tester.pumpWidget(
        IndustryBootstrap(
          loadIndustries: () => ++attempts == 1 ? first.future : retry.future,
        ),
      );
      first.completeError(StateError('asset unavailable'));
      await tester.pump();
      expect(find.text('產業分類載入失敗，請重試。'), findsOneWidget);
      expect(find.byType(MartinLukApp), findsNothing);
      await tester.tap(find.text('重新載入'));
      await tester.pump();
      expect(attempts, 2);
      expect(find.text('載入產業分類…'), findsOneWidget);
      retry.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(MartinLukApp), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
