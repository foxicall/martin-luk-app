import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real metadata transport, separate from the Yahoo price/indicator health gate.
/// CI opts in explicitly; regular unit tests use deterministic parser fixtures.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runLive = bool.fromEnvironment('RUN_LIVE_UNIVERSE_TEST', defaultValue: false);
  test('real US directory refresh verifies Nasdaq and NYSE identities before APK build', () async {
    expect(AppConfig.useMockData, isFalse);
    SharedPreferences.setMockInitialValues({});
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    StockUniverseService? service;
    final elapsed = Stopwatch()..start();
    try {
      final preferences = await SharedPreferences.getInstance();
      service = StockUniverseService(preferences: preferences);
      final result = await service.load(StockMarket.us, forceRefresh: true)
          .timeout(const Duration(seconds: 15));
      expect(result.isCached, isFalse, reason: 'Bundled or cached identities cannot pass a real HTTP gate.');
      expect(result.source, contains('Nasdaq Trader'));
      expect(result.source.toLowerCase(), isNot(contains('bundled')));
      expect(result.totalCount, greaterThanOrEqualTo(2500));
      final symbols = result.stocks.map((stock) => stock.symbol).toSet();
      for (final symbol in ['NVDA', 'AAPL', 'BRK-B']) {
        expect(symbols, contains(symbol), reason: 'A real Nasdaq / NYSE membership probe is missing.');
      }
      final now = DateTime.now().toUtc();
      expect(now.difference(result.asOf).isNegative, isFalse);
      expect(now.difference(result.asOf), lessThan(const Duration(days: 8)));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 15)));
      debugPrint('[US_UNIVERSE_LIVE_PASSED] ${jsonEncode({
        'source': result.source,
        'source_file_date': result.asOf.toIso8601String(),
        'retrieved_at': result.retrievedAt?.toIso8601String(),
        'stock_count': result.totalCount,
        'is_complete': result.isComplete,
        'is_cached': result.isCached,
        'verified_symbols': ['NVDA', 'AAPL', 'BRK-B'],
        'elapsed_ms': elapsed.elapsedMilliseconds,
        'warnings': result.warnings,
      })}');
      // Conservative security-name classification or a dated mirror can be
      // partial. This gate verifies fresh real retrieval, not a 100% CFI claim.
    } finally {
      service?.close();
      HttpOverrides.global = previousOverrides;
    }
  }, skip: runLive ? false : 'Opt in with RUN_LIVE_UNIVERSE_TEST=true for real network verification.');
}
