import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/hybrid_protocol.dart';
import 'package:martin_luk_app/models/portfolio_position.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/exit_advisory_engine.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';

HybridAssessment verifiedFixture() => HybridAssessment(
  checks: {
    for (final key in HybridAssessment.requiredChecks) key: CheckState.passed,
  },
  notes: const ['Synthetic test fixture, never market evidence'],
);

PortfolioQuote quote(double price) => PortfolioQuote(
  symbol: 'TEST',
  name: 'Test',
  market: StockMarket.us,
  currentPrice: price,
  ema9: 100,
  ema21: 98,
  ema50: 95,
  lastClose: 100,
  closeConfirmed: false,
  quoteTimestamp: DateTime.utc(2026, 10, 23),
  closeTimestamp: null,
  source: 'test fixture',
  isLargeLiquid: true,
);

void main() {
  test('source threshold boundaries and distinct scan/ORH gaps', () {
    expect(HybridProtocol.adrPass(5, isUs: true), isTrue);
    expect(HybridProtocol.adrPass(4.9999, isUs: true), isFalse);
    expect(HybridProtocol.adrPass(3.5, isUs: false), isFalse);
    expect(HybridProtocol.adrPass(3.50001, isUs: false), isTrue);
    expect(HybridProtocol.dollarVolumePass(50000000), isTrue);
    expect(HybridProtocol.dollarVolumePass(49999999.99), isFalse);
    expect(HybridProtocol.marketCapPass(100000000), isTrue);
    expect(HybridProtocol.marketCapPass(99999999), isFalse);
    expect(HybridProtocol.gapScannerPass(4), isTrue);
    expect(HybridProtocol.orhGapPass(4), isFalse);
    expect(HybridProtocol.orhGapPass(4.0001), isTrue);
    expect(HybridProtocol.needsPdhAlternate(100, 96.5), isFalse);
    expect(HybridProtocol.needsPdhAlternate(100, 96.4999), isTrue);
  });
  test('partial or one-stock rank cannot qualify as top five percent', () {
    bool top(int rank, int total, bool complete) => HybridProtocol.topFraction(
      rank: rank,
      total: total,
      fraction: .05,
      complete: complete,
    );
    expect(top(1, 1, true), isFalse);
    expect(top(1, 20, false), isFalse);
    expect(top(1, 20, true), isTrue);
    expect(top(5, 100, true), isTrue);
    expect(top(6, 100, true), isFalse);
    expect(top(0, 100, true), isFalse);
  });
  test('four volume decreases require five comparable samples', () {
    expect(HybridProtocol.fourDeclines([5, 4, 3, 2, 1]), isTrue);
    expect(HybridProtocol.fourDeclines([4, 3, 2, 1]), isFalse);
    expect(HybridProtocol.fourDeclines([5, 4, 4, 2, 1]), isFalse);
  });
  test('known thresholds do not stand in for missing order flow or macro', () {
    final assessment = HybridProtocol.assess(
      isUs: true,
      adr: 5,
      close: 100,
      ema9: 99,
      ema21: 98,
      ema50: 97,
      exchange: 'NMS',
      marketCap: 100000000,
      dollarVolume20: 50000000,
    );
    expect(assessment.checks['liquidity'], CheckState.passed);
    expect(assessment.checks['market_cap'], CheckState.passed);
    expect(assessment.checks['order_flow'], CheckState.missing);
    expect(assessment.passed, isFalse);
    expect(HybridAssessment.fromJson(assessment.toJson()).passed, isFalse);
    final equalEma = HybridProtocol.assess(
      isUs: true,
      adr: 6,
      close: 100,
      ema9: 98,
      ema21: 98,
      ema50: 97,
    );
    expect(equalEma.checks['trend'], CheckState.failed);
  });
  test('legacy confirmed payload stays unverified after reload', () {
    final old = StockCandidate(
      id: 'us:TEST',
      symbol: 'TEST',
      name: 'Test',
      sector: 'fixture',
      market: StockMarket.us,
      adrPercent: 6,
      rsScore: 99,
      rsRank: 1,
      patterns: const ['PDH'],
      entryPrice: 100,
      stopPrice: 98,
      dayLow: 98,
      triggerType: 'PDH',
      isLargeLiquid: true,
      status: 'confirmed',
      dataTimestamp: DateTime.utc(2026, 10, 23),
    );
    expect(old.isConfirmed, isFalse);
    expect(StockCandidate.fromJson(old.toJson()).isConfirmed, isFalse);
    expect(() => StrategyEngine.calculate(old, 100000), throwsArgumentError);
  });
  test('normal/drawdown sizing, original-share rounds and fixed R targets', () {
    PositionPlan plan(RiskMode mode) => StrategyEngine.calculatePrices(
      entryPrice: 100,
      stopPrice: 98,
      equity: 100000,
      isLargeLiquid: true,
      riskMode: mode,
    );
    final normal = plan(RiskMode.normal), reduced = plan(RiskMode.drawdown);
    expect(normal.shares, 250);
    expect(normal.trimShares, 38);
    expect(normal.remainingShares, 174);
    expect(reduced.shares, 125);
    expect(normal.breakEvenTrigger, 103);
    expect(normal.targetPrice(3), 106);
    expect(normal.targetPrice(5), 110);
    expect(() => plan(RiskMode.unknown), throwsArgumentError);
    expect(() => plan(RiskMode.paused), throwsArgumentError);
    final cash = StrategyEngine.calculatePrices(
      entryPrice: 100,
      stopPrice: 98,
      equity: 100000,
      isLargeLiquid: true,
      availableCash: 10000,
      feeBudget: 20,
    );
    expect(cash.shares, 99);
    expect(cash.riskAmount, 218);
  });
  test('1.5R is a suggestion, existing stop and fixed R are preserved', () {
    final p = PortfolioPosition(
      id: 'test', strategyVersion: HybridProtocol.version,
      symbol: 'TEST',
      market: StockMarket.us,
      entryPrice: 100,
      initialStop: 98,
      shares: 250,
    );
    final below = ExitAdvisoryEngine.evaluate(p, quote(102.9999), 100000);
    expect(below.breakEvenSuggested, isFalse);
    final exact = ExitAdvisoryEngine.evaluate(p, quote(103), 100000);
    expect(exact.breakEvenSuggested, isTrue);
    expect(exact.suggestedStop, 100);
    expect(exact.position.trailingStop, 98);
    expect(exact.position.riskPerShare, 2);
    final raised = p.withObservation(2, 101);
    expect(
      ExitAdvisoryEngine.evaluate(raised, quote(104), 100000).suggestedStop,
      101,
    );
  });
  test('old holdings keep legacy exit plan and original data on decode', () {
    final json =
        PortfolioPosition(
            id: 'test',
            symbol: 'TEST',
            market: StockMarket.us,
            entryPrice: 100,
            initialStop: 98,
            shares: 250,
          ).toJson()
          ..remove('strategy_version')
          ..remove('original_shares');
    final p = PortfolioPosition.fromJson(json);
    expect(p.usesHybrid, isFalse);
    expect(
      ExitAdvisoryEngine.evaluate(p, quote(103), 100000).position.trailingStop,
      98,
    );
    expect(
      ExitAdvisoryEngine.evaluate(p, quote(104), 100000).position.trailingStop,
      100,
    );
    expect(p.initialStop, 98);
  });
  test(
    'confirmed first trim does not recalculate second from remaining shares',
    () {
      final p = PortfolioPosition(strategyVersion: HybridProtocol.version,
        id: 'test',
        symbol: 'TEST',
        market: StockMarket.us,
        entryPrice: 100,
        initialStop: 98,
        originalShares: 250,
        shares: 212,
        sold3R: true,
      );
      expect(ExitAdvisoryEngine.evaluate(p, quote(106), 100000).trimShares, 0);
      expect(ExitAdvisoryEngine.evaluate(p, quote(110), 100000).trimShares, 38);
      expect(
        ExitAdvisoryEngine.evaluate(p, quote(110), 100000).position.shares,
        212,
      );
    },
  );
}
