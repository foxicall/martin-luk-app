import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/portfolio_position.dart';
import '../models/stock_candidate.dart';
import 'network_request.dart';

class PortfolioQuoteSnapshot {
  PortfolioQuoteSnapshot({required Map<String, PortfolioQuote> quotes,
    required Map<String, String> errors, required this.source,
    List<String> warnings = const []})
      : quotes = Map.unmodifiable(quotes), errors = Map.unmodifiable(errors),
        warnings = List.unmodifiable(warnings);
  final Map<String, PortfolioQuote> quotes;
  final Map<String, String> errors;
  final String source;
  final List<String> warnings;
}

abstract interface class PortfolioRepository {
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false});
  void close();
}

class RealPortfolioRepository implements PortfolioRepository {
  RealPortfolioRepository({required String baseUrl, http.Client? client,
      Duration requestTimeout = NetworkRequest.defaultTimeout})
      : _baseUri = Uri.parse(baseUrl),
        _network = NetworkRequest(client: client, timeout: requestTimeout) {
    if (!['http', 'https'].contains(_baseUri.scheme) || _baseUri.host.isEmpty ||
        _baseUri.userInfo.isNotEmpty || _baseUri.hasQuery || _baseUri.hasFragment) {
      throw ArgumentError('行情 API 網址格式無效。');
    }
  }
  final Uri _baseUri;
  final NetworkRequest _network;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols, {bool forceRefresh = false}) async {
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    final sources = <String>{};
    final warnings = <String>[];
    // The backend permits at most 50 symbols per request. Keep successes from
    // other chunks if a single request fails, and identify every missing quote.
    for (var start = 0; start < symbols.length; start += 50) {
      final batch = symbols.skip(start).take(50).toList();
      try {
        final snapshot = await _fetchBatch(market, batch);
        quotes.addAll(snapshot.quotes);
        errors.addAll(snapshot.errors);
        sources.add(snapshot.source);
        warnings.addAll(snapshot.warnings.take(20 - warnings.length));
      } catch (error) {
        for (final symbol in batch) {
          errors[symbol] = _boundedQuoteMessage('行情批次取得失敗：$error');
        }
      }
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
      source: sources.isEmpty ? 'API 行情尚不可用' : sources.join('／'),
      warnings: warnings);
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
      final response = await _network.get(endpoint,
          headers: {'Accept': 'application/json'});
      if (response.statusCode != 200) throw StateError('行情 API HTTP ${response.statusCode}');
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic> || data['market'] != market.name ||
          data['quotes'] is! List || data['errors'] is! Map || data['source'] is! String) {
        throw const FormatException('行情回應格式無效。');
      }
      final generatedAt = parseApiTimestamp(data['generated_at'], 'generated_at');
      final source = (data['source'] as String).trim();
      if (source.isEmpty || _isDemoSource(source)) {
        throw const FormatException('實際行情 API 回傳了示範來源或空白來源。');
      }
      for (final flag in ['is_cached', 'is_stale', 'stale']) {
        if (data.containsKey(flag) && data[flag] is! bool) {
          throw FormatException('$flag 回應旗標必須為布林值。');
        }
      }
      final quotes = <String, PortfolioQuote>{};
      final errors = <String, String>{};
      final warnings = <String>[];
      final requested = symbols.toSet();
      final seenSymbols = <String>{};
      final rows = data['quotes'] as List;
      void warn(String message) {
        if (warnings.length < 20) warnings.add(_boundedQuoteMessage(message));
      }
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final rawSymbol = row is Map<String, dynamic> ? row['symbol'] : null;
        final symbol = rawSymbol is String ? rawSymbol.trim() : null;
        try {
          if (row is! Map<String, dynamic>) {
            throw const FormatException('行情必須為 JSON 物件。');
          }
          if (symbol != null && requested.contains(symbol) && !seenSymbols.add(symbol)) {
            quotes.remove(symbol);
            throw const FormatException('重複股票行情；該代碼所有回應已排除。');
          }
          for (final flag in ['is_cached', 'is_stale']) {
            if (row.containsKey(flag) && row[flag] is! bool) {
              throw FormatException('$flag 個股旗標必須為布林值。');
            }
          }
          if (row['cache_warning'] != null && row['cache_warning'] is! String) {
            throw const FormatException('個股快取警告必須為字串。');
          }
          final quote = PortfolioQuote.fromJson(row);
          if (quote.market != market || !requested.contains(quote.symbol) ||
              _isDemoSource(quote.source)) {
            throw const FormatException('行情來自不同市場、未要求的股票或示範來源。');
          }
          final latestAllowed = generatedAt.add(const Duration(minutes: 1));
          if (quote.quoteTimestamp.isAfter(latestAllowed) ||
              (quote.fetchedAt?.isAfter(latestAllowed) ?? false)) {
            throw const FormatException('個股報價時間晚於行情回應時間。');
          }
          // Any explicit cached/stale marker freezes observation history. The
          // original provider quote/close timestamps are preserved unchanged.
          final stale = quote.isStale || data['stale'] == true || data['is_stale'] == true;
          final cached = quote.isCached || data['is_cached'] == true || stale ||
              (quote.cacheWarning?.trim().isNotEmpty ?? false);
          quotes[quote.symbol] = PortfolioQuote(
            symbol: quote.symbol, name: quote.name, market: quote.market,
            currentPrice: quote.currentPrice, ema9: quote.ema9,
            ema21: quote.ema21, ema50: quote.ema50, lastClose: quote.lastClose,
            closeConfirmed: quote.closeConfirmed, quoteTimestamp: quote.quoteTimestamp,
            closeTimestamp: quote.closeTimestamp, source: quote.source,
            isLargeLiquid: quote.isLargeLiquid, isCached: cached, isStale: stale,
            cacheWarning: quote.cacheWarning ?? (cached ? 'API 標示為快取行情；最高 R 與停損保持不變。' : null),
            fetchedAt: quote.fetchedAt,
          );
        } catch (error) {
          final reason = error is FormatException ? error.message.toString() : error.runtimeType.toString();
          final label = symbol?.isNotEmpty == true ? symbol! : '第 ${index + 1} 筆行情';
          final message = _boundedQuoteMessage('$label 行情已排除：$reason');
          warn(message);
          if (symbol != null && requested.contains(symbol)) errors[symbol] = message;
        }
      }
      for (final entry in (data['errors'] as Map).entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || !requested.contains(key)) {
          warn('已忽略未要求股票或無代碼的 API 錯誤訊息。');
          continue;
        }
        if (value is! String || value.trim().isEmpty) {
          quotes.remove(key);
          errors[key] = 'API 回傳的個股錯誤訊息格式無效；該股保留上次快取。';
          continue;
        }
        if (quotes.remove(key) != null) {
          errors[key] = _boundedQuoteMessage('同一股票同時回傳行情與錯誤：$value；行情已排除。');
          warn('$key 行情與錯誤互相矛盾，該股保留上次快取。');
        } else {
          errors.putIfAbsent(key, () => _boundedQuoteMessage(value));
        }
      }
      for (final symbol in symbols) {
        if (!quotes.containsKey(symbol)) errors.putIfAbsent(symbol, () => 'API 未提供可驗證行情');
      }
      if (rows.isNotEmpty && quotes.isEmpty) {
        throw FormatException('非空行情清單全部無法驗證：'
            '${errors.values.take(3).join('；')}');
      }
      return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
          source: source, warnings: warnings);
    } on TimeoutException {
      throw StateError('持股行情連線逾時，請稍後重試。');
    } on http.ClientException {
      throw StateError('無法連線持股行情 API，請檢查網址與網路。');
    }
  }

  @override
  void close() { _network.close(); }
}

bool _isDemoSource(String value) =>
    RegExp(r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(value);

String _boundedQuoteMessage(String value) =>
    value.length <= 240 ? value : '${value.substring(0, 240)}…';

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
