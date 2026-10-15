import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/market_data.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

final _now = DateTime.utc(2026, 10, 15, 14);

List<PriceBar> _history({double slope = 1, DateTime? last}) {
  final dates = <DateTime>[];
  var date = last ?? DateTime.utc(2026, 10, 14, 13, 30);
  while (dates.length < 82) {
    if (date.weekday < 6) dates.add(date);
    date = date.subtract(const Duration(days: 1));
  }
  return dates.reversed.toList().asMap().entries.map((row) {
    final close = 100 + row.key * slope;
    return PriceBar(timestamp: row.value, open: close, high: close + 4,
        low: close - 4, close: close, volume: 100000);
  }).toList();
}

MarketChart _chart(List<PriceBar> bars, {String symbol = 'NVDA',
    StockMarket market = StockMarket.us, String interval = '1d',
    DateTime? fetchedAt, DateTime? quoteAt, DateTime? start, DateTime? end,
    bool missingSession = false}) => MarketChart(
  symbol: symbol, market: market, currency: market.currency,
  exchangeTimezoneName: market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York',
  gmtoffset: market == StockMarket.tw ? 28800 : -14400,
  bars: bars, latestPrice: bars.last.close, interval: interval,
  fetchedAt: fetchedAt ?? _now, quoteTimestamp: quoteAt ?? _now,
  regularSessionStart: missingSession ? null : start ?? DateTime.utc(2026, 10, 15, 13, 30),
  regularSessionEnd: missingSession ? null : end ?? DateTime.utc(2026, 10, 15, 20),
);

void main() {
  const engine = LiveStrategyEngine();

  for (final stockAhead in [true, false]) {
    test('RS uses identical return endpoints when ${stockAhead ? 'stock' : 'benchmark'} is one session ahead', () {
      final stockBars = _history(slope: 2);
      final indexBars = _history(slope: .5);
      final stock = _chart(stockAhead ? stockBars : stockBars.take(81).toList());
      final index = _chart(stockAhead ? indexBars.take(81).toList() : indexBars,
          symbol: '^GSPC');
      DateTime? alignedDate;
      int? stockTail, indexTail;
      final value = engine.relativeMomentum(stock, index,
          onAligned: (date, stockLag, indexLag) {
        alignedDate = date;
        stockTail = stockLag;
        indexTail = indexLag;
      });
      double excess(int sessions) =>
          (stockBars[80].close / stockBars[80 - sessions].close - 1) -
          (indexBars[80].close / indexBars[80 - sessions].close - 1);
      expect(value, closeTo((excess(20) + excess(60)) * 50, 1e-10));
      expect(alignedDate, DateTime.utc(2026, 10, 13));
      expect(stockTail, stockAhead ? 1 : 0);
      expect(indexTail, stockAhead ? 0 : 1);
    });
  }

  test('evaluation discloses common RS date and does not confirm a stale signal', () {
    final stock = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
        nameZh: '輝達', nameFullZh: '', nameEn: 'NVIDIA', abbrEn: 'Nvidia');
    final result = engine.evaluate(stock: stock,
        data: ChartBundle(daily: _chart(_history(slope: 2))),
        benchmark: _chart(_history().take(81).toList(), symbol: '^GSPC'), now: _now);
    expect(result.notes.any((note) => note.contains('RS') &&
        note.contains('2026-10-13')), isTrue);
    expect(result.stop, isNull);
    expect(result.signalTime, isNull);
  });

  test('more than one trailing known session on either side remains rejected', () {
    final full = _history();
    for (final stockAhead in [true, false]) {
      expect(() => engine.relativeMomentum(
        _chart(stockAhead ? full : full.take(80).toList()),
        _chart(stockAhead ? full.take(80).toList() : full, symbol: '^GSPC')),
        throwsFormatException);
    }
  });

  test('old common date and fewer than 61 complete common sessions are rejected', () {
    final old = _history(last: DateTime.utc(2026, 10, 1, 13, 30));
    expect(() => engine.relativeMomentum(_chart(old), _chart(old, symbol: '^GSPC')),
        throwsFormatException);
    final short = _history().skip(22).toList();
    expect(() => engine.relativeMomentum(_chart(short), _chart(short, symbol: '^GSPC')),
        throwsFormatException);
  });

  test('RS requires daily charts from the same market', () {
    expect(() => engine.relativeMomentum(_chart(_history()),
        _chart(_history(), symbol: '^TWII', market: StockMarket.tw)),
        throwsFormatException);
    expect(() => engine.relativeMomentum(_chart(_history(), interval: '5m'),
        _chart(_history(), symbol: '^GSPC')), throwsFormatException);
  });

  test('rolled session metadata finalizes today only after close plus 15 minutes', () {
    final bars = _history();
    final atClose = DateTime.utc(2026, 10, 14, 20);
    final finalized = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 15)),
        quoteAt: atClose);
    expect(finalized.completedDailyBars.last.timestamp, bars.last.timestamp);
    final provisional = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 14)),
        quoteAt: atClose);
    expect(provisional.completedDailyBars.last.timestamp, bars[bars.length - 2].timestamp);
    final staleQuote = _chart(bars, fetchedAt: atClose.add(const Duration(minutes: 15)),
        quoteAt: atClose.subtract(const Duration(hours: 1)));
    expect(staleQuote.completedDailyBars.last.timestamp, bars[bars.length - 2].timestamp);
    final missingMetadata = _chart(bars,
        fetchedAt: atClose.add(const Duration(hours: 1)), quoteAt: atClose,
        missingSession: true);
    expect(missingMetadata.completedDailyBars.last.timestamp,
        bars[bars.length - 2].timestamp);
  });
}
