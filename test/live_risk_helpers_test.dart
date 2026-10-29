import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/services/live_strategy_engine.dart';

void main() {
  test('fixed 0.5% risk budget and whole-share floor', () {
    final plan = calculatePositionSize(capital: 50000, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true);
    expect(plan.riskBudget, 250);
    expect(plan.riskPerShare, 2);
    expect(plan.shares, 125);
    expect(plan.amount, 12500);
    expect(plan.riskAmount, 250);
    expect(plan.stopPercent, 2);
  });
  test('small-cap 25% exposure caps shares below risk-only result', () {
    final mega = calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: true);
    final small = calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: false);
    expect(mega.capPercent, 35);
    expect(mega.shares, 333);
    expect(mega.positionPercent, lessThanOrEqualTo(35));
    expect(small.capPercent, 25);
    expect(small.shares, 250);
    expect(small.positionPercent, 25);
    expect(small.riskAmount, 375);
    expect(small.riskAmount, lessThanOrEqualTo(small.riskBudget));
  });
  test('manual scenarios accept observed stops through 5% without synthetic tightening', () {
    expect(calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 98.5, isMegaCap: true).stopPercent, 1.5);
    expect(calculatePositionSize(capital: 100000, entryPrice: 100,
      stopLossPrice: 97, isMegaCap: true).stopPercent, 3);
    for (final stop in [94.999999, 94.0]) {
      expect(() => calculatePositionSize(capital: 100000, entryPrice: 100,
        stopLossPrice: stop, isMegaCap: true), throwsArgumentError);
    }
  });
  test('decimal risk boundary does not lose or add a share due to IEEE subtraction', () {
    // Naive 0.25 - 0.245 is 0.005000000000000004, whose risk-only
    // quotient floors to 99. Exact decimal arithmetic correctly returns 100.
    final plan = calculatePositionSize(capital: 100, entryPrice: .25,
      stopLossPrice: .245, isMegaCap: false);
    expect(plan.shares, 100);
    expect(plan.amount, 25);
    expect(plan.riskAmount, .5);
    expect(plan.riskBudget, .5);
    expect(plan.riskPerShare, .005);
    expect(plan.positionPercent, 25);
  });
  test('fractional quantity is floored; target decimals remain canonical', () {
    final plan = calculatePositionSize(capital: 100000, entryPrice: 17.32,
      stopLossPrice: 17, isMegaCap: true);
    expect(plan.shares, 1562);
    expect(plan.riskAmount, 499.84);
    expect(plan.amount, 27053.84);
    expect(plan.targets, {3: 18.28, 5: 18.92, 10: 20.52});
  });
  test('zero, negative and non-finite capital or prices are rejected', () {
    for (final capital in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: capital, entryPrice: 100,
        stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    }
    for (final entry in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: 50000, entryPrice: entry,
        stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    }
    for (final stop in [0.0, -1.0, 100.0, 101.0, double.nan, double.infinity]) {
      expect(() => calculatePositionSize(capital: 50000, entryPrice: 100,
        stopLossPrice: stop, isMegaCap: true), throwsArgumentError);
    }
  });
  test('insufficient capital and unsafe integers are explicit errors', () {
    expect(() => calculatePositionSize(capital: 1, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true), throwsArgumentError);
    expect(() => calculatePositionSize(capital: 1e20, entryPrice: .1,
      stopLossPrice: .098, isMegaCap: true), throwsArgumentError);
  });
  test('exact 1R and 3R/5R/10R target prices are immutable', () {
    final targets = calculateExitTargets(.1, .098);
    expect(targets.oneR, .002);
    expect(targets.targets, {3: .106, 5: .11, 10: .12});
    expect(targets.targetPrice(3), .106);
    expect(() => targets.targetPrice(2), throwsArgumentError);
    expect(() => targets.targets[3] = 1, throwsUnsupportedError);
  });
  test('target math validates initial risk without imposing new-order bounds', () {
    expect(calculateExitTargets(100, 90).oneR, 10);
    expect(calculateExitTargets(100, 90).targets, {3: 130, 5: 150, 10: 200});
    for (final stop in [0.0, -1.0, 100.0, 101.0, double.nan, double.infinity]) {
      expect(() => calculateExitTargets(100, stop), throwsArgumentError);
    }
    for (final entry in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calculateExitTargets(entry, 98), throwsArgumentError);
    }
  });
  test('static wrappers return the same plans and risk target values', () {
    final top = calculatePositionSize(capital: 50000, entryPrice: 100,
      stopLossPrice: 98, isMegaCap: true);
    final member = LiveStrategyEngine.calculatePositionSize(capital: 50000,
      entryPrice: 100, stopLossPrice: 98, isMegaCap: true);
    expect(member.shares, top.shares);
    expect(member.riskAmount, top.riskAmount);
    expect(member.targets, top.targets);
    expect(LiveStrategyEngine.calculateExitTargets(100, 98).targets,
      calculateExitTargets(100, 98).targets);
  });
}
