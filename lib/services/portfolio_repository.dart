import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/portfolio_position.dart';
import '../models/stock_candidate.dart';

class PortfolioQuoteSnapshot {
  PortfolioQuoteSnapshot({required Map<String, PortfolioQuote> quotes,
    required Map<String, String> errors, required this.source})
      : quotes = Map.unmodifiable(quotes), errors = Map.unmodifiable(errors);
  final Map<String, PortfolioQuote> quotes;
  final Map<String, String> errors;
  final String source;
}

abstract interface class PortfolioRepository {
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false});
  void close();
}

class RealPortfolioRepository implements PortfolioRepository {
  RealPortfolioRepository({required String baseUrl, http.Client? client})
      : _baseUri = Uri.parse(baseUrl), _client = client ?? http.Client(),
        _ownsClient = client == null {
    if (!['http', 'https'].contains(_baseUri.scheme) || _baseUri.host.isEmpty ||
        _baseUri.userInfo.isNotEmpty || _baseUri.hasQuery || _baseUri.hasFragment) {
      throw ArgumentError('行情 API 網址格式無效。');
    }
  }
  final Uri _baseUri;
  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false}) async {
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    final sources = <String>{};
    // The backend permits at most 50 symbols per request. Keep successes from
    // other chunks if a single request fails, and identify every missing quote.
    for (var start = 0; start < symbols.length; start += 50) {
      final batch = symbols.skip(start).take(50).toList();
      try {
        final snapshot = await _fetchBatch(market, batch);
        quotes.addAll(snapshot.quotes);
        errors.addAll(snapshot.errors);
        sources.add(snapshot.source);
      } catch (error) {
        for (final symbol in batch) { errors[symbol] = '行情批次取得失敗：$error'; }
      }
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
      source: sources.isEmpty ? 'API 行情尚不可用' : sources.join('／'));
  }

  Future<PortfolioQuoteSnapshot> _fetchBatch(StockMarket market, List<String> symbols) async {
    if (symbols.isEmpty) {
      return PortfolioQuoteSnapshot(quotes: {}, errors: {}, source: '無持股');
    }
    final endpoint = _baseUri.replace(
      path: '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/quotes',
      queryParameters: {'market': market.name, 'symbols': symbols.join(','), 'demo': 'false'},
    );
    try {
      final response = await _client.get(endpoint,
          headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw StateError('行情 API HTTP ${response.statusCode}');
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic> || data['market'] != market.name ||
          data['quotes'] is! List || data['errors'] is! Map || data['source'] is! String) {
        throw const FormatException('行情回應格式無效。');
      }
      parseApiTimestamp(data['generated_at'], 'generated_at');
      final source = (data['source'] as String).trim();
      if (source.isEmpty || _isDemoSource(source)) {
        throw const FormatException('實際行情 API 回傳了示範來源或空白來源。');
      }
      final quotes = <String, PortfolioQuote>{};
      for (final row in data['quotes'] as List) {
        if (row is! Map<String, dynamic>) throw const FormatException('行情必須為 JSON 物件。');
        final quote = PortfolioQuote.fromJson(row);
        if (quote.market != market || !symbols.contains(quote.symbol) ||
            quotes.containsKey(quote.symbol) || _isDemoSource(quote.source)) {
          throw const FormatException('行情含重複、不同市場或未要求的股票。');
        }
        quotes[quote.symbol] = quote;
      }
      final errors = <String, String>{};
      for (final entry in (data['errors'] as Map).entries) {
        if (entry.key is! String || entry.value is! String ||
            (entry.value as String).trim().isEmpty ||
            !symbols.contains(entry.key) || quotes.containsKey(entry.key)) {
          throw const FormatException('行情錯誤訊息格式無效。');
        }
        errors[entry.key as String] = entry.value as String;
      }
      for (final symbol in symbols) {
        if (!quotes.containsKey(symbol)) errors.putIfAbsent(symbol, () => 'API 未提供可驗證行情');
      }
      return PortfolioQuoteSnapshot(quotes: quotes, errors: errors, source: source);
    } on TimeoutException {
      throw StateError('持股行情連線逾時，請稍後重試。');
    } on http.ClientException {
      throw StateError('無法連線持股行情 API，請檢查網址與網路。');
    }
  }

  @override
  void close() { if (_ownsClient) _client.close(); }
}

bool _isDemoSource(String value) =>
    RegExp(r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(value);

/// Fixed fictitious daily snapshots. Unknown symbols require manual demo input.
class MockPortfolioRepository implements PortfolioRepository {
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false}) async {
    final known = {for (final quote in mockPortfolioQuotes()) quote.key: quote};
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    for (final symbol in symbols) {
      final quote = known['${market.name}:$symbol'];
      if (quote == null) {
        errors[symbol] = '無此股票的固定假行情；請使用「調整示範行情」自行輸入。';
      } else {
        quotes[symbol] = quote;
      }
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors, source: '離線虛構行情');
  }
  @override
  void close() {}
}

List<PortfolioPosition> demoPortfolioPositions() => [
  PortfolioPosition(id: 'demo-tw-2330', symbol: '2330.TW', name: '台積電',
    market: StockMarket.tw, entryPrice: 1000, shares: 200, initialStop: 980),
  PortfolioPosition(id: 'demo-tw-3017', symbol: '3017.TW', name: '奇鋐',
    market: StockMarket.tw, entryPrice: 650, shares: 100, initialStop: 637),
  PortfolioPosition(id: 'demo-us-nvda', symbol: 'NVDA', name: 'NVIDIA',
    market: StockMarket.us, entryPrice: 100, shares: 80, initialStop: 98),
  PortfolioPosition(id: 'demo-us-tsla', symbol: 'TSLA', name: 'Tesla',
    market: StockMarket.us, entryPrice: 250, shares: 40, initialStop: 245),
];

List<PortfolioQuote> mockPortfolioQuotes() {
  final time = DateTime.utc(2026, 10, 13, 6);
  final closeTime = DateTime.utc(2026, 10, 12, 20);
  PortfolioQuote quote(String symbol, String name, StockMarket market,
      double price, double ema9, double ema21, double ema50,
      double close, bool large) => PortfolioQuote(
    symbol: symbol, name: name, market: market, currentPrice: price,
    ema9: ema9, ema21: ema21, ema50: ema50, lastClose: close,
    closeConfirmed: true, quoteTimestamp: time,
    closeTimestamp: market == StockMarket.tw ? DateTime.utc(2026, 10, 12, 5, 30) : closeTime,
    source: '離線虛構行情（並非最新市價）', isLargeLiquid: large,
  );
  return [
    quote('2330.TW', '台積電', StockMarket.tw, 1060, 1040, 1020, 990, 1050, true),
    quote('3017.TW', '奇鋐', StockMarket.tw, 640, 645, 630, 610, 640, false),
    quote('NVDA', 'NVIDIA', StockMarket.us, 110, 107, 104, 100, 109, true),
    quote('TSLA', 'Tesla', StockMarket.us, 248, 247, 240, 230, 249, true),
  ];
}
