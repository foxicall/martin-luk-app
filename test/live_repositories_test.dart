import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_candidate_repository.dart';
import 'package:martin_luk_app/services/live_portfolio_repository.dart';
import 'package:martin_luk_app/services/market_data_api.dart';
import 'package:martin_luk_app/services/stock_universe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 14, 14, 50);
StockItem _stock(String symbol) => StockItem(market: StockMarket.us,
  symbol: symbol, code: symbol, nameZh: '', nameFullZh: '', nameEn: symbol, abbrEn: '');

MarketChart _daily(String symbol) => MarketChart(symbol: symbol,
  market: StockMarket.us, currency: 'USD', exchangeTimezoneName: 'America/New_York',
  gmtoffset: -14400, bars: List.generate(80, (index) => PriceBar(
    timestamp: DateTime.utc(2026, 10, 13, 13, 30).subtract(Duration(days: 79 - index)),
    open: 100, high: 104, low: 96, close: 100, volume: 10000)),
  latestPrice: 100, quoteTimestamp: _now, fetchedAt: _now, interval: '1d',
  regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
  regularSessionEnd: DateTime.utc(2026, 10, 14, 20));

class _Api extends MarketDataApi {
  _Api(SharedPreferences preferences) : super(preferences: preferences, now: () => _now);
  bool fail = false;
  int dailyCalls = 0, intradayCalls = 0, benchmarkCalls = 0;
  @override
  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) async {
    dailyCalls++;
    if (fail) throw StateError('Network unavailable');
    return _daily(symbol);
  }
  @override
  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) async {
    benchmarkCalls++;
    if (fail) throw StateError('Network unavailable');
    return _daily('^GSPC');
  }
  @override
  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) async {
    intradayCalls++;
    if (fail) throw StateError('Network unavailable');
    return MarketChart(symbol: symbol, market: market, currency: 'USD',
      exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
      bars: [PriceBar(timestamp: DateTime.utc(2026, 10, 14, 13, 30),
        open: 100, high: 101, low: 99, close: 100, volume: 1000,
        interval: const Duration(minutes: 5))], latestPrice: 100,
      quoteTimestamp: _now, fetchedAt: _now, interval: '5m',
      regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
      regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
  }
}

class _Universe extends StockUniverseService {
  _Universe(this.rows, SharedPreferences preferences) : super(preferences: preferences);
  final List<StockItem> rows;
  int calls = 0;
  @override
  Future<UniverseSnapshot> load(StockMarket market, {bool forceRefresh = false}) async {
    calls++;
    return UniverseSnapshot(stocks: rows, asOf: _now,
      source: 'Unit-test member fixture', isComplete: false,
      warnings: const ['Partial fixture, not a live complete universe']);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late _Api api;
  late _Universe universe;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    api = _Api(preferences);
    universe = _Universe([_stock('NVDA'), _stock('TSLA')], preferences);
  });

  test('scan reports evaluated coverage and ranks before ADR filtering', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(snapshot.evaluatedCount, 2);
    expect(snapshot.universeCount, 2);
    expect(snapshot.universeIsComplete, false);
    expect(snapshot.candidates.map((stock) => stock.rsScore), [50, 50]);
    expect(snapshot.candidates.every((stock) => !stock.isConfirmed), true);
    expect(api.dailyCalls, 2);
    expect(api.intradayCalls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('foreground refresh reuses member scan and force refresh rescans', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await repository.fetch(StockMarket.us, adrThreshold: 5);
    await repository.fetch(StockMarket.us, adrThreshold: 5, refreshQuotesOnly: true);
    expect(universe.calls, 1);
    await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(universe.calls, 2);
    repository.close(); api.close(); universe.close();
  });
  test('HTTP failure retains explicitly stale true-data snapshot', () async {
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, adrThreshold: 5);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, adrThreshold: 5, forceRefresh: true);
    expect(cached.stale, true);
    expect(cached.fetchedAt, first.fetchedAt);
    expect(cached.source, contains('真實快取'));
    expect(cached.candidates.map((stock) => stock.symbol), ['NVDA', 'TSLA']);
    repository.close(); api.close(); universe.close();
  });
  test('no cache and no real data reports error instead of demo fallback', () async {
    api.fail = true;
    final repository = DirectLiveCandidateRepository(api: api, universe: universe,
      preferences: preferences, now: () => _now);
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5), throwsA(isA<Exception>()));
    repository.close(); api.close(); universe.close();
  });
  test('portfolio completed EMA quote and stale fallback preserve timestamp', () async {
    final repository = DirectLivePortfolioRepository(api: api,
      preferences: preferences, now: () => _now);
    final first = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    final quote = first.quotes['NVDA']!;
    expect(quote.currentPrice, 100);
    expect(quote.ema9, 100);
    expect(quote.ema21, 100);
    expect(quote.ema50, 100);
    expect(quote.closeConfirmed, true);
    expect(quote.isStale, false);
    api.fail = true;
    final cached = await repository.fetch(StockMarket.us, ['NVDA'], forceRefresh: true);
    expect(cached.quotes['NVDA']!.isStale, true);
    expect(cached.quotes['NVDA']!.isCached, true);
    expect(cached.quotes['NVDA']!.quoteTimestamp, quote.quoteTimestamp);
    expect(cached.errors['NVDA'], contains('保留上次真實快取'));
    repository.close(); api.close();
  });
}
