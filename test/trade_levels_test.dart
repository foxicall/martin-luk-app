import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';

StockCandidate _candidate({
  double entry = 74.7,
  double? stop = 73.5,
  String status = 'confirmed',
  String? stopSource = 'day_low',
  double? dayLow,
  double? entryBarLow,
  bool large = false,
}) => StockCandidate(
  id: 'tw:6269.TW',
  symbol: '6269.TW',
  name: 'Explicit price-level fixture',
  sector: 'Test',
  market: StockMarket.tw,
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
  dataTimestamp: DateTime.utc(2026, 10, 14, 2),
);

void main() {
  test('manual hypothetical math accepts wide risk but never creates a plan', () {
    final levels = StrategyEngine.calculateHypotheticalLevels(
        entryPrice: 68, stopPrice: 61.9);
    expect(levels.riskPerShare, 6.1);
    expect(levels.stopPercent, closeTo(6.1 / 68 * 100, 1e-12));
    expect(levels.targets, {3: 86.3, 5: 98.5, 10: 129});
    expect(() => StrategyEngine.calculateTradeLevels(
        _candidate(entry: 68, stop: 61.9, dayLow: 61.9)),
        throwsArgumentError);
    expect(() => StrategyEngine.calculate(
        _candidate(entry: 68, stop: 61.9, dayLow: 61.9), 1000000),
        throwsArgumentError);
  });

  test('manual math rejects missing risk, invalid and non-finite prices', () {
    for (final entry in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => StrategyEngine.calculateHypotheticalLevels(
          entryPrice: entry, stopPrice: 98), throwsArgumentError);
    }
    for (final stop in [0.0, -1.0, 100.0, 101.0,
        double.nan, double.infinity]) {
      expect(() => StrategyEngine.calculateHypotheticalLevels(
          entryPrice: 100, stopPrice: stop), throwsArgumentError);
    }
    final levels = StrategyEngine.calculateHypotheticalLevels(
        entryPrice: .25, stopPrice: .245);
    expect(levels.riskPerShare, .005);
    expect(levels.stopPercent, 2);
    expect(levels.targets, {3: .265, 5: .275, 10: .3});
    expect(() => levels.targets[3] = 1, throwsUnsupportedError);
    expect(() => StrategyEngine.calculateHypotheticalLevels(
        entryPrice: 1e308, stopPrice: 1), throwsArgumentError);
  });

  test('observed price levels do not depend on capital or affordable shares', () {
    final candidate = _candidate(dayLow: 73.5);
    final levels = StrategyEngine.calculateTradeLevels(candidate);
    expect(levels.riskPerShare, 1.2);
    expect(levels.stopPercent, closeTo(1.2 / 74.7 * 100, 1e-12));
    expect(levels.targets, {3: 78.3, 5: 80.7, 10: 86.7});
    // Invalid/insufficient capital still prevents a new position plan. It does
    // not remove the independently verified historical price calculation.
    for (final equity in [0.0, -1.0, double.nan, double.infinity, 1.0]) {
      expect(() => StrategyEngine.calculatePrices(entryPrice: candidate.entryPrice, stopPrice: candidate.stopPrice!, equity: equity, isLargeLiquid: candidate.isLargeLiquid),
          throwsArgumentError);
    }
    expect(levels.targetPrice(3), 78.3);
    expect(candidate.dataTimestamp, DateTime.utc(2026, 10, 14, 2));
    expect(candidate.status, 'confirmed');
  });

  test('manual sizing uses exactly the same decimal price levels', () {
    for (final candidate in [
      _candidate(dayLow: 73.5),
      _candidate(entry: 100, stop: 95, dayLow: 95, large: true),
      _candidate(entry: 101, stop: 99.485, dayLow: 90,
          entryBarLow: 99.485, stopSource: 'entry_bar_low'),
      _candidate(entry: .25, stop: .245, dayLow: .245),
    ]) {
      final levels = StrategyEngine.calculateTradeLevels(candidate);
      for (final equity in [50000.0, 1000000.0]) {
        final plan = StrategyEngine.calculatePrices(entryPrice: candidate.entryPrice, stopPrice: candidate.stopPrice!, equity: equity, isLargeLiquid: candidate.isLargeLiquid);
        expect(plan.riskPerShare, levels.riskPerShare);
        expect(plan.stopPercent, levels.stopPercent);
        expect(plan.targets, levels.targets);
        expect(plan.riskAmount, lessThanOrEqualTo(plan.riskBudget));
        expect(plan.positionPercent, lessThanOrEqualTo(plan.capPercent));
      }
    }
  });

  test('price targets and target lookup remain immutable and bounded', () {
    final levels = StrategyEngine.calculateTradeLevels(_candidate());
    expect(() => levels.targets[3] = 1, throwsUnsupportedError);
    expect(() => levels.targetPrice(2), throwsArgumentError);
    expect(() => levels.targetPrice(0), throwsArgumentError);
  });

  test('watchlists and missing stops do not become reference R calculations', () {
    for (final candidate in [
      _candidate(status: 'watchlist'),
      _candidate(status: 'watchlist', stop: null),
    ]) {
      expect(() => StrategyEngine.calculateTradeLevels(candidate),
          throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate, 1000000),
          throwsArgumentError);
      expect(candidate.status, 'watchlist');
    }
  });

  test('wide day stops remain invalid instead of fabricating tight stops', () {
    for (final candidate in [
      _candidate(entry: 68, stop: 61.9, dayLow: 61.9),
      _candidate(entry: 100, stop: 94.99999, dayLow: 94.99999),
    ]) {
      expect(() => StrategyEngine.calculateTradeLevels(candidate),
          throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate, 1000000),
          throwsArgumentError);
    }
  });

  test('mismatched day low and missing stop source remain invalid', () {
    for (final candidate in [
      _candidate(dayLow: 73),
      _candidate(stopSource: null),
    ]) {
      expect(() => StrategyEngine.calculateTradeLevels(candidate),
          throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate, 1000000),
          throwsArgumentError);
    }
  });

  test('actual minute-bar stop requires wide day risk and matching evidence', () {
    for (final candidate in [
      _candidate(entry: 100, stop: 98, stopSource: 'entry_bar_low',
          dayLow: 90), // Missing actual minute low.
      _candidate(entry: 100, stop: 98, stopSource: 'entry_bar_low',
          dayLow: 90, entryBarLow: 97),
      _candidate(entry: 100, stop: 98, stopSource: 'entry_bar_low',
          entryBarLow: 98), // Missing actual day low.
      _candidate(entry: 100, stop: 98, stopSource: 'entry_bar_low',
          dayLow: 95, entryBarLow: 98), // Day risk is not above 5%.
    ]) {
      expect(() => StrategyEngine.calculateTradeLevels(candidate),
          throwsArgumentError);
      expect(() => StrategyEngine.calculate(candidate, 1000000),
          throwsArgumentError);
    }
  });

  test('decimal 1.5% and 3% minute-stop boundaries are inclusive exactly', () {
    final lower = StrategyEngine.calculateTradeLevels(_candidate(
      entry: 101, stop: 99.485, stopSource: 'entry_bar_low',
      dayLow: 90, entryBarLow: 99.485,
    ));
    expect(lower.riskPerShare, 1.515);
    expect(lower.stopPercent, 1.5);
    expect(lower.targets, {3: 105.545, 5: 108.575, 10: 116.15});
    final upper = StrategyEngine.calculateTradeLevels(_candidate(
      entry: 95, stop: 92.15, stopSource: 'entry_bar_low',
      dayLow: 85, entryBarLow: 92.15,
    ));
    expect(upper.riskPerShare, 2.85);
    expect(upper.stopPercent, 3);
    expect(upper.targets, {3: 103.55, 5: 109.25, 10: 123.5});
    for (final stop in [99.485001, 97.969999]) {
      expect(() => StrategyEngine.calculateTradeLevels(_candidate(
        entry: 101, stop: stop, stopSource: 'entry_bar_low',
        dayLow: 90, entryBarLow: stop,
      )), throwsArgumentError);
    }
  });

  test('day-low range remains positive through exact 5% without new floor', () {
    expect(StrategyEngine.calculateTradeLevels(_candidate(
        entry: 100, stop: 99.5, dayLow: 99.5)).stopPercent, .5);
    expect(StrategyEngine.calculateTradeLevels(_candidate(
        entry: 100, stop: 95, dayLow: 95)).stopPercent, 5);
  });
}
