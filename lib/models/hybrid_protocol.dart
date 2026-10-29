/// Shared v1.3.0 rules. Missing evidence never becomes a passing check.
enum CheckState { passed, failed, missing }

enum RiskMode { unknown, normal, drawdown, paused }

extension RiskModeInfo on RiskMode {
  double? get fraction => switch (this) {
    RiskMode.normal => .005,
    RiskMode.drawdown => .0025,
    _ => null,
  };
  String get label => switch (this) {
    RiskMode.unknown => '帳戶狀態未確認',
    RiskMode.normal => '正常 · 0.5%',
    RiskMode.drawdown => '回撤 · 0.25%',
    RiskMode.paused => '暫停新倉',
  };
}

class HybridAssessment {
  HybridAssessment({
    required Map<String, CheckState> checks,
    this.version = HybridProtocol.version,
    this.rankingCount = 0,
    this.rankingScope = '未取得可比較股票池',
    this.rankingComplete = false,
    List<String> notes = const [],
  }) : checks = Map.unmodifiable(checks),
       notes = List.unmodifiable(notes);
  final String version, rankingScope;
  final int rankingCount;
  final bool rankingComplete;
  final Map<String, CheckState> checks;
  final List<String> notes;
  static const requiredChecks = [
    'market',
    'adr',
    'liquidity',
    'market_cap',
    'trend',
    'scanner',
    'macro',
    'structure',
    'order_flow',
    'trigger',
  ];
  static const labels = {
    'market': '交易市場',
    'adr': 'ADR20',
    'liquidity': '20日平均成交額',
    'market_cap': '市值',
    'trend': '9／21／50 EMA',
    'scanner': '三重掃描',
    'macro': '大盤／板塊背景',
    'structure': 'Daily／1H結構及5R空間',
    'order_flow': 'Footprint／Delta／大單',
    'trigger': '進場觸發與停損',
  };
  bool get passed =>
      version == HybridProtocol.version &&
      requiredChecks.every((key) => checks[key] == CheckState.passed);
  String get summary =>
      passed
          ? 'Hybrid v$version 條件已驗證'
          : checks.values.contains(CheckState.failed)
          ? 'Hybrid 條件未通過'
          : 'Hybrid 資料待補齊';
  List<String> get pending =>
      requiredChecks
          .where((key) => checks[key] != CheckState.passed)
          .map(
            (key) =>
                '${labels[key]}：${checks[key] == CheckState.failed ? '未通過' : '未驗證'}',
          )
          .toList();
  Map<String, dynamic> toJson() => {
    'version': version,
    'checks': checks.map((key, value) => MapEntry(key, value.name)),
    'ranking_count': rankingCount,
    'ranking_scope': rankingScope,
    'ranking_complete': rankingComplete,
    'notes': notes,
  };
  factory HybridAssessment.fromJson(Map<String, dynamic> json) {
    final raw = json['checks'];
    if (raw is! Map ||
        json['version'] is! String ||
        json['ranking_count'] is! int ||
        (json['ranking_count'] as int) < 0 ||
        json['ranking_scope'] is! String ||
        json['ranking_complete'] is! bool ||
        json['notes'] is! List ||
        (json['notes'] as List).any((v) => v is! String)) {
      throw const FormatException('Hybrid 驗證資料格式無效。');
    }
    final checks = <String, CheckState>{};
    for (final key in requiredChecks) {
      checks[key] = switch (raw[key]) {
        'passed' => CheckState.passed,
        'failed' => CheckState.failed,
        _ => CheckState.missing,
      };
    }
    return HybridAssessment(
      checks: checks,
      version: json['version'] as String,
      rankingCount: json['ranking_count'] as int,
      rankingScope: json['ranking_scope'] as String,
      rankingComplete: json['ranking_complete'] as bool,
      notes: (json['notes'] as List).cast<String>(),
    );
  }
}

abstract final class HybridProtocol {
  static const version = '1.3.0';
  static const appVersion = '1.7.0+15';
  static bool adrPass(double value, {required bool isUs}) =>
      value.isFinite && (isUs ? value >= 5 : value > 3.5);
  static bool dollarVolumePass(double value) =>
      value.isFinite && value >= 50000000;
  static bool marketCapPass(double value) =>
      value.isFinite && value >= 100000000;
  static bool gapScannerPass(double gap) => gap.isFinite && gap >= 4;
  static bool orhGapPass(double gap) => gap.isFinite && gap > 4;
  static bool needsPdhAlternate(double entry, double dayLow) =>
      (entry - dayLow) / entry > .035 + 1e-12;

  /// Strict rank / denominator: a one-stock page is not a top-5% universe.
  /// Missing members and different dates cannot establish a population rank.
  static bool topFraction({
    required int rank,
    required int total,
    required double fraction,
    required bool complete,
  }) =>
      complete &&
      total > 0 &&
      rank > 0 &&
      rank <= total &&
      fraction > 0 &&
      fraction <= 1 &&
      rank / total <= fraction;

  static bool fourDeclines(List<double> volumes) =>
      volumes.length >= 5 &&
      volumes.every((v) => v.isFinite && v >= 0) &&
      List.generate(
        4,
        (i) =>
            volumes[volumes.length - 5 + i] > volumes[volumes.length - 4 + i],
      ).every((v) => v);

  /// Callers supply independent market/structure/order-flow evidence only
  /// when available. OHLCV alone is intentionally insufficient.
  static HybridAssessment assess({
    required bool isUs,
    required double adr,
    required double close,
    required double ema9,
    required double ema21,
    required double ema50,
    double? marketCap,
    double? dollarVolume20,
    String? exchange,
    CheckState liquidityTw = CheckState.missing,
    CheckState scanner = CheckState.missing,
    CheckState macro = CheckState.missing,
    CheckState structure = CheckState.missing,
    CheckState orderFlow = CheckState.missing,
    CheckState trigger = CheckState.missing,
    int rankingCount = 0,
    String rankingScope = '本頁已取得資料；非全市場排名',
    bool rankingComplete = false,
    List<String> notes = const [],
  }) {
    CheckState flag(bool value) =>
        value ? CheckState.passed : CheckState.failed;
    final venue = exchange?.toUpperCase();
    final trendValid = [
      close,
      ema9,
      ema21,
      ema50,
    ].every((v) => v.isFinite && v > 0);
    return HybridAssessment(
      checks: {
        'market':
            venue == null
                ? CheckState.missing
                : flag(
                  isUs
                      ? [
                        'NYSE',
                        'NASDAQ',
                        'NYQ',
                        'NMS',
                        'NGM',
                        'NCM',
                      ].contains(venue)
                      : ['TWSE', 'TPEX', 'TAI', 'TWO'].contains(venue),
                ),
        'adr': flag(adrPass(adr, isUs: isUs)),
        'liquidity':
            isUs
                ? dollarVolume20 == null
                    ? CheckState.missing
                    : flag(dollarVolumePass(dollarVolume20))
                : liquidityTw,
        'market_cap':
            !isUs
                ? CheckState.passed
                : marketCap == null
                ? CheckState.missing
                : flag(marketCapPass(marketCap)),
        'trend':
            !trendValid
                ? CheckState.missing
                : flag(close > ema21 && ema9 > ema21 && ema21 > ema50),
        'scanner': scanner,
        'macro': macro,
        'structure': structure,
        'order_flow': orderFlow,
        'trigger': trigger,
      },
      rankingCount: rankingCount,
      rankingScope: rankingScope,
      rankingComplete: rankingComplete,
      notes: notes,
    );
  }
}
