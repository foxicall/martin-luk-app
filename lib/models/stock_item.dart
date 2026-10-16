import 'stock_candidate.dart';

/// Search metadata identifies a security. It contains no quote, ADR or signal,
/// so finding a name alone can never create a trade recommendation.
class StockItem {
  StockItem({
    required this.market,
    required this.symbol,
    required this.code,
    required this.nameZh,
    required this.nameFullZh,
    required this.nameEn,
    required this.abbrEn,
    List<String> aliases = const [],
    List<String> shortCodes = const [],
  })  : aliases = List.unmodifiable(aliases),
        shortCodes = List.unmodifiable(shortCodes) {
    if (symbol.isEmpty || code.isEmpty ||
        (market == StockMarket.tw && (!RegExp(r'^\d{4}\.(?:TW|TWO)$').hasMatch(symbol) ||
            code != symbol.split('.').first)) ||
        (market == StockMarket.us && (!RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$').hasMatch(symbol) ||
            code != symbol))) {
      throw const FormatException('股票元資料的市場或標準代碼無效。');
    }
  }

  final StockMarket market;
  final String symbol;
  final String code;
  final String nameZh;
  final String nameFullZh;
  final String nameEn;
  final String abbrEn;
  final List<String> aliases;
  final List<String> shortCodes;

  String get marketTag => market.name.toUpperCase();
  String get displayName => nameZh.isNotEmpty ? nameZh : nameEn;
  String get key => '${market.name}:$symbol';

  factory StockItem.fromJson(Map<String, dynamic> json) {
    String text(String field) {
      final value = json[field];
      if (value is! String) throw FormatException('股票欄位 $field 必須為字串。');
      return value.trim();
    }

    List<String> list(String field) {
      final value = json[field];
      if (value is! List || value.any((entry) => entry is! String)) {
        throw FormatException('股票欄位 $field 必須為字串陣列。');
      }
      return value.cast<String>().map((entry) => entry.trim()).toList();
    }

    final market = switch (text('market').toUpperCase()) {
      'TW' => StockMarket.tw,
      'US' => StockMarket.us,
      _ => throw const FormatException('股票市場必須為 TW 或 US。'),
    };
    return StockItem(
      market: market,
      symbol: text('symbol').toUpperCase(),
      code: text('code').toUpperCase(),
      nameZh: text('name_zh'),
      nameFullZh: text('name_full_zh'),
      nameEn: text('name_en'),
      abbrEn: text('abbr_en'),
      aliases: list('aliases'),
      shortCodes: list('short_codes'),
    );
  }

  Map<String, dynamic> toJson() => {
        'market': marketTag,
        'symbol': symbol,
        'code': code,
        'name_zh': nameZh,
        'name_full_zh': nameFullZh,
        'name_en': nameEn,
        'abbr_en': abbrEn,
        'aliases': aliases,
        'short_codes': shortCodes,
      };
}
