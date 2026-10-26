import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/exit_advisory_engine.dart';

PortfolioPosition holding({double entry = 100, double stop = 98,
    int shares = 100, double peak = 0, double? trailing,
    int ema = 9, bool uptrend = false}) => PortfolioPosition(strategyVersion: 'legacy',
  id: 'test-nvda', symbol: 'NVDA', market: StockMarket.us,
  entryPrice: entry, shares: shares, initialStop: stop, peakR: peak,
  trailingStop: trailing, trailingEma: ema, mainUptrend: uptrend,
);

PortfolioQuote quote(double price, {double ema9 = 100, double ema21 = 98,
    double ema50 = 95, double? close = 100, bool confirmed = true,
    bool large = true}) => PortfolioQuote(
  symbol: 'NVDA', name: 'NVIDIA', market: StockMarket.us,
  currentPrice: price, ema9: ema9, ema21: ema21, ema50: ema50,
  lastClose: close, closeConfirmed: confirmed,
  quoteTimestamp: DateTime.utc(2026, 10, 13, 15),
  closeTimestamp: confirmed ? DateTime.utc(2026, 10, 12, 20) : null,
  source: 'test mock', isLargeLiquid: large,
);

void main() {
  test('fixed risk and exact decimal 3R / 5R / 10R targets', () {
    final diagnosis = ExitAdvisoryEngine.evaluate(
      holding(stop: 98.1), quote(105.7), 100000);
    expect(diagnosis.currentR, 3);
    expect(diagnosis.action, ExitAction.trim);
    expect(diagnosis.targets[3], 105.7);
    expect(diagnosis.targets[5], 109.5);
    expect(diagnosis.targets[10], 119);
    expect(diagnosis.unrealizedPnl, 570);
    expect(diagnosis.position.initialStop, 98.1);
  });

  test('breakeven latches after 2R, and hard exit precedes strength trim', () {
    final initial = ExitAdvisoryEngine.evaluate(holding(), quote(104), 100000);
    expect(initial.position.trailingStop, 100);
    final retraced = ExitAdvisoryEngine.evaluate(initial.position, quote(100), 100000);
    expect(retraced.position.peakR, 2);
    expect(retraced.position.trailingStop, 100);
    expect(retraced.action, ExitAction.exit);
    final priorStop = holding(peak: 5, trailing: 109);
    expect(ExitAdvisoryEngine.evaluate(priorStop, quote(108), 100000).action, ExitAction.exit);
  });

  test('unconfirmed intraday weakness cannot become a daily EMA exit', () {
    final intraday = ExitAdvisoryEngine.evaluate(holding(),
      quote(99, ema9: 101, close: 99, confirmed: false), 100000);
    expect(intraday.action, ExitAction.hold);
    final finalized = ExitAdvisoryEngine.evaluate(holding(),
      quote(106, ema9: 101, close: 99), 100000);
    expect(finalized.action, ExitAction.exit);
    expect(finalized.reasons.join(), contains('已確認日收盤跌破 9 EMA'));
  });

  test('21/50 EMA requires explicit uptrend and at least a 3R peak', () {
    expect(ExitAdvisoryEngine.evaluate(holding(ema: 21, uptrend: true),
      quote(103), 100000).selectedEma, 9);
    expect(ExitAdvisoryEngine.evaluate(holding(ema: 21, peak: 3),
      quote(101), 100000).selectedEma, 9);
    final allowed = ExitAdvisoryEngine.evaluate(holding(ema: 50, peak: 3, uptrend: true),
      quote(101, close: 99), 100000);
    expect(allowed.selectedEma, 50);
    expect(allowed.action, ExitAction.hold);
  });

  test('strict 35% exposure and euphoria boundaries; 25% is a separate warning', () {
    final exact35 = ExitAdvisoryEngine.evaluate(holding(shares: 350), quote(100), 100000);
    expect(exact35.action, ExitAction.hold);
    expect(exact35.overExposure, isFalse);
    expect(ExitAdvisoryEngine.evaluate(holding(shares: 350), quote(100.01), 100000).action,
      ExitAction.trim);
    final small = ExitAdvisoryEngine.evaluate(holding(shares: 260), quote(100, large: false), 100000);
    expect(small.overExposure, isTrue);
    expect(small.action, ExitAction.hold);
    expect(ExitAdvisoryEngine.evaluate(holding(entry: 120, stop: 118), quote(120), 100000).action,
      ExitAction.hold);
    expect(ExitAdvisoryEngine.evaluate(holding(entry: 120, stop: 118), quote(120.01), 100000).action,
      ExitAction.trim);
  });

  test('whole-share trim never forces a one-share sale outside 10–15%', () {
    final small = ExitAdvisoryEngine.evaluate(holding(shares: 6), quote(106), 100000);
    expect(small.action, ExitAction.trim);
    expect(small.trimShares, 0);
    expect(small.position.shares, 6);
    final enough = ExitAdvisoryEngine.evaluate(holding(shares: 7), quote(106), 100000);
    expect(enough.trimShares, 1);
  });

  test('malformed holdings and mismatched quote are rejected', () {
    expect(() => holding(stop: 100), throwsFormatException);
    expect(() => holding(shares: 0), throwsFormatException);
    expect(() => holding(peak: -1), throwsFormatException);
    expect(() => PortfolioPosition(strategyVersion: 'legacy',id: 'bad', symbol: '23300.TW', market: StockMarket.tw,
      entryPrice: 100, shares: 1, initialStop: 98), throwsFormatException);
    expect(() => PortfolioPosition(strategyVersion: 'legacy',id: 'bad', symbol: 'BRK.B', market: StockMarket.us,
      entryPrice: 100, shares: 1, initialStop: 98), throwsFormatException);
    expect(() => ExitAdvisoryEngine.evaluate(holding(), quote(100), double.nan), throwsArgumentError);
    expect(() => ExitAdvisoryEngine.evaluate(holding(), quote(100), 100000,
      euphoriaPercent: 14), throwsArgumentError);
    final json = holding().toJson()..['shares'] = 1.5;
    expect(() => PortfolioPosition.fromJson(json), throwsFormatException);
    final invalidTime = quote(100).toJson()
      ..['close_timestamp'] = '2026-10-14T20:00:00Z';
    expect(() => PortfolioQuote.fromJson(invalidTime), throwsFormatException);
  });
}
