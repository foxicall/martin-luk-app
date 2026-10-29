import '../models/hybrid_protocol.dart';
import '../models/stock_candidate.dart';

/// The risk budget describes loss at the stop, before fees and gap/slippage.
class PositionPlan {
  PositionPlan({
    required this.shares,
    required this.amount,
    required this.positionPercent,
    required this.riskBudget,
    required this.riskAmount,
    required this.riskPerShare,
    required this.stopPercent,
    required this.capPercent,
    required Map<int, double> targets,
    required this.trimShares,
    required this.breakEvenTrigger,
    required this.riskFraction,
  }) : targets = Map<int, double>.unmodifiable(targets);

  final int shares;
  final double amount;
  final double positionPercent;
  final double riskBudget;
  final double riskAmount;
  final double riskPerShare;
  final double stopPercent;
  final double capPercent;
  final Map<int, double> targets;
  final int trimShares;
  final double breakEvenTrigger, riskFraction;
  int get remainingShares => shares - 2 * trimShares;

  double targetPrice(int r) {
    final value = targets[r];
    if (value == null) throw ArgumentError('僅支援 3R、5R、10R 目標價。');
    return value;
  }
}

class TradeLevels {
  TradeLevels._({
    required this.riskPerShare,
    required this.stopPercent,
    required this.breakEvenTrigger,
    required Map<int, double> targets,
  }) : targets = Map<int, double>.unmodifiable(targets);

  final double riskPerShare;
  final double stopPercent;
  final double breakEvenTrigger;
  final Map<int, double> targets;

  double targetPrice(int r) {
    final value = targets[r];
    if (value == null) throw ArgumentError('僅支援 3R、5R、10R 目標價。');
    return value;
  }
}

/// Shared, deterministic long-only sizing for offline data and API results.
///
/// Decimal inputs use exact rational arithmetic until display conversion. This
/// avoids an extra share at risk, cash and exposure boundaries. Pattern-specific
/// stop validation occurs before sizing; prices are never synthesized.
class StrategyEngine {
  /// Price-only observation; never proves Hybrid entry eligibility.
  static TradeLevels calculateTradeLevels(StockCandidate candidate) {
    if (!candidate.hasValidPriceStop) {
      throw ArgumentError('突破與實際停損尚未確認，不能建立觀察價位。');
    }
    return calculateHypotheticalLevels(entryPrice: candidate.entryPrice,
        stopPrice: candidate.stopPrice!);
  }

  static TradeLevels calculateHypotheticalLevels({
    required double entryPrice,
    required double stopPrice,
  }) {
    if (!entryPrice.isFinite || entryPrice <= 0 || !stopPrice.isFinite ||
        stopPrice <= 0 || stopPrice >= entryPrice) {
      throw ArgumentError('假設停損須為有限正數，且低於假設買價。');
    }
    final entry = _Rational.fromDouble(entryPrice);
    final stop = _Rational.fromDouble(stopPrice);
    final difference = entry - stop;
    final fraction = difference / entry;
    return TradeLevels._(
      riskPerShare: difference.toDouble(),
      stopPercent: (fraction * _Rational.integer(100)).toDouble(),
      breakEvenTrigger: (entry + difference * _Rational.parse('1.5')).toDouble(),
      targets: {
        for (final r in [3, 5, 10])
          r: (entry + difference * _Rational.integer(r)).toDouble(),
      },
    );
  }


  static PositionPlan calculate(
    StockCandidate candidate,
    double equity, {
    int lotSize = 1,
    RiskMode riskMode = RiskMode.normal,
    double? availableCash,
    double feeBudget = 0,
  }) {
    if (!candidate.hasValidStopRange) {
      throw ArgumentError('Hybrid 市場、結構、訂單流或實際停損尚未驗證；僅供觀察。');
    }
    return calculatePrices(
      entryPrice: candidate.entryPrice,
      stopPrice: candidate.stopPrice!,
      equity: equity,
      isLargeLiquid: candidate.isLargeLiquid,
      lotSize: lotSize,
      riskMode: riskMode,
      availableCash: availableCash,
      feeBudget: feeBudget,
    );
  }

  /// Explicit price scenario; this arithmetic is not evidence of an entry.
  static PositionPlan calculatePrices({
    required double entryPrice,
    required double stopPrice,
    required double equity,
    required bool isLargeLiquid,
    int lotSize = 1,
    RiskMode riskMode = RiskMode.normal,
    double? availableCash,
    double feeBudget = 0,
  }) {
    if (!equity.isFinite ||
        equity <= 0 ||
        lotSize <= 0 ||
        !entryPrice.isFinite ||
        !stopPrice.isFinite ||
        entryPrice <= 0 ||
        stopPrice <= 0 ||
        stopPrice >= entryPrice ||
        !feeBudget.isFinite ||
        feeBudget < 0 ||
        (availableCash != null &&
            (!availableCash.isFinite || availableCash < 0))) {
      throw ArgumentError('帳戶淨值、現金、交易單位、費用或實際價格無效。');
    }
    if (riskMode.fraction == null) {
      throw ArgumentError(
        riskMode == RiskMode.paused ? '暫停新倉。' : '請先確認帳戶正常／回撤狀態。',
      );
    }
    final entry = _Rational.fromDouble(entryPrice);
    final stop = _Rational.fromDouble(stopPrice);
    final balance = _Rational.fromDouble(equity);
    final one = _Rational.integer(1);
    final difference = entry - stop;
    if (difference.compareTo(_Rational.integer(0)) <= 0 ||
        stop.compareTo(_Rational.integer(0)) <= 0) {
      throw ArgumentError('停損必須大於 0 且低於進場價。');
    }
    final fraction = difference / entry;
    if (fraction.compareTo(_Rational.parse('0.05')) > 0) {
      throw ArgumentError('初始停損超過5%；請取得有效較近結構，不合成停損。');
    }
    final cap = _Rational.parse(isLargeLiquid ? '0.35' : '0.25');
    final budget = balance * _Rational.fromDouble(riskMode.fraction!);
    final costs = _Rational.fromDouble(feeBudget);
    final cash = _Rational.fromDouble(availableCash ?? equity);
    if (budget.compareTo(costs) <= 0 || cash.compareTo(costs) <= 0) {
      throw ArgumentError('費用預留後無可用風險或現金。');
    }
    final riskShares = ((budget - costs) / difference).floor();
    final capShares = (balance * cap / entry).floor();
    final cashShares = ((cash - costs) / entry).floor();
    final capped = riskShares < capShares ? riskShares : capShares;
    final possible = capped < cashShares ? capped : cashShares;
    final lot = BigInt.from(lotSize);
    final rounded = (possible ~/ lot) * lot;
    // All results must fit a Dart VM/web integer exactly before conversion.
    if (rounded > BigInt.parse('9007199254740991')) {
      throw ArgumentError('計算股數超過可安全表示範圍，請檢查本金與價格。');
    }
    final shares = rounded.toInt();
    if (shares == 0) {
      throw ArgumentError('本金與風險預算不足以買入至少一個交易單位。');
    }
    final quantity = _Rational.integer(shares);
    final amount = quantity * entry;
    final risk = quantity * difference;
    final desiredTrim =
        ((quantity * _Rational.parse('0.15') + _Rational.parse('0.5'))
                .floor() ~/
            lot) *
        lot;
    final trimShares = desiredTrim.toInt().clamp(0, shares ~/ 2);

    if ((risk + costs).compareTo(budget) > 0 ||
        amount.compareTo(balance * cap) > 0 ||
        fraction.compareTo(one) >= 0) {
      throw StateError('倉位計算未通過風險上限檢查。');
    }
    return PositionPlan(
      shares: shares,
      amount: amount.toDouble(),
      positionPercent: (amount / balance * _Rational.integer(100)).toDouble(),
      riskBudget: budget.toDouble(),
      riskAmount: (risk + costs).toDouble(),
      riskPerShare: difference.toDouble(),
      stopPercent: (fraction * _Rational.integer(100)).toDouble(),
      capPercent: (cap * _Rational.integer(100)).toDouble(),
      targets: {
        for (final r in [3, 5, 10])
          r: (entry + difference * _Rational.integer(r)).toDouble(),
      },
      trimShares: trimShares,
      breakEvenTrigger:
          (entry + difference * _Rational.parse('1.5')).toDouble(),
      riskFraction: riskMode.fraction!,
    );
  }
}

/// Small normalized decimal fraction, including exponent-form double strings.
class _Rational {
  factory _Rational(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) throw StateError('除數不得為 0。');
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final gcd = numerator.abs().gcd(denominator);
    return _Rational._(numerator ~/ gcd, denominator ~/ gcd);
  }

  const _Rational._(this.numerator, this.denominator);
  final BigInt numerator;
  final BigInt denominator;

  factory _Rational.integer(int value) =>
      _Rational(BigInt.from(value), BigInt.one);
  factory _Rational.fromDouble(double value) {
    if (!value.isFinite) throw ArgumentError('數值必須為有限數字。');
    return _Rational.parse(value.toString());
  }

  factory _Rational.parse(String value) {
    final pieces = value.toLowerCase().split('e');
    final exponent = pieces.length == 2 ? int.parse(pieces[1]) : 0;
    final base = pieces[0].split('.');
    final decimalPlaces = base.length == 2 ? base[1].length : 0;
    final numerator = BigInt.parse(base.join());
    final scale = decimalPlaces - exponent;
    return scale >= 0
        ? _Rational(numerator, BigInt.from(10).pow(scale))
        : _Rational(numerator * BigInt.from(10).pow(-scale), BigInt.one);
  }

  _Rational operator +(_Rational other) => _Rational(
    numerator * other.denominator + other.numerator * denominator,
    denominator * other.denominator,
  );
  _Rational operator -(_Rational other) => _Rational(
    numerator * other.denominator - other.numerator * denominator,
    denominator * other.denominator,
  );
  _Rational operator *(_Rational other) =>
      _Rational(numerator * other.numerator, denominator * other.denominator);
  _Rational operator /(_Rational other) =>
      _Rational(numerator * other.denominator, denominator * other.numerator);
  int compareTo(_Rational other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
  BigInt floor() {
    final quotient = numerator ~/ denominator;
    return numerator.isNegative &&
            numerator.remainder(denominator) != BigInt.zero
        ? quotient - BigInt.one
        : quotient;
  }

  double toDouble() {
    if (numerator == BigInt.zero) return 0;
    // Scientific notation retains small values without infinity / infinity.
    final exponent =
        numerator.abs().toString().length - denominator.toString().length;
    final scale = 18 - exponent;
    final scaled =
        scale >= 0
            ? (numerator * BigInt.from(10).pow(scale)) ~/ denominator
            : numerator ~/ (denominator * BigInt.from(10).pow(-scale));
    final result = double.parse('${scaled}e${-scale}');
    if (!result.isFinite || result == 0) {
      throw ArgumentError('計算結果超出可顯示範圍。');
    }
    return result;
  }
}
