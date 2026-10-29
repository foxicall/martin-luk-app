import 'hybrid_protocol_test.dart' show verifiedFixture;
import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';

StockCandidate candidate({
  double entry = 100,
  double? stop = 98,
  bool large = true,
  StockMarket market = StockMarket.us,
  String status = 'confirmed',
  String? stopSource = 'day_low',
  double? dayLow,
  double? entryBarLow,
}) =>
    StockCandidate(
      id: 'test', hybrid: verifiedFixture(), triggerType: 'PDH',
      symbol: 'TEST',
      name: '測試股票',
      sector: '測試',
      market: market,
      adrPercent: 6,
      rsScore: 95,
      rsRank: 1,
      patterns: const ['PDH 突破'],
      entryPrice: entry,
      stopPrice: stop,
      stopSource: stopSource,
      dayLow: dayLow,
      entryBarLow: entryBarLow,
      isLargeLiquid: large,
      status: status,
      dataTimestamp: DateTime.utc(2026, 10, 13),
    );

void main() {
  group('strict risk and position sizing', () {
    test('uses the 0.5% risk budget and initial risk for R targets', () {
      final plan = StrategyEngine.calculate(candidate(), 100000);
      expect(plan.shares, 250);
      expect(plan.amount, 25000);
      expect(plan.positionPercent, 25);
      expect(plan.riskBudget, 500);
      expect(plan.riskAmount, 500);
      expect(plan.riskPerShare, 2);
      expect(plan.stopPercent, 2);
      expect(plan.capPercent, 35);
      expect(plan.targets, {3: 106, 5: 110, 10: 120});
      expect(plan.trimShares, 38);
      expect(plan.targetPrice(3), 106);
      expect(() => plan.targetPrice(4), throwsArgumentError);
    });

    test('caps a smaller stock at 25% even with spare risk budget', () {
      final plan = StrategyEngine.calculate(candidate(stop: 98.5, large: false), 100000);
      expect(plan.shares, 250);
      expect(plan.amount, 25000);
      expect(plan.capPercent, 25);
      expect(plan.riskAmount, 375);
      expect(plan.riskAmount, lessThanOrEqualTo(plan.riskBudget));
    });

    test('large liquid stock may exceed 25%, while respecting 35% and risk', () {
      final plan = StrategyEngine.calculate(candidate(stop: 98.5), 100000);
      expect(plan.shares, 333);
      expect(plan.positionPercent, 33.3);
      expect(plan.riskAmount, 499.5);
      expect(plan.positionPercent, lessThanOrEqualTo(35));
    });

    test('accepts exact 1.5% without binary subtraction rejecting it', () {
      final plan = StrategyEngine.calculate(candidate(entry: 101, stop: 99.485), 100000);
      expect(plan.stopPercent, 1.5);
      expect(plan.shares, 330);
      expect(plan.riskAmount, lessThanOrEqualTo(plan.riskBudget));
    });

    test('accepts exact 3% with decimal quote prices', () {
      final plan = StrategyEngine.calculate(candidate(entry: 95, stop: 92.15), 100000);
      expect(plan.stopPercent, 3);
      expect(plan.shares, 175);
    });

    test('uses an observed day-low stop up to 3.5% without fabricating a tighter stop', () {
      expect(StrategyEngine.calculate(candidate(stop: 99), 100000).stopPercent, 1);
      expect(StrategyEngine.calculate(candidate(stop: 96.5), 100000).stopPercent, 3.5);
      expect(() => StrategyEngine.calculate(candidate(stop: 96.49999), 100000), throwsArgumentError);
    });

    test('PDH beyond 3.5% requires a valid higher 5-minute low', () {
      final plan = StrategyEngine.calculate(candidate(stop: 98,
          stopSource: 'entry_bar_low', dayLow: 90, entryBarLow: 98), 100000);
      expect(plan.stopPercent, 2);
      expect(plan.shares, 250);
      expect(() => StrategyEngine.calculate(candidate(stop: 98,
          stopSource: 'entry_bar_low', dayLow: 90), 100000), throwsArgumentError);
      for (final stop in [94.99, 94.0]) {
        expect(() => StrategyEngine.calculate(candidate(stop: stop,
            stopSource: 'entry_bar_low', dayLow: 90, entryBarLow: stop), 100000), throwsArgumentError);
      }
      expect(() => StrategyEngine.calculate(candidate(stop: 98,
          stopSource: 'entry_bar_low', dayLow: 96.5, entryBarLow: 98), 100000), throwsArgumentError);
    });

    test('day-low provenance cannot be silently replaced with a fabricated stop', () {
      expect(() => StrategyEngine.calculate(candidate(stop: 98, dayLow: 97), 100000), throwsArgumentError);
    });

    test('watchlists cannot produce an executable position recommendation', () {
      expect(() => StrategyEngine.calculate(candidate(stop: null, status: 'watchlist'), 100000), throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate(status: 'watchlist'), 100000), throwsArgumentError);
    });

    test('floors shares and whole-lot shares without exceeding constraints', () {
      final value = candidate(entry: 103.5, stop: 101.43);
      final fractional = StrategyEngine.calculate(value, 50000);
      expect(fractional.shares, 120);
      expect(fractional.riskAmount, 248.4);
      final lots = StrategyEngine.calculate(value, 50000, lotSize: 100);
      expect(lots.shares, 100);
      expect(lots.amount, 10350);
      expect(lots.riskAmount, 207);
      expect(lots.trimShares, 0); // One lot cannot trim 10%–15% in whole lots.
    });

    test('rejects unfundable orders instead of recommending zero shares', () {
      expect(() => StrategyEngine.calculate(candidate(), 1), throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate(), 100000, lotSize: 1000), throwsArgumentError);
    });

    test('small holdings round the original-share 15% plan explicitly', () {
      final small = StrategyEngine.calculate(candidate(), 3200);
      expect(small.shares, 8);
      expect(small.trimShares, 1);
      final possible = StrategyEngine.calculate(candidate(), 3600);
      expect(possible.shares, 9);
      expect(possible.trimShares, 1);
    });

    test('validates the account and the trading unit', () {
      for (final equity in [0.0, -1.0, double.nan, double.infinity]) {
        expect(() => StrategyEngine.calculate(candidate(), equity), throwsArgumentError);
      }
      for (final lot in [0, -1]) {
        expect(() => StrategyEngine.calculate(candidate(), 100000, lotSize: lot), throwsArgumentError);
      }
    });

    test('requires a safely representable integer share count', () {
      expect(() => StrategyEngine.calculate(candidate(entry: 1e-10, stop: 9.8e-11), 1e20), throwsArgumentError);
    });

    test('small finite decimal values retain their scale', () {
      final plan = StrategyEngine.calculate(candidate(entry: 1e-10, stop: 9.8e-11), 1e-8);
      expect(plan.shares, 25);
      expect(plan.amount, closeTo(2.5e-9, 1e-24));
      expect(plan.riskBudget, closeTo(5e-11, 1e-26));
      expect(plan.riskAmount, closeTo(5e-11, 1e-26));
    });

    test('USD and TWD use supplied account currency without invented FX', () {
      final us = StrategyEngine.calculate(candidate(market: StockMarket.us), 50000);
      final tw = StrategyEngine.calculate(candidate(market: StockMarket.tw), 50000);
      expect(tw.shares, us.shares);
      expect(tw.riskBudget, us.riskBudget);
    });

    test('many valid decimal cases stay within both exact constraints', () {
      for (final price in [12.5, 23.75, 100.0, 1250.0]) {
        for (final percent in [1.5, 2.0, 2.5, 3.0]) {
          final stop = double.parse((price * (1 - percent / 100)).toStringAsFixed(6));
          for (final large in [false, true]) {
            final plan = StrategyEngine.calculate(candidate(entry: price, stop: stop, large: large), 50000.01);
            expect(plan.riskAmount, lessThanOrEqualTo(plan.riskBudget));
            expect(plan.positionPercent, lessThanOrEqualTo(large ? 35 : 25));
            expect(plan.shares, greaterThanOrEqualTo(0));
          }
        }
      }
    });
  });
}
