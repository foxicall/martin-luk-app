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

  double targetPrice(int r) {
    final value = targets[r];
    if (value == null) throw ArgumentError('僅支援 3R、5R、10R 目標價。');
    return value;
  }
}

/// Shared, deterministic long-only sizing for offline data and API results.
///
/// Decimal inputs use exact rational arithmetic until display conversion. This
/// avoids an extra share at a risk/cap boundary. An observed day-low stop may
/// be up to 5%; only an alternate minute-bar stop must be 1.5%–3%.
class StrategyEngine {
  static PositionPlan calculate(
    StockCandidate candidate,
    double equity, {
    int lotSize = 1,
  }) {
    if (!equity.isFinite || equity <= 0) {
      throw ArgumentError.value(equity, 'equity', '帳戶淨值必須為有限正數。');
    }
    if (lotSize <= 0) {
      throw ArgumentError.value(lotSize, 'lotSize', '交易單位必須為正整數。');
    }
    if (!candidate.isConfirmed || candidate.stopPrice == null) {
      throw ArgumentError('觀察名單尚未確認突破與停損，不能計算建議買進股數。');
    }

    final entry = _Rational.fromDouble(candidate.entryPrice);
    final stop = _Rational.fromDouble(candidate.stopPrice!);
    final balance = _Rational.fromDouble(equity);
    final one = _Rational.integer(1);
    final difference = entry - stop;
    if (difference.compareTo(_Rational.integer(0)) <= 0 ||
        stop.compareTo(_Rational.integer(0)) <= 0) {
      throw ArgumentError('停損必須大於 0 且低於進場價。');
    }
    final fraction = difference / entry;
    if (candidate.stopSource == 'entry_bar_low') {
      if (fraction.compareTo(_Rational.parse('0.015')) < 0 ||
          fraction.compareTo(_Rational.parse('0.03')) > 0 ||
          candidate.entryBarLow != candidate.stopPrice || candidate.dayLow == null) {
        throw ArgumentError('替代停損須為實際分鐘 K 低點，且距離在 1.5%–3%。');
      }
      final dayLow = _Rational.fromDouble(candidate.dayLow!);
      if ((entry - dayLow).compareTo(entry * _Rational.parse('0.05')) <= 0 ||
          dayLow.compareTo(stop) > 0) {
        throw ArgumentError('僅當當日低點風險超過 5% 時採用分鐘 K 低點。');
      }
    } else if (candidate.stopSource != 'day_low' ||
        fraction.compareTo(_Rational.parse('0.05')) > 0 ||
        (candidate.dayLow != null && candidate.dayLow != candidate.stopPrice)) {
      throw ArgumentError('初始停損須為當日實際低點，距離不得超過 5%。');
    }

    final cap = _Rational.parse(candidate.isLargeLiquid ? '0.35' : '0.25');
    final budget = balance * _Rational.parse('0.005');
    final riskShares = (budget / difference).floor();
    final capShares = (balance * cap / entry).floor();
    final possible = riskShares < capShares ? riskShares : capShares;
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
        ((quantity * _Rational.parse('0.12')).floor() ~/ lot) * lot;
    final trimRatio = desiredTrim == BigInt.zero
        ? _Rational.integer(0)
        : _Rational(desiredTrim, BigInt.one) / quantity;
    final trimShares = trimRatio.compareTo(_Rational.parse('0.10')) >= 0 &&
            trimRatio.compareTo(_Rational.parse('0.15')) <= 0
        ? desiredTrim.toInt()
        : 0;

    if (risk.compareTo(budget) > 0 ||
        amount.compareTo(balance * cap) > 0 ||
        fraction.compareTo(one) >= 0) {
      throw StateError('倉位計算未通過風險上限檢查。');
    }
    return PositionPlan(
      shares: shares,
      amount: amount.toDouble(),
      positionPercent: (amount / balance * _Rational.integer(100)).toDouble(),
      riskBudget: budget.toDouble(),
      riskAmount: risk.toDouble(),
      riskPerShare: difference.toDouble(),
      stopPercent: (fraction * _Rational.integer(100)).toDouble(),
      capPercent: (cap * _Rational.integer(100)).toDouble(),
      targets: {
        for (final r in [3, 5, 10])
          r: (entry + difference * _Rational.integer(r)).toDouble(),
      },
      trimShares: trimShares,
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

  factory _Rational.integer(int value) => _Rational(BigInt.from(value), BigInt.one);
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
      denominator * other.denominator);
  _Rational operator -(_Rational other) => _Rational(
      numerator * other.denominator - other.numerator * denominator,
      denominator * other.denominator);
  _Rational operator *(_Rational other) =>
      _Rational(numerator * other.numerator, denominator * other.denominator);
  _Rational operator /(_Rational other) =>
      _Rational(numerator * other.denominator, denominator * other.numerator);
  int compareTo(_Rational other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
  BigInt floor() {
    final quotient = numerator ~/ denominator;
    return numerator.isNegative && numerator.remainder(denominator) != BigInt.zero
        ? quotient - BigInt.one
        : quotient;
  }

  double toDouble() {
    if (numerator == BigInt.zero) return 0;
    // Scientific notation retains small values without infinity / infinity.
    final exponent = numerator.abs().toString().length - denominator.toString().length;
    final scale = 18 - exponent;
    final scaled = scale >= 0
        ? (numerator * BigInt.from(10).pow(scale)) ~/ denominator
        : numerator ~/ (denominator * BigInt.from(10).pow(-scale));
    final result = double.parse('${scaled}e${-scale}');
    if (!result.isFinite || result == 0) {
      throw ArgumentError('計算結果超出可顯示範圍。');
    }
    return result;
  }
}
