/// A market's prices and account equity always use its own currency.
enum StockMarket { tw, us }

extension StockMarketInfo on StockMarket {
  String get label => this == StockMarket.tw ? '台股上市' : '美股 S&P 500';
  String get currency => this == StockMarket.tw ? 'TWD' : 'USD';
  String get currencySymbol => this == StockMarket.tw ? 'NT\$' : 'US\$';
  double get defaultEquity => this == StockMarket.tw ? 1000000 : 50000;
  double get defaultAdr => this == StockMarket.tw ? 3.5 : 5.0;
  double get defaultAdrThreshold => defaultAdr;
}

/// Validated, immutable API data. An unconfirmed setup has no suggested order.
class StockCandidate {
  StockCandidate({
    required this.id,
    required this.symbol,
    required this.name,
    required this.sector,
    required this.market,
    required this.adrPercent,
    required this.rsScore,
    required this.rsRank,
    required List<String> patterns,
    required this.entryPrice,
    required this.stopPrice,
    required this.isLargeLiquid,
    required this.status,
    required this.dataTimestamp,
    this.signalTimestamp,
    List<String> notes = const [],
    List<double> dailyCloses = const [],
    double? triggerPrice,
    this.triggerType,
    this.confirmationPrice,
    this.stopSource = 'day_low',
    this.dayLow,
    this.entryBarLow,
    this.ema9, this.ema21, this.ema50, this.quotePrice,
  })  : triggerPrice = triggerPrice ?? entryPrice,
        patterns = List<String>.unmodifiable(patterns),
        notes = List<String>.unmodifiable(notes),
        dailyCloses = List<double>.unmodifiable(dailyCloses) {
    for (final value in [id, symbol, name, sector]) {
      if (value.trim().isEmpty) {
        throw const FormatException('股票代碼、名稱、產業與識別碼不得為空。');
      }
    }
    if (!adrPercent.isFinite || adrPercent < 0) {
      throw const FormatException('ADR 必須為有限且非負的數字。');
    }
    if (!rsScore.isFinite || rsScore < 0 || rsScore > 100 || rsRank < 1) {
      throw const FormatException('RS 分數必須介於 0–100，排名必須為正整數。');
    }
    if (!entryPrice.isFinite || entryPrice <= 0) {
      throw const FormatException('進場參考價必須大於 0。');
    }
    if (!this.triggerPrice.isFinite || this.triggerPrice <= 0 ||
        this.triggerPrice != entryPrice) {
      throw const FormatException('進場參考價必須等於精確突破觸發界線。');
    }
    if (triggerType != null && !['PDH', 'ORH'].contains(triggerType)) {
      throw const FormatException('未知突破界線類型。');
    }
    if (stopSource != null && !['day_low', 'entry_bar_low'].contains(stopSource)) {
      throw const FormatException('未知初始停損來源。');
    }
    for (final value in [confirmationPrice, dayLow, entryBarLow, ema9, ema21, ema50, quotePrice]) {
      if (value != null && (!value.isFinite || value <= 0)) {
        throw const FormatException('確認價及實際低點必須為有限正數。');
      }
    }
    if (stopPrice != null &&
        (!stopPrice!.isFinite || stopPrice! <= 0 || stopPrice! >= entryPrice)) {
      throw const FormatException('停損價必須大於 0 且低於進場價。');
    }
    if (status != 'confirmed' && status != 'watchlist') {
      throw const FormatException('未知訊號狀態，僅接受 confirmed / watchlist。');
    }
    if (status == 'confirmed' && stopPrice == null) {
      throw const FormatException('已確認訊號必須提供可驗證的停損價。');
    }
    if (this.patterns.any((value) => value.trim().isEmpty) ||
        this.notes.any((value) => value.trim().isEmpty)) {
      throw const FormatException('型態與備註不得包含空白字串。');
    }
    if (this.dailyCloses.any((value) => !value.isFinite || value <= 0)) {
      throw const FormatException('歷史收盤價必須為有限正數。');
    }
  }

  final String id;
  final String symbol;
  final String name;
  final String sector;
  final StockMarket market;
  final double adrPercent;
  final double rsScore;
  final int rsRank;
  final List<String> patterns;
  final double entryPrice;
  final double? stopPrice;
  final bool isLargeLiquid;
  final String status;
  final DateTime dataTimestamp;
  final DateTime? signalTimestamp;
  final List<String> notes;
  final List<double> dailyCloses;
  final double triggerPrice;
  final String? triggerType;
  final double? confirmationPrice;
  final String? stopSource;
  final double? dayLow;
  final double? entryBarLow;
  final double? ema9, ema21, ema50, quotePrice;

  bool get isConfirmed => status == 'confirmed';
  double? get riskPerShare => stopPrice == null ? null : entryPrice - stopPrice!;
  bool get hasValidStopRange {
    final percent = stopPercent;
    if (!isConfirmed || percent == null || percent <= 0) return false;
    return stopSource == 'entry_bar_low'
        ? percent >= 1.5 - 1e-10 && percent <= 3 + 1e-10
        : stopSource == 'day_low' && percent <= 5 + 1e-10;
  }
  double? get stopPercent => stopPrice == null
      ? null
      : (entryPrice - stopPrice!) / entryPrice * 100;

  factory StockCandidate.fromJson(Map<String, dynamic> json) {
    final marketText = _string(json, 'market');
    final market = switch (marketText) {
      'tw' => StockMarket.tw,
      'us' => StockMarket.us,
      _ => throw FormatException('未知市場：$marketText'),
    };
    final symbol = _string(json, 'symbol');
    final rankValue = json['rs_rank'];
    if (rankValue is! int || rankValue < 1) {
      throw const FormatException('rs_rank 必須為正整數。');
    }
    final largeValue = json['is_large_liquid'];
    if (largeValue is! bool) {
      throw const FormatException('is_large_liquid 必須為布林值。');
    }
    return StockCandidate(
      id: json.containsKey('id') ? _string(json, 'id') : '${market.name}:$symbol',
      symbol: symbol,
      name: _string(json, 'name'),
      sector: _string(json, 'sector'),
      market: market,
      adrPercent: _number(json, 'adr_percent'),
      rsScore: _number(json, 'rs_score'),
      rsRank: rankValue,
      patterns: _strings(json, 'patterns'),
      entryPrice: _number(json, 'entry_price'),
      stopPrice: json['stop_price'] == null ? null : _number(json, 'stop_price'),
      isLargeLiquid: largeValue,
      status: _string(json, 'status'),
      dataTimestamp: parseApiTimestamp(json['data_timestamp'], 'data_timestamp'),
      signalTimestamp: json['signal_timestamp'] == null
          ? null
          : parseApiTimestamp(json['signal_timestamp'], 'signal_timestamp'),
      notes: _strings(json, 'notes'),
      dailyCloses: _prices(json),
      triggerPrice: json['trigger_price'] == null ? null : _number(json, 'trigger_price'),
      triggerType: json['trigger_type'] == null ? null : _string(json, 'trigger_type'),
      confirmationPrice: json['confirmation_price'] == null ? null : _number(json, 'confirmation_price'),
      stopSource: json.containsKey('stop_source')
          ? (json['stop_source'] == null ? null : _string(json, 'stop_source'))
          : 'day_low',
      dayLow: json['day_low'] == null ? null : _number(json, 'day_low'),
      entryBarLow: json['entry_bar_low'] == null ? null : _number(json, 'entry_bar_low'),
      ema9: json['ema9'] == null ? null : _number(json, 'ema9'),
      ema21: json['ema21'] == null ? null : _number(json, 'ema21'),
      ema50: json['ema50'] == null ? null : _number(json, 'ema50'),
      quotePrice: json['quote_price'] == null ? null : _number(json, 'quote_price'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'market': market.name,
        'symbol': symbol,
        'name': name,
        'sector': sector,
        'adr_percent': adrPercent,
        'rs_score': rsScore,
        'rs_rank': rsRank,
        'patterns': patterns,
        'entry_price': entryPrice,
        'stop_price': stopPrice,
        'is_large_liquid': isLargeLiquid,
        'status': status,
        'data_timestamp': dataTimestamp.toUtc().toIso8601String(),
        'signal_timestamp': signalTimestamp?.toUtc().toIso8601String(),
        'notes': notes,
        'daily_closes': dailyCloses,
        'trigger_price': triggerPrice,
        'trigger_type': triggerType,
        'confirmation_price': confirmationPrice,
        'stop_source': stopSource,
        'day_low': dayLow,
        'entry_bar_low': entryBarLow,
        'risk_per_share': riskPerShare,
        'ema9': ema9, 'ema21': ema21, 'ema50': ema50, 'quote_price': quotePrice,
      };
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key 必須為非空字串。');
  }
  return value.trim();
}

double _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.toDouble().isFinite) {
    throw FormatException('$key 必須為有限數字，不接受數字字串。');
  }
  return value.toDouble();
}

List<String> _strings(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List ||
      value.any((item) => item is! String || item.trim().isEmpty)) {
    throw FormatException('$key 必須為字串陣列。');
  }
  return value.cast<String>();
}

List<double> _prices(Map<String, dynamic> json) {
  final value = json['daily_closes'];
  if (value == null) return const [];
  if (value is! List ||
      value.any((item) => item is! num || !item.toDouble().isFinite)) {
    throw const FormatException('daily_closes 必須為數字陣列。');
  }
  return value.map((item) => (item as num).toDouble()).toList();
}

/// Reject timestamps without an offset: the backend must not hide data age.
DateTime parseApiTimestamp(dynamic value, String field) {
  if (value is! String) {
    throw FormatException('$field 必須為包含時區的 ISO-8601 日期時間。');
  }
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})$',
  ).firstMatch(value);
  if (parts == null) {
    throw FormatException('$field 必須為包含時區的 ISO-8601 日期時間。');
  }
  final year = int.parse(parts[1]!);
  final month = int.parse(parts[2]!);
  final day = int.parse(parts[3]!);
  final hour = int.parse(parts[4]!);
  final minute = int.parse(parts[5]!);
  final second = int.parse(parts[6]!);
  final offset = parts[7]!.replaceAll(':', '');
  if (year < 1 || month < 1 || month > 12 || day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      hour > 23 || minute > 59 || second > 59 ||
      (offset != 'Z' &&
          (int.parse(offset.substring(1, 3)) > 23 ||
              int.parse(offset.substring(3, 5)) > 59))) {
    throw FormatException('$field 包含無效的日期或時間。');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$field 的日期時間格式無效。');
  }
  return parsed.toUtc();
}
