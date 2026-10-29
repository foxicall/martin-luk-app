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
  Future<String> loadString(String key, {bool cache = true}) =>
      super.loadString(key, cache: false);
  @override
  Future<ByteData> load(String key) async {
    reads++;
    if (fail) throw StateError('missing asset');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode({
      'NVDA': {'symbol': 'NVDA', 'market': 'US', 'sector': 'Technology',
        'industry': 'Semiconductors', 'themes': []},
    }))));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real bundled snapshot covers both markets and preserves Unknown', () async {
    final service = StockIndustryService();
    await service.load();
    expect(service.length, 7091);
    expect(service.sector(StockMarket.tw, '2330.TW'), '半導體業');
    expect(service.label(StockMarket.us, 'nvda'), contains('Semiconductors'));
    expect(service.sector(StockMarket.us, 'TVC'), 'Unknown');
    expect(service.lookup(StockMarket.tw, 'NVDA'), isNull);
    expect(service.lookup(StockMarket.tw, '2330.TWO'), isNull);
    expect(service.sector(StockMarket.us, 'NONEXISTENT'), 'Unknown');
  });

  test('failed reads retry; concurrent successful reads share one index', () async {
    final service = StockIndustryService();
    final bundle = RetryBundle();
    await expectLater(service.load(bundle: bundle), throwsStateError);
    bundle.fail = false;
    await Future.wait([service.load(bundle: bundle), service.load(bundle: bundle)]);
    expect(bundle.reads, 2);
    expect(service.sector(StockMarket.us, 'NVDA'), 'Technology');
  });

  testWidgets('startup loads real metadata before creating the App', (tester) async {
    seedMockPreferences();
    await tester.pumpWidget(const IndustryBootstrap());
    expect(find.text('載入產業分類…'), findsOneWidget);
    await tester.runAsync(() => StockIndustryService.instance.load());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(MartinLukApp), findsOneWidget);
    expect(StockIndustryService.instance.length, 7091);
    // Dispose the controller before any background refresh completes.
    await tester.pumpWidget(const SizedBox());
  });
}

