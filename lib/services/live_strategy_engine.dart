import 'dart:math' as math;

import '../models/market_data.dart';
import '../models/hybrid_protocol.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'strategy_engine.dart' show PositionPlan, StrategyEngine;

export 'strategy_engine.dart' show PositionPlan, StrategyEngine;

/// Pure sizing for a user-supplied entry/stop pair. This function does not
/// establish that a breakout occurred: the market scanner supplies that proof.
/// Uses an observed stop within 5%; no replacement price is invented.
/// Normal risk is 0.5%, drawdown 0.25%, before unbudgeted gap/slippage losses.
PositionPlan calculatePositionSize({
  required double capital,
  required double entryPrice,
  required double stopLossPrice,
  required bool isMegaCap,
  RiskMode riskMode = RiskMode.normal,
  double? availableCash,
  double feeBudget = 0,
}) => _calculatePositionSize(
  capital: capital,
  entryPrice: entryPrice,
  stopLossPrice: stopLossPrice,
  isMegaCap: isMegaCap,
  riskMode: riskMode,
  availableCash: availableCash,
  feeBudget: feeBudget,
);

/// Immutable prices derived from the original entry/stop risk, even if an
/// existing holding subsequently raises its trailing stop to breakeven.
class ExitTargets {
  ExitTargets({required this.oneR, required Map<int, double> targets})
    : targets = Map<int, double>.unmodifiable(targets);
  final double oneR;
  final Map<int, double> targets;
  double targetPrice(int multiple) {
    final price = targets[multiple];
    if (price == null) throw ArgumentError('僅支援 3R、5R、10R 目標。');
    return price;
  }
}

/// Target math accepts any finite positive initial stop below entry. The
/// new-position stop limits do not redefine a historical holding’s initial R.
ExitTargets calculateExitTargets(double entryPrice, double stopLossPrice) =>
    _calculateExitTargets(entryPrice, stopLossPrice);

/// Calculations consume provider candles only. No synthetic quote, stop or
/// ranking is substituted when history/session metadata is missing.
class LiveStrategyEngine {
  const LiveStrategyEngine();

  static PositionPlan calculatePositionSize({
    required double capital,
    required double entryPrice,
    required double stopLossPrice,
    required bool isMegaCap,
    RiskMode riskMode = RiskMode.normal,
    double? availableCash,
    double feeBudget = 0,
  }) => _calculatePositionSize(
    capital: capital,
    entryPrice: entryPrice,
    stopLossPrice: stopLossPrice,
    isMegaCap: isMegaCap,
    riskMode: riskMode,
    availableCash: availableCash,
    feeBudget: feeBudget,
  );

  static ExitTargets calculateExitTargets(
    double entryPrice,
    double stopLossPrice,
  ) => _calculateExitTargets(entryPrice, stopLossPrice);

  double adrPercent(List<PriceBar> bars, {int period = 20}) {
    if (period < 1 || bars.length < period) {
      throw const FormatException('ADR 所需完整日 K 不足。');
    }
    return bars
            .skip(bars.length - period)
            .map((bar) => (bar.high - bar.low) / bar.low * 100)
            .reduce((a, b) => a + b) /
        period;
  }

  /// SMA seed avoids pretending one initial close is a fully formed EMA.
  double ema(List<double> closes, int period) {
    if (period < 1 ||
        closes.length < period ||
        closes.any((value) => !value.isFinite || value <= 0)) {
      throw const FormatException('EMA 所需完整收盤資料不足或無效。');
    }
    var value = closes.take(period).reduce((a, b) => a + b) / period;
    final alpha = 2 / (period + 1);
    for (final close in closes.skip(period)) {
      value = alpha * close + (1 - alpha) * value;
    }
    return value;
  }

  /// Pair both returns on the same completed exchange dates. A provider may
  /// publish one tail session earlier than its peer; never mix their endpoints.
  /// The callback discloses the actual RS date and excluded tail sessions.
  double relativeMomentum(
    MarketChart stock,
    MarketChart benchmark, {
    void Function(DateTime asOf, int stockTail, int benchmarkTail)? onAligned,
  }) {
    if (stock.market != benchmark.market ||
        stock.currency != benchmark.currency ||
        stock.interval != '1d' ||
        benchmark.interval != '1d') {
      throw const FormatException('RS 必須使用同市場、同幣別的日 K。');
    }
    final stockByDate = <DateTime, PriceBar>{
      for (final bar in stock.completedDailyBars)
        stock.localSessionDate(bar.timestamp): bar,
    };
    final benchmarkByDate = <DateTime, PriceBar>{
      for (final bar in benchmark.completedDailyBars)
        benchmark.localSessionDate(bar.timestamp): bar,
    };
    final common =
        stockByDate.keys.where(benchmarkByDate.containsKey).toList()..sort();
    if (common.length < 61) {
      throw const FormatException('RS 需要股票與指數至少 61 個共同完整交易日。');
    }
    final asOf = common.last;
    final stockDates = stockByDate.keys.toList()..sort();
    final benchmarkDates = benchmarkByDate.keys.toList()..sort();
    final stockTail = stockDates.where((date) => date.isAfter(asOf)).length;
    final benchmarkTail =
        benchmarkDates.where((date) => date.isAfter(asOf)).length;
    String day(DateTime date) => date.toIso8601String().substring(0, 10);
    final context =
        '${stock.symbol}=${day(stockDates.last)}，'
        '${benchmark.symbol}=${day(benchmarkDates.last)}，共同截至 ${day(asOf)}';
    // Bound publication lag; a common date alone must not legitimize old data.
    final stockAge = stock.localSessionDate(stock.fetchedAt).difference(asOf);
    final benchmarkAge = benchmark
        .localSessionDate(benchmark.fetchedAt)
        .difference(asOf);
    if (stockTail > 1 ||
        benchmarkTail > 1 ||
        stockAge.isNegative ||
        benchmarkAge.isNegative ||
        stockAge > const Duration(days: 7) ||
        benchmarkAge > const Duration(days: 7)) {
      throw FormatException('RS 資料落差超過一個已知交易日或共同資料已過期：$context');
    }
    double excess(int sessions) {
      final first = common[common.length - 1 - sessions];
      return (stockByDate[asOf]!.close / stockByDate[first]!.close - 1) -
          (benchmarkByDate[asOf]!.close / benchmarkByDate[first]!.close - 1);
    }

    final score = (excess(20) + excess(60)) / 2 * 100;
    if (!score.isFinite) throw const FormatException('RS 計算結果不是有限數值。');
    onAligned?.call(asOf, stockTail, benchmarkTail);
    return score;
  }

  LiveEvaluation evaluate({
    required StockItem stock,
    required ChartBundle data,
    required MarketChart benchmark,
    required DateTime now,
  }) {
    final bars = data.daily.completedDailyBars;
    final closes = bars.map((bar) => bar.close).toList();
    if (bars.length < 61) {
      throw const FormatException('策略至少需要 61 根完整日 K。');
    }
    final averageRange =
        bars
            .skip(bars.length - 20)
            .map((bar) => bar.high - bar.low)
            .reduce((a, b) => a + b) /
        20;
    final prior = bars.last;
    final earlier = bars[bars.length - 2];
    final ema9 = ema(closes, 9),
        ema21 = ema(closes, 21),
        ema50 = ema(closes, 50);
    final spread =
        ([ema9, ema21, ema50].reduce(math.max) -
            [ema9, ema21, ema50].reduce(math.min)) /
        prior.close;
    final shrinking =
        _std(closes.sublist(closes.length - 7)) <=
        _std(closes.sublist(closes.length - 20)) * .8;
    final compressed =
        spread <= .025 &&
        shrinking &&
        prior.close >= ema9 &&
        prior.close >= ema21 &&
        prior.close >= ema50;
    final inside = prior.high <= earlier.high && prior.low >= earlier.low;
    final narrow = prior.high - prior.low <= averageRange * .6;
    final notes = <String>[
      '日 EMA 與 ADR 僅使用已完成日 K；Yahoo 公開報價可能延遲。',
      'RS 僅為本頁相對排名，不是全市場前5%；失敗標的不算已驗證。',
      'Yahoo未提供Footprint、Delta、Big Trades及固定區間Volume Profile；完整Hybrid未驗證。',
      '盤中量按交易時間線性估算僅供觀察，不能代替同時段歷史量。',
    ];
    var stockDailyBehindBenchmark = false;
    final momentum = relativeMomentum(
      data.daily,
      benchmark,
      onAligned: (asOf, stockTail, benchmarkTail) {
        notes.add(
          'RS 計算截至 ${asOf.toIso8601String().substring(0, 10)}；'
          '股票未納入尾端 $stockTail 日，大盤未納入尾端 $benchmarkTail 日。',
        );
        stockDailyBehindBenchmark = benchmarkTail > 0;
        if (stockDailyBehindBenchmark) {
          notes.add('股票完整日 K 落後大盤，僅列觀察；補齊日 K 後才確認新突破。');
        }
      },
    );
    final patterns = <String>[];
    if (compressed) patterns.add('EMA 9/21/50 收斂');
    if (inside) patterns.add('內包日');
    if (narrow) patterns.add('窄幅整理');
    final intraday = data.intraday;
    var trigger = prior.high;
    String? triggerType = 'PDH';
    double? stop, dayLow, entryBarLow, confirmation;
    String? stopSource;
    double? openingRangeLow;
    DateTime? signalTime;
    if (data.intradayError != null) notes.add(data.intradayError!);
    if (data.daily.isStale || intraday?.isStale == true || benchmark.isStale) {
      notes.add('行情為過期快取，僅供觀察，不建立新進場確認。');
    }
    if (intraday != null &&
        intraday.regularSessionStart != null &&
        intraday.quoteTimestamp.isBefore(intraday.regularSessionStart!) &&
        intraday.localSessionDate(intraday.quoteTimestamp) ==
            intraday.localSessionDate(intraday.regularSessionStart!) &&
        intraday.isQuoteFresh(now)) {
      final premarketGap = (intraday.latestPrice / prior.close - 1) * 100;
      if (HybridProtocol.gapScannerPass(premarketGap)) {
        patterns.add('盤前跳空 ${premarketGap.toStringAsFixed(2)}%（待開盤量能確認）');
        notes.add('盤前報價僅列跳空觀察；ORH 必須等實際開盤區間完成，PDH 是目前參考界線。');
      }
    }
    if (intraday != null &&
        !stockDailyBehindBenchmark &&
        !benchmark.isStale &&
        !data.daily.isStale &&
        !intraday.isStale &&
        intraday.quoteIsInRegularSession &&
        intraday.isQuoteFresh(now)) {
      final regular =
          intraday.regularSessionBars
              .where(
                (bar) => !bar.closeTimestamp.isAfter(intraday.quoteTimestamp),
              )
              .toList();
      // ORH exists only if the actual first regular-session 5-minute candle is
      // present and complete. A delayed/missing opening candle is not replaced.
      final first = regular.isEmpty ? null : regular.first;
      final openingComplete =
          first != null && first.timestamp == intraday.regularSessionStart;
      final gap = first == null ? 0.0 : (first.open / prior.close - 1) * 100;
      final averageVolume =
          bars
              .skip(bars.length - 20)
              .map((bar) => bar.volume)
              .reduce((a, b) => a + b) /
          20;
      final sessionMinutes =
          intraday.regularSessionEnd == null
              ? 0
              : intraday.regularSessionEnd!
                  .difference(intraday.regularSessionStart!)
                  .inMinutes;
      final elapsed =
          regular.isEmpty || intraday.regularSessionStart == null
              ? 0
              : regular.last.closeTimestamp
                  .difference(intraday.regularSessionStart!)
                  .inMinutes;
      final cumulativeVolume = regular.fold<double>(
        0,
        (sum, bar) => sum + bar.volume,
      );
      final expectedVolume =
          sessionMinutes > 0 ? averageVolume * elapsed / sessionMinutes : 0;
      final exceptionalVolume =
          expectedVolume > 0 && cumulativeVolume >= expectedVolume * 1.5;
      final ep =
          openingComplete &&
          HybridProtocol.orhGapPass(gap) &&
          exceptionalVolume;
      if (HybridProtocol.orhGapPass(gap))
        patterns.add('開盤跳空 ${gap.toStringAsFixed(2)}%');
      if (ep) patterns.add('ORH 價格觀察（催化劑／同時段量待核實）');
      final openingHigh = first?.high;
      openingRangeLow = first?.low;
      PriceBar? breakout;
      var volumeThroughBar = 0.0;
      for (var i = 0; i < regular.length; i++) {
        final bar = regular[i];
        if (!openingComplete ||
            (i > 0 && bar.timestamp != regular[i - 1].closeTimestamp)) {
          notes.add('正常交易時段 K 棒缺漏；無法確認完整當日低點，不建立進場單。');
          break;
        }
        volumeThroughBar += bar.volume;
        final minutesThroughBar =
            bar.closeTimestamp
                .difference(intraday.regularSessionStart!)
                .inMinutes;
        final expectedThroughBar =
            sessionMinutes > 0
                ? averageVolume * minutesThroughBar / sessionMinutes
                : 0;
        final epAtBar =
            openingComplete &&
            HybridProtocol.orhGapPass(gap) &&
            expectedThroughBar > 0 &&
            volumeThroughBar >= expectedThroughBar * 1.5;
        final previous = i == 0 ? bar.open : regular[i - 1].close;
        if (epAtBar &&
            i > 0 &&
            openingHigh != null &&
            previous <= openingHigh &&
            bar.close > openingHigh) {
          trigger = openingHigh;
          triggerType = 'ORH';
          breakout = bar;
          break;
        }
        if (!epAtBar &&
            compressed &&
            (inside || narrow) &&
            previous <= prior.high &&
            bar.close > prior.high) {
          trigger = prior.high;
          triggerType = 'PDH';
          breakout = bar;
          break;
        }
      }
      final confirmedBar = breakout;
      if (confirmedBar != null) {
        confirmation = confirmedBar.close;
        entryBarLow = confirmedBar.low;
        dayLow = regular
            .where((bar) => !bar.timestamp.isAfter(confirmedBar.timestamp))
            .map((bar) => bar.low)
            .reduce(math.min);
        final dayRisk = (trigger - dayLow) / trigger * 100;
        if (triggerType == 'ORH' && openingRangeLow != null) {
          final distance = (trigger - openingRangeLow) / trigger * 100;
          if (distance > 0 && distance <= 5) {
            stop = openingRangeLow;
            stopSource = 'opening_range_low';
          }
        } else if (dayRisk > 0 &&
            !HybridProtocol.needsPdhAlternate(trigger, dayLow)) {
          stop = dayLow;
          stopSource = 'day_low';
        } else if (HybridProtocol.needsPdhAlternate(trigger, dayLow) &&
            intraday.interval == '5m' &&
            entryBarLow > dayLow &&
            entryBarLow < trigger &&
            (trigger - entryBarLow) / trigger <= .05) {
          stop = entryBarLow;
          stopSource = 'entry_bar_low';
        }
        if (stop != null && intraday.latestPrice > stop) {
          signalTime = confirmedBar.closeTimestamp;
          patterns.add('$triggerType 突破');
        } else {
          stop = null;
          stopSource = null;
          notes.add('突破缺乏有效停損或最新報價已觸及停損，僅列觀察。');
        }
      }
    } else {
      notes.add('尚無新鮮且位於正常交易時段的完整盤中 K，突破未確認。');
    }
    if (patterns.isEmpty) patterns.add('ADR / RS 動能觀察');
    return LiveEvaluation(
      stock: stock,
      data: data,
      adr: adrPercent(bars),
      momentum: momentum,
      ema9: ema9,
      ema21: ema21,
      ema50: ema50,
      patterns: patterns,
      trigger: trigger,
      triggerType: triggerType,
      stop: stop,
      stopSource: stopSource,
      dayLow: dayLow,
      entryBarLow: entryBarLow,
      confirmation: confirmation,
      signalTime: signalTime,
      notes: notes,
      openingRangeLow: openingRangeLow,
    );
  }

  /// Rank all successfully evaluated securities before applying ADR filters.
  /// Equal raw momentum receives equal percentile; one observation is 50.
  List<StockCandidate> rank(
    List<LiveEvaluation> evaluations, {
    bool completeUniverse = false,
    int? universeCount,
  }) {
    final ordered = [...evaluations]..sort((a, b) {
      final score = b.momentum.compareTo(a.momentum);
      return score == 0 ? a.stock.symbol.compareTo(b.stock.symbol) : score;
    });
    return List.generate(ordered.length, (i) {
      final item = ordered[i];
      var first = i, last = i;
      while (first > 0 && ordered[first - 1].momentum == item.momentum) {
        first--;
      }
      while (last + 1 < ordered.length &&
          ordered[last + 1].momentum == item.momentum) {
        last++;
      }
      final percentile =
          ordered.length < 2
              ? 50.0
              : (ordered.length - 1 - (first + last) / 2) /
                  (ordered.length - 1) *
                  100;
      final complete =
          completeUniverse &&
          universeCount == evaluations.length &&
          evaluations
                  .map(
                    (e) => e.data.daily.localSessionDate(
                      e.data.daily.completedDailyBars.last.timestamp,
                    ),
                  )
                  .toSet()
                  .length ==
              1;
      int rankBy(double Function(LiveEvaluation) metric) =>
          evaluations.where((e) => metric(e) >= metric(item)).length;
      final rank20 = rankBy((e) => e.returnOver(20));
      final rank60 = rankBy((e) => e.returnOver(60));
      final rankDay = rankBy((e) => e.returnOver(1));
      final leaders =
          HybridProtocol.topFraction(
            rank: rank20,
            total: ordered.length,
            fraction: .05,
            complete: complete,
          ) &&
          HybridProtocol.topFraction(
            rank: rank60,
            total: ordered.length,
            fraction: .05,
            complete: complete,
          );
      final movers =
          HybridProtocol.topFraction(
            rank: rankDay,
            total: ordered.length,
            fraction: .03,
            complete: complete,
          ) &&
          item.priorVolumeExpanded;
      return item.toCandidate(
        rsScore: percentile,
        rsRank: first + 1,
        rankingCount: ordered.length,
        rankingComplete: complete,
        scanner: leaders || movers ? CheckState.passed : CheckState.missing,
        rankNote:
            '本頁分母${ordered.length}檔；1月#$rank20／3月#$rank60／前日漲幅#$rankDay；${complete ? '完整同日股票池' : '非全市場百分位'}',
      );
    });
  }

  double _std(List<double> values) {
    final mean = values.reduce((a, b) => a + b) / values.length;
    return math.sqrt(
      values.map((value) => math.pow(value - mean, 2)).reduce((a, b) => a + b) /
          values.length,
    );
  }
}

class LiveEvaluation {
  const LiveEvaluation({
    required this.stock,
    required this.data,
    required this.adr,
    required this.momentum,
    required this.ema9,
    required this.ema21,
    required this.ema50,
    required this.patterns,
    required this.trigger,
    required this.triggerType,
    required this.stop,
    required this.stopSource,
    required this.dayLow,
    required this.entryBarLow,
    required this.confirmation,
    required this.signalTime,
    required this.notes,
    this.openingRangeLow,
  });
  final StockItem stock;
  final ChartBundle data;
  final double adr, momentum, ema9, ema21, ema50, trigger;
  final List<String> patterns, notes;
  final String? triggerType, stopSource;
  final double? stop, dayLow, entryBarLow, confirmation, openingRangeLow;
  final DateTime? signalTime;

  double returnOver(int days) {
    final bars = data.daily.completedDailyBars;
    return bars.last.close / bars[bars.length - days - 1].close - 1;
  }

  bool get priorVolumeExpanded {
    final bars = data.daily.completedDailyBars;
    final priorAverage =
        bars
            .skip(bars.length - 21)
            .take(20)
            .fold<double>(0, (a, b) => a + b.volume) /
        20;
    return priorAverage > 0 && bars.last.volume > priorAverage;
  }

  StockCandidate toCandidate({
    required double rsScore,
    required int rsRank,
    int rankingCount = 0,
    bool rankingComplete = false,
    CheckState scanner = CheckState.missing,
    String? rankNote,
  }) => StockCandidate(
    id: '${stock.market.name}:${stock.symbol}',
    symbol: stock.symbol,
    name: stock.displayName,
    sector: '來源未提供產業',
    market: stock.market,
    adrPercent: adr,
    rsScore: rsScore,
    rsRank: rsRank,
    patterns: patterns,
    entryPrice: trigger,
    triggerPrice: trigger,
    triggerType: triggerType,
    stopPrice: stop,
    stopSource: stopSource,
    dayLow: dayLow,
    entryBarLow: entryBarLow,
    confirmationPrice: confirmation,
    ema9: ema9,
    ema21: ema21,
    ema50: ema50,
    quotePrice: (data.intraday ?? data.daily).latestPrice,
    isLargeLiquid: largeLiquid(stock),
    status: stop == null ? 'watchlist' : 'confirmed',
    dataTimestamp: (data.intraday ?? data.daily).quoteTimestamp,
    signalTimestamp: signalTime,
    notes: [...notes, if (rankNote != null) rankNote],
    openingRangeLow: openingRangeLow,
    hybrid: HybridProtocol.assess(
      isUs: stock.market == StockMarket.us,
      adr: adr,
      close: data.daily.completedDailyBars.last.close,
      ema9: ema9,
      ema21: ema21,
      ema50: ema50,
      marketCap: data.daily.marketCap,
      exchange: data.daily.exchangeName,
      scanner: scanner,
      dollarVolume20:
          data.daily.completedDailyBars
              .skip(data.daily.completedDailyBars.length - 20)
              .fold<double>(0, (a, b) => a + b.close * b.volume) /
          20,
      trigger: stop == null ? CheckState.missing : CheckState.passed,
      rankingCount: rankingCount,
      rankingComplete: rankingComplete,
      notes: const [
        '成交額為逐日收盤價×成交股數之20日平均估算。',
        '回調協定需1M／30S微觀衰竭；目前5M來源只能列背景觀察。',
      ],
    ),
    dailyCloses: data.daily.completedDailyBars.map((bar) => bar.close).toList(),
  );
}

/// A conservative, explicit allowlist. Membership in S&P 500 alone does not
/// prove the liquidity required for a 35% concentration allowance.
bool largeLiquid(StockItem stock) =>
    stock.market == StockMarket.tw
        ? const {
          '2330.TW',
          '2317.TW',
          '2454.TW',
          '2308.TW',
          '2382.TW',
        }.contains(stock.symbol)
        : const {
          'AAPL',
          'MSFT',
          'NVDA',
          'AMZN',
          'GOOGL',
          'GOOG',
          'META',
          'TSLA',
          'AVGO',
          'BRK-B',
        }.contains(stock.symbol);

PositionPlan _calculatePositionSize({
  required double capital,
  required double entryPrice,
  required double stopLossPrice,
  required bool isMegaCap,
  RiskMode riskMode = RiskMode.normal,
  double? availableCash,
  double feeBudget = 0,
}) => StrategyEngine.calculatePrices(
  entryPrice: entryPrice,
  stopPrice: stopLossPrice,
  equity: capital,
  isLargeLiquid: isMegaCap,
  riskMode: riskMode,
  availableCash: availableCash,
  feeBudget: feeBudget,
);

ExitTargets _calculateExitTargets(double entryPrice, double stopLossPrice) {
  _validateRiskPrices(entryPrice, stopLossPrice);
  final entry = _RiskDecimal.fromDouble(entryPrice);
  final difference = entry - _RiskDecimal.fromDouble(stopLossPrice);
  return ExitTargets(
    oneR: difference.toDouble(),
    targets: {
      for (final multiple in [3, 5, 10])
        multiple:
            (entry + difference * _RiskDecimal.integer(multiple)).toDouble(),
    },
  );
}

void _validateRiskPrices(double entry, double stop) {
  if (!entry.isFinite ||
      !stop.isFinite ||
      entry <= 0 ||
      stop <= 0 ||
      stop >= entry) {
    throw ArgumentError('進場／初始停損必須為有限正數，且初始停損必須低於進場價。');
  }
}

/// Decimal double strings are interpreted exactly before division/floor.
/// Isolated from indicator arithmetic: an EMA never sets the sizing rounding.
class _RiskDecimal {
  factory _RiskDecimal(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) throw StateError('除數不得為零。');
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final gcd = numerator.abs().gcd(denominator);
    return _RiskDecimal._(numerator ~/ gcd, denominator ~/ gcd);
  }
  const _RiskDecimal._(this.numerator, this.denominator);
  final BigInt numerator, denominator;
  factory _RiskDecimal.integer(int value) =>
      _RiskDecimal(BigInt.from(value), BigInt.one);
  factory _RiskDecimal.fromDouble(double value) {
    if (!value.isFinite) throw ArgumentError('計算值必須為有限數。');
    return _RiskDecimal.parse(value.toString());
  }
  factory _RiskDecimal.parse(String value) {
    final parts = value.toLowerCase().split('e');
    final exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
    final digits = parts.first.split('.');
    final scale = (digits.length == 2 ? digits[1].length : 0) - exponent;
    final numerator = BigInt.parse(digits.join());
    return scale >= 0
        ? _RiskDecimal(numerator, BigInt.from(10).pow(scale))
        : _RiskDecimal(numerator * BigInt.from(10).pow(-scale), BigInt.one);
  }
  _RiskDecimal operator +(_RiskDecimal other) => _RiskDecimal(
    numerator * other.denominator + other.numerator * denominator,
    denominator * other.denominator,
  );
  _RiskDecimal operator -(_RiskDecimal other) => _RiskDecimal(
    numerator * other.denominator - other.numerator * denominator,
    denominator * other.denominator,
  );
  _RiskDecimal operator *(_RiskDecimal other) => _RiskDecimal(
    numerator * other.numerator,
    denominator * other.denominator,
  );
  _RiskDecimal operator /(_RiskDecimal other) => _RiskDecimal(
    numerator * other.denominator,
    denominator * other.numerator,
  );
  int compareTo(_RiskDecimal other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
  BigInt floor() {
    final whole = numerator ~/ denominator;
    return numerator.isNegative &&
            numerator.remainder(denominator) != BigInt.zero
        ? whole - BigInt.one
        : whole;
  }

  double toDouble() {
    if (numerator == BigInt.zero) return 0;
    final exponent =
        numerator.abs().toString().length - denominator.toString().length;
    final scale = 18 - exponent;
    final scaled =
        scale >= 0
            ? (numerator * BigInt.from(10).pow(scale)) ~/ denominator
            : numerator ~/ (denominator * BigInt.from(10).pow(-scale));
    final result = double.parse('${scaled}e${-scale}');
    if (!result.isFinite || result == 0) throw ArgumentError('計算結果超出可顯示範圍。');
    return result;
  }
}
