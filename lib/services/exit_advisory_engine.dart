import 'dart:math' as math;

import '../models/portfolio_position.dart';

enum ExitAction { hold, trim, exit }

class PortfolioDiagnosis {
  const PortfolioDiagnosis({required this.position, required this.currentR,
    required this.unrealizedPnl, required this.positionPercent,
    required this.exposureLimitPercent, required this.health,
    required this.action, required this.reasons, required this.selectedEma,
    required this.emaBoundary, required this.trimShares, required this.targets,
    required this.deviationPercent});
  final PortfolioPosition position;
  final double currentR;
  final double unrealizedPnl;
  final double positionPercent;
  final double exposureLimitPercent;
  final String health;
  final ExitAction action;
  final List<String> reasons;
  final int selectedEma;
  final double emaBoundary;
  final int trimShares;
  final Map<int, double> targets;
  final double deviationPercent;
  bool get overExposure => positionPercent > exposureLimitPercent;
  String get label => switch (action) {
    ExitAction.exit => '🔴 建議全數平倉／追蹤停損觸發',
    ExitAction.trim => '🟢 建議分批獲利了結 10%～15%',
    ExitAction.hold => '持有（維持 $selectedEma EMA 追蹤）',
  };
}

/// Advisory only: never places an order or changes a holding's share count.
class ExitAdvisoryEngine {
  static PortfolioDiagnosis evaluate(PortfolioPosition holding,
      PortfolioQuote quote, double equity, {double euphoriaPercent = 20}) {
    if (!equity.isFinite || equity <= 0 || !euphoriaPercent.isFinite ||
        euphoriaPercent < 15 || euphoriaPercent > 20 || holding.key != quote.key) {
      throw ArgumentError('市場、帳戶淨值或正乖離門檻無效。');
    }
    final price = _Decimal.fromDouble(quote.currentPrice);
    final entry = _Decimal.fromDouble(holding.entryPrice);
    final risk = entry - _Decimal.fromDouble(holding.initialStop);
    final ratio = (price - entry) / risk;
    var currentR = ratio.toDouble();
    // A rounded display ratio must not persist an unobserved 2R / 3R crossing.
    if (ratio.compareTo(_Decimal.integer(2)) < 0 && currentR >= 2) {
      currentR = 1.9999999999999998;
    }
    if (ratio.compareTo(_Decimal.integer(3)) < 0 && currentR >= 3) {
      currentR = 2.9999999999999996;
    }
    bool reached(int threshold) => ratio.compareTo(_Decimal.integer(threshold)) >= 0 ||
        holding.peakR >= threshold;
    final peak = math.max(holding.peakR, currentR);
    final stop = math.max(holding.trailingStop,
        math.max(holding.initialStop, reached(2) ? holding.entryPrice : holding.initialStop));
    final observed = holding.withObservation(peak, stop);
    final selectedEma = holding.mainUptrend && reached(3) ? holding.trailingEma : 9;
    final boundary = switch (selectedEma) {
      21 => quote.ema21, 50 => quote.ema50, _ => quote.ema9,
    };
    final quantity = _Decimal.integer(holding.shares);
    final exposureRatio = price * quantity / _Decimal.fromDouble(equity) * _Decimal.integer(100);
    final deviationRatio = (price / _Decimal.fromDouble(quote.ema9) -
        _Decimal.integer(1)) * _Decimal.integer(100);
    final exposure = exposureRatio.toDouble();
    final deviation = deviationRatio.toDouble();
    final exits = <String>[];
    if (quote.currentPrice <= stop) {
      exits.add(reached(2) && stop >= holding.entryPrice
          ? '市價觸及保本／硬停損 ${stop.toStringAsFixed(2)}'
          : '市價觸及初始／硬停損 ${stop.toStringAsFixed(2)}');
    }
    // A current quote below an EMA is not a finalized daily close signal.
    if (quote.closeConfirmed && quote.lastClose! < boundary) {
      exits.add('已確認日收盤跌破 $selectedEma EMA ${boundary.toStringAsFixed(2)}');
    }
    final strengths = <String>[];
    if (ratio.compareTo(_Decimal.integer(3)) >= 0) {
      final target = ratio.compareTo(_Decimal.integer(10)) >= 0 ? 10 :
          ratio.compareTo(_Decimal.integer(5)) >= 0 ? 5 : 3;
      strengths.add('達到 $target R：建議分批减碼');
    }
    if (exposureRatio.compareTo(_Decimal.integer(35)) > 0) {
      strengths.add('單一部位市值超過帳戶淨值 35%');
    }
    if (deviationRatio.compareTo(_Decimal.fromDouble(euphoriaPercent)) > 0) {
      strengths.add('股價相對 9 EMA 正乖離達 ${deviation.toStringAsFixed(1)}%');
    }
    final action = exits.isNotEmpty ? ExitAction.exit :
        strengths.isNotEmpty ? ExitAction.trim : ExitAction.hold;
    final trim = (quantity * _Decimal.parse('0.15')).floor().toInt();
    final trimRatio = _Decimal.integer(trim) / quantity;
    final validTrim = trimRatio.compareTo(_Decimal.parse('0.10')) >= 0 &&
        trimRatio.compareTo(_Decimal.parse('0.15')) <= 0;
    final health = quote.currentPrice < quote.ema50 ? '轉弱跌破 50 EMA' :
        quote.currentPrice >= quote.ema9 ? '強勢（高於 9 EMA）' :
        quote.currentPrice >= quote.ema21 ? '盤整震盪（9／21 EMA 間）' : '轉弱跌破 21 EMA';
    return PortfolioDiagnosis(
      position: observed, currentR: currentR,
      unrealizedPnl: ((price - entry) * quantity).toDouble(),
      positionPercent: exposure, exposureLimitPercent: quote.isLargeLiquid ? 35 : 25,
      health: health, action: action,
      reasons: List.unmodifiable(action == ExitAction.exit ? exits : strengths),
      selectedEma: selectedEma, emaBoundary: boundary,
      trimShares: action == ExitAction.trim && validTrim ? trim : 0,
      targets: Map.unmodifiable({for (final r in [1, 2, 3, 5, 10])
        r: (entry + _Decimal.integer(r) * risk).toDouble()}), deviationPercent: deviation,
    );
  }
}

/// Small normalized decimal fraction, including exponent-form double strings.
class _Decimal {
  factory _Decimal(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) throw StateError('除數不得為 0。');
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final gcd = numerator.abs().gcd(denominator);
    return _Decimal._(numerator ~/ gcd, denominator ~/ gcd);
  }

  const _Decimal._(this.numerator, this.denominator);
  final BigInt numerator;
  final BigInt denominator;

  factory _Decimal.integer(int value) => _Decimal(BigInt.from(value), BigInt.one);
  factory _Decimal.fromDouble(double value) {
    if (!value.isFinite) throw ArgumentError('數值必須為有限數字。');
    return _Decimal.parse(value.toString());
  }

  factory _Decimal.parse(String value) {
    final pieces = value.toLowerCase().split('e');
    final exponent = pieces.length == 2 ? int.parse(pieces[1]) : 0;
    final base = pieces[0].split('.');
    final decimalPlaces = base.length == 2 ? base[1].length : 0;
    final numerator = BigInt.parse(base.join());
    final scale = decimalPlaces - exponent;
    return scale >= 0
        ? _Decimal(numerator, BigInt.from(10).pow(scale))
        : _Decimal(numerator * BigInt.from(10).pow(-scale), BigInt.one);
  }

  _Decimal operator +(_Decimal other) => _Decimal(
      numerator * other.denominator + other.numerator * denominator,
      denominator * other.denominator);
  _Decimal operator -(_Decimal other) => _Decimal(
      numerator * other.denominator - other.numerator * denominator,
      denominator * other.denominator);
  _Decimal operator *(_Decimal other) =>
      _Decimal(numerator * other.numerator, denominator * other.denominator);
  _Decimal operator /(_Decimal other) =>
      _Decimal(numerator * other.denominator, denominator * other.numerator);
  int compareTo(_Decimal other) =>
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
