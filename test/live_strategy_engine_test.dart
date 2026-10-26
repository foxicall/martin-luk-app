import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

void main() {
  const engine = LiveStrategyEngine();
  final now = DateTime.utc(2026, 10, 14, 14, 50);
  final stock = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
    nameZh: '輝達', nameFullZh: '', nameEn: 'NVIDIA Corporation', abbrEn: 'Nvidia');
  List<PriceBar> history({double slope = 0}) {
    final dates = <DateTime>[];
    var date = DateTime.utc(2026, 10, 13, 13, 30);
    while (dates.length < 80) {
      if (date.weekday < 6) dates.add(date);
      date = date.subtract(const Duration(days: 1));
    }
    return dates.reversed.toList().asMap().entries.map((entry) {
      final close = 100 + entry.key * slope;
      return PriceBar(timestamp: entry.value, open: close,
        high: close + (entry.key == 79 ? 1.5 : 4),
        low: close - (entry.key == 79 ? 1.5 : 4), close: close, volume: 100000);
    }).toList();
  }
  MarketChart daily({String symbol = 'NVDA', double slope = 0,
      List<PriceBar>? bars, bool stale = false}) => MarketChart(symbol: symbol,
    market: StockMarket.us, currency: 'USD', exchangeTimezoneName: 'America/New_York',
    gmtoffset: -14400, bars: bars ?? history(slope: slope), latestPrice: 102,
    quoteTimestamp: now, fetchedAt: now, interval: '1d', isStale: stale,
    regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
    regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
  PriceBar minute(int offset, {required double open, required double high,
      required double low, required double close, double volume = 2000}) =>
      PriceBar(timestamp: DateTime.utc(2026, 10, 14, 13, 30).add(Duration(minutes: offset)),
        open: open, high: high, low: low, close: close, volume: volume,
        interval: const Duration(minutes: 5));
  MarketChart intraday(List<PriceBar> bars, {DateTime? quoteTime, bool stale = false}) =>
      MarketChart(symbol: 'NVDA', market: StockMarket.us, currency: 'USD',
        exchangeTimezoneName: 'America/New_York', gmtoffset: -14400,
        bars: bars, latestPrice: bars.last.close, quoteTimestamp: quoteTime ?? now,
        fetchedAt: now, interval: '5m', isStale: stale,
        regularSessionStart: DateTime.utc(2026, 10, 14, 13, 30),
        regularSessionEnd: DateTime.utc(2026, 10, 14, 20));
  LiveEvaluation evaluate(MarketChart? intradayChart, {MarketChart? dailyChart, DateTime? at}) =>
      engine.evaluate(stock: stock, data: ChartBundle(daily: dailyChart ?? daily(),
        intraday: intradayChart), benchmark: daily(symbol: '^GSPC'), now: at ?? now);

  test('ADR is mean of daily (high-low)/low, not ATR', () {
    final bars = [for (var i = 0; i < 20; i++) PriceBar(
      timestamp: DateTime.utc(2026, 1, i + 1), open: 100, high: 110,
      low: 100, close: 105, volume: 1)];
    expect(engine.adrPercent(bars), closeTo(10, 1e-12));
    expect(() => engine.adrPercent(bars.take(19).toList()), throwsFormatException);
  });
  test('EMA uses an SMA seed and rejects incomplete history', () {
    expect(engine.ema([1, 2, 3, 4], 3), closeTo(3, 1e-12));
    expect(() => engine.ema([100], 50), throwsFormatException);
  });
  test('RS aligns 61 common session dates and yields benchmark excess', () {
    expect(engine.relativeMomentum(daily(), daily(symbol: '^GSPC')), 0);
    expect(engine.relativeMomentum(daily(slope: 1), daily(symbol: '^GSPC')), greaterThan(0));
    expect(() => engine.relativeMomentum(daily(bars: history().skip(25).toList()),
      daily(symbol: '^GSPC')), throwsFormatException);
  });
  test('a benchmark more than one known session behind cannot create a ranking', () {
    expect(() => engine.relativeMomentum(daily(), daily(symbol: '^GSPC',
      bars: history().take(78).toList())), throwsFormatException);
  });
  test('completed PDH crossing uses exact high and actual day low', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102),
    ]));
    expect(result.trigger, 101.5);
    expect(result.stop, 98);
    expect(result.stopSource, 'day_low');
    expect(result.signalTime, DateTime.utc(2026, 10, 14, 13, 40));
    final candidate = result.toCandidate(rsScore: 50, rsRank: 1);
    expect(candidate.priceSignalConfirmed, true);
    expect(candidate.isConfirmed, false); // OHLCV does not verify Hybrid order flow.
    expect(candidate.quotePrice, 102);
    expect(candidate.ema9, 100);
  });
  test('one-session stock history lag allows RS but cannot confirm a new entry', () {
    final result = evaluate(intraday([
      minute(0, open: 103, high: 104, low: 102, close: 103),
      minute(5, open: 103, high: 105, low: 102.5, close: 105),
    ]), dailyChart: daily(bars: history().take(79).toList()));
    expect(result.momentum.isFinite, isTrue);
    expect(result.stop, isNull);
    expect(result.signalTime, isNull);
    expect(result.notes.any((note) => note.contains('落後')), isTrue);
    expect(result.toCandidate(rsScore: 50, rsRank: 1).isConfirmed, isFalse);
  });
  test('provisional candle above PDH does not confirm crossing', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102),
    ], quoteTime: DateTime.utc(2026, 10, 14, 13, 37)),
      at: DateTime.utc(2026, 10, 14, 13, 37));
    expect(result.stop, null);
  });
  test('ORH excludes premarket and requires the actual opening candle', () {
    final result = evaluate(intraday([
      minute(-5, open: 108, high: 202, low: 108, close: 112),
      minute(0, open: 105, high: 106, low: 104, close: 105, volume: 40000),
      minute(5, open: 105, high: 108, low: 104.5, close: 107, volume: 40000),
    ]));
    expect(result.triggerType, 'ORH');
    expect(result.trigger, 106);
    expect(result.stop, 104);
    expect(result.patterns, contains('ORH 價格觀察（催化劑／同時段量待核實）'));
    final missingOpening = evaluate(intraday([
      minute(5, open: 105, high: 106, low: 104, close: 105, volume: 40000),
      minute(10, open: 105, high: 108, low: 104.5, close: 107, volume: 40000),
    ]));
    expect(missingOpening.triggerType, 'PDH');
    expect(missingOpening.patterns, isNot(contains('ORH 突破')));
  });
  test('gap without volume cannot manufacture an EP or ORH signal', () {
    final result = evaluate(intraday([
      minute(0, open: 105, high: 106, low: 104, close: 105, volume: 1),
      minute(5, open: 105, high: 108, low: 104.5, close: 107, volume: 1),
    ]));
    expect(result.patterns, isNot(contains('ORH 價格觀察（催化劑／同時段量待核實）')));
    expect(result.stop, null);
  });
  test('volume observed after a crossing cannot backdate an ORH confirmation', () {
    final result = evaluate(intraday([
      minute(0, open: 105, high: 106, low: 104, close: 105, volume: 1),
      minute(5, open: 105, high: 108, low: 104.5, close: 107, volume: 1),
      minute(10, open: 107, high: 110, low: 106, close: 108, volume: 1000000),
    ]));
    expect(result.patterns, contains('ORH 價格觀察（催化劑／同時段量待核實）'));
    expect(result.stop, null);
  });
  test('missing regular candles cannot establish a complete breakout day low', () {
    final result = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(10, open: 100, high: 102, low: 99, close: 102),
    ]));
    expect(result.stop, null);
    expect(result.notes.any((note) => note.contains('K 棒缺漏')), true);
  });
  test('real premarket gap is watch-only until an opening range exists', () {
    final at = DateTime.utc(2026, 10, 14, 12, 50);
    final result = evaluate(intraday([
      minute(-45, open: 104, high: 106, low: 104, close: 105),
    ], quoteTime: at), at: at);
    expect(result.stop, null);
    expect(result.patterns.any((pattern) => pattern.contains('盤前跳空')), true);
    expect(result.patterns, isNot(contains('ORH 突破')));
  });
  test('day risk over 5% uses only an actual qualifying entry bar low', () {
    final tight = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 94, close: 100),
      minute(5, open: 100, high: 103, low: 99, close: 102),
    ]));
    expect(tight.stop, 99);
    expect(tight.stopSource, 'entry_bar_low');
    final invalid = evaluate(intraday([
      minute(0, open: 100, high: 101, low: 94, close: 100),
      minute(5, open: 100, high: 103, low: 96, close: 102),
    ]));
    expect(invalid.stop, null);
    expect(invalid.toCandidate(rsScore: 50, rsRank: 1).isConfirmed, false);
  });
  test('stale quotes and after-hours crossings remain watchlist', () {
    final bars = [minute(0, open: 100, high: 101, low: 98, close: 100),
      minute(5, open: 100, high: 102, low: 99, close: 102)];
    expect(evaluate(intraday(bars, stale: true)).stop, null);
    expect(evaluate(intraday(bars, quoteTime: DateTime.utc(2026, 10, 14, 21))).stop, null);
    expect(evaluate(intraday(bars), dailyChart: daily(stale: true)).stop, null);
  });
  test('percentile ranks are bounded and a single stock is neutral', () {
    final item = evaluate(null);
    expect(engine.rank([item]).single.rsScore, 50);
    expect(engine.rank([item, item]).map((stock) => stock.rsScore), [50, 50]);
  });
}
