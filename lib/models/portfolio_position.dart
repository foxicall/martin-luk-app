import 'stock_candidate.dart';

/// Long-only holding. Initial risk remains fixed even after a stop is raised.
class PortfolioPosition {
  PortfolioPosition({
    required this.id,
    required this.symbol,
    required this.market,
    required this.entryPrice,
    required this.shares,
    required this.initialStop,
    this.name = '',
    this.peakR = 0,
    double? trailingStop,
    this.trailingEma = 9,
    this.mainUptrend = false,
  }) : trailingStop = trailingStop ?? initialStop {
    if (id.trim().isEmpty || symbol.trim().isEmpty ||
        !(market == StockMarket.tw ? RegExp(r'^\d{4}\.TW$') :
            RegExp(r'^[A-Z][A-Z0-9-]{0,14}$')).hasMatch(symbol) ||
        !entryPrice.isFinite || entryPrice <= 0 || shares <= 0 || shares > 9007199254740991 ||
        !initialStop.isFinite || initialStop <= 0 || initialStop >= entryPrice ||
        !peakR.isFinite || peakR < 0 || !this.trailingStop.isFinite ||
        this.trailingStop < initialStop || ![9, 21, 50].contains(trailingEma)) {
      throw const FormatException('持股價格、股數、初始停損或代碼格式無效。');
    }
  }

  final String id;
  final String symbol;
  final String name;
  final StockMarket market;
  final double entryPrice;
  final int shares;
  final double initialStop;
  final double peakR;
  final double trailingStop;
  final int trailingEma;
  final bool mainUptrend;

  String get key => '${market.name}:$symbol';
  double get riskPerShare => entryPrice - initialStop;

  PortfolioPosition withObservation(double peak, double stop) =>
      PortfolioPosition(id: id, symbol: symbol, market: market, name: name,
        entryPrice: entryPrice, shares: shares, initialStop: initialStop,
        peakR: peak, trailingStop: stop, trailingEma: trailingEma,
        mainUptrend: mainUptrend);

  Map<String, dynamic> toJson() => {
    'id': id, 'symbol': symbol, 'name': name, 'market': market.name,
    'entry_price': entryPrice, 'shares': shares, 'initial_stop': initialStop,
    'peak_r': peakR, 'trailing_stop': trailingStop,
    'trailing_ema': trailingEma, 'main_uptrend': mainUptrend,
  };

  factory PortfolioPosition.fromJson(Map<String, dynamic> json) {
    final shares = json['shares'];
    final ema = json['trailing_ema'] ?? 9;
    final uptrend = json['main_uptrend'] ?? false;
    if (shares is! int || ema is! int || uptrend is! bool) {
      throw const FormatException('股數、EMA 或主升段設定格式無效。');
    }
    return PortfolioPosition(
      id: _text(json, 'id'), symbol: _text(json, 'symbol'),
      name: json['name'] is String ? json['name'] as String : '',
      market: _market(json), entryPrice: _number(json, 'entry_price'),
      shares: shares, initialStop: _number(json, 'initial_stop'),
      peakR: json['peak_r'] == null ? 0 : _number(json, 'peak_r'),
      trailingStop: json['trailing_stop'] == null ? null : _number(json, 'trailing_stop'),
      trailingEma: ema, mainUptrend: uptrend,
    );
  }
}

/// Daily EMA and finalized close are kept distinct from the intraday quote.
class PortfolioQuote {
  PortfolioQuote({
    required this.symbol, required this.name, required this.market,
    required this.currentPrice, required this.ema9, required this.ema21,
    required this.ema50, required this.lastClose, required this.closeConfirmed,
    required this.quoteTimestamp, required this.closeTimestamp,
    required this.source, required this.isLargeLiquid,
  }) {
    if (!(market == StockMarket.tw ? RegExp(r'^\d{4}\.TW$') :
            RegExp(r'^[A-Z][A-Z0-9-]{0,14}$')).hasMatch(symbol) ||
        name.trim().isEmpty || source.trim().isEmpty ||
        [currentPrice, ema9, ema21, ema50].any((n) => !n.isFinite || n <= 0) ||
        (lastClose != null && (!lastClose!.isFinite || lastClose! <= 0)) ||
        (closeConfirmed && (lastClose == null || closeTimestamp == null)) ||
        (closeTimestamp != null && closeTimestamp!.isAfter(quoteTimestamp))) {
      throw const FormatException('行情、每日 EMA 或已確認收盤資料無效。');
    }
  }

  final String symbol;
  final String name;
  final StockMarket market;
  final double currentPrice;
  final double ema9;
  final double ema21;
  final double ema50;
  final double? lastClose;
  final bool closeConfirmed;
  final DateTime quoteTimestamp;
  final DateTime? closeTimestamp;
  final String source;
  final bool isLargeLiquid;
  String get key => '${market.name}:$symbol';

  Map<String, dynamic> toJson() => {
    'symbol': symbol, 'name': name, 'market': market.name,
    'current_price': currentPrice, 'ema9': ema9, 'ema21': ema21, 'ema50': ema50,
    'last_close': lastClose, 'close_confirmed': closeConfirmed,
    'quote_timestamp': quoteTimestamp.toUtc().toIso8601String(),
    'close_timestamp': closeTimestamp?.toUtc().toIso8601String(),
    'source': source, 'is_large_liquid': isLargeLiquid,
  };

  factory PortfolioQuote.fromJson(Map<String, dynamic> json) {
    final confirmed = json['close_confirmed'];
    final large = json['is_large_liquid'];
    if (confirmed is! bool || large is! bool) {
      throw const FormatException('行情旗標必须為布林值。');
    }
    return PortfolioQuote(
      symbol: _text(json, 'symbol'), name: _text(json, 'name'), market: _market(json),
      currentPrice: _number(json, 'current_price'), ema9: _number(json, 'ema9'),
      ema21: _number(json, 'ema21'), ema50: _number(json, 'ema50'),
      lastClose: json['last_close'] == null ? null : _number(json, 'last_close'),
      closeConfirmed: confirmed,
      quoteTimestamp: parseApiTimestamp(json['quote_timestamp'], 'quote_timestamp'),
      closeTimestamp: json['close_timestamp'] == null ? null :
          parseApiTimestamp(json['close_timestamp'], 'close_timestamp'),
      source: _text(json, 'source'), isLargeLiquid: large,
    );
  }
}

StockMarket _market(Map<String, dynamic> json) => switch (json['market']) {
  'tw' => StockMarket.tw, 'us' => StockMarket.us,
  _ => throw const FormatException('市場必須為 tw 或 us。'),
};

String _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) throw FormatException('$key 必須為字串。');
  return value.trim();
}

double _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.toDouble().isFinite) throw FormatException('$key 必須為有限數字。');
  return value.toDouble();
}
