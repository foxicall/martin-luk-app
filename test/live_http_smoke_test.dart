import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:martin_luk_app/app_config.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';
import 'package:martin_luk_app/services/market_data_api.dart';

/// Explicit opt-in: regular unit tests never depend on Yahoo availability.
/// Run with:
/// flutter test test/live_http_smoke_test.dart \
///   --dart-define=RUN_LIVE_HTTP_TEST=true --dart-define=USE_MOCK_DATA=false
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runLive = bool.fromEnvironment('RUN_LIVE_HTTP_TEST', defaultValue: false);
  test('Production transport obtains NVDA and 2330.TW real OHLCV and ADR', () async {
    expect(AppConfig.useMockData, isFalse,
        reason: 'This verification must not run with USE_MOCK_DATA=true.');
    // Only the platform preferences plugin is replaced. HTTP is the real
    // http.Client, not MockClient, and forceRefresh forbids a cached success.
    SharedPreferences.setMockInitialValues({});
    // Flutter's test binding normally replaces dart:io HTTP with HTTP 400.
    // Explicit opt-in restores real networking without changing TLS checks.
    final previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final preferences = await SharedPreferences.getInstance();
    final api = MarketDataApi(preferences: preferences);
    const engine = LiveStrategyEngine();
    try {
      for (final (symbol, market) in [
        ('2330.TW', StockMarket.tw), ('NVDA', StockMarket.us),
      ]) {
        final chart = await api.fetchDaily(symbol, market, forceRefresh: true);
        expect(chart.isCached, isFalse);
        expect(chart.isStale, isFalse);
        expect(chart.currency, market.currency);
        expect(chart.symbol, symbol);
        expect(chart.latestPrice, greaterThan(0));
        expect(chart.completedDailyBars.length, greaterThanOrEqualTo(61));
        final adr = engine.adrPercent(chart.completedDailyBars);
        expect(adr.isFinite, isTrue);
        expect(adr, greaterThan(0));
        final closes = chart.completedDailyBars.map((bar) => bar.close).toList();
        debugPrint(jsonEncode({
          'symbol': symbol, 'currency': chart.currency,
          'provider_price': chart.latestPrice,
          'provider_quote_time': chart.quoteTimestamp.toIso8601String(),
          'request_completed_at': chart.fetchedAt.toIso8601String(),
          'completed_daily_bars': chart.completedDailyBars.length,
          'adr_20_percent': adr,
          'ema_9': engine.ema(closes, 9),
          'ema_21': engine.ema(closes, 21),
          'ema_50': engine.ema(closes, 50),
          'source': chart.source,
          'is_cached': chart.isCached,
          'is_stale': chart.isStale,
        }));
      }
    } finally {
      api.close();
      HttpOverrides.global = previousHttpOverrides;
    }
  }, skip: runLive ? false :
      'Opt in with RUN_LIVE_HTTP_TEST=true; live endpoints may throttle.',
    timeout: const Timeout(Duration(seconds: 60)));
}
