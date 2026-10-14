import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/portfolio_position.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'live_strategy_engine.dart';
import 'market_data_api.dart';
import 'portfolio_repository.dart';

/// Quotes use the provider's actual quote timestamp and EMAs from finalized
/// daily bars. Stale delivery is explicit so it cannot arm a new trailing stop.
class DirectLivePortfolioRepository implements PortfolioRepository {
  DirectLivePortfolioRepository({MarketDataApi? api, SharedPreferences? preferences,
    DateTime Function()? now})
      : _api = api ?? MarketDataApi(preferences: preferences, now: now),
        _ownsApi = api == null, _preferences = preferences, _now = now ?? DateTime.now;
  final MarketDataApi _api;
  final bool _ownsApi;
  final DateTime Function() _now;
  SharedPreferences? _preferences;
  Future<Map<String, StockItem>>? _metadata;
  final _engine = const LiveStrategyEngine();
  bool _closed = false;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) async {
    if (_closed) throw StateError('持股行情服務已關閉。');
    final unique = symbols.toSet().toList();
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    final metadata = await (_metadata ??= _loadMetadata());
    var cursor = 0;
    Future<void> worker() async {
      while (!_closed && cursor < unique.length) {
        final symbol = unique[cursor++];
        try {
          final bundle = await _api.fetchBundle(symbol, market, forceRefresh: forceRefresh);
          final daily = bundle.daily;
          final delivery = bundle.intraday ?? daily;
          final bars = daily.completedDailyBars;
          final closes = bars.map((bar) => bar.close).toList();
          final known = metadata['${market.name}:$symbol'];
          final stock = known ?? StockItem(market: market, symbol: symbol,
            code: market == StockMarket.tw ? symbol.split('.').first : symbol,
            nameZh: symbol, nameFullZh: '', nameEn: symbol, abbrEn: '');
          // A final daily close must be no later than the provider quote. Some
          // endpoints publish the close candle before regularMarketTime catches
          // up; do not violate the quote/close chronology in that case.
          final last = bars.isEmpty ? null : bars.last;
          final closeTime = last == null ? null : daily.dailyCloseTimestamp(last);
          final confirmed = closeTime != null && !closeTime.isAfter(delivery.quoteTimestamp);
          final currentTime = _now().toUtc();
          final sessionOpenNow = delivery.regularSessionStart != null &&
              !currentTime.isBefore(delivery.regularSessionStart!) &&
              currentTime.isBefore(delivery.regularSessionEnd!);
          final stale = daily.isStale || delivery.isStale ||
              (sessionOpenNow && !delivery.isQuoteFresh(currentTime));
          // Historical EMA candles may be reused while the intraday quote is
          // freshly requested. Only quote delivery caching freezes observation.
          final cached = delivery.isCached;
          final quote = PortfolioQuote(symbol: symbol, name: stock.displayName,
            market: market, currentPrice: delivery.latestPrice,
            ema9: _engine.ema(closes, 9), ema21: _engine.ema(closes, 21),
            ema50: _engine.ema(closes, 50), lastClose: confirmed ? last!.close : null,
            closeConfirmed: confirmed, quoteTimestamp: delivery.quoteTimestamp,
            closeTimestamp: confirmed ? closeTime : null,
            source: delivery.source, isLargeLiquid: largeLiquid(stock),
            isCached: cached, isStale: stale,
            cacheWarning: delivery.cacheWarning ?? daily.cacheWarning ?? bundle.intradayError ??
                (stale ? '正常交易時段內供應商報價超過 15 分鐘未更新，凍結自動風控觀察。' : null),
            fetchedAt: delivery.fetchedAt);
          quotes[symbol] = quote;
          if (stale) errors[symbol] = '行情為過期快取；不更新最高 R 或自動上移停損。';
          if (!stale) await _saveQuote(quote);
        } catch (error) {
          final cached = await _loadQuote(market, symbol);
          if (cached != null) quotes[symbol] = cached;
          errors[symbol] = cached == null ? '真實行情取得失敗：$error' :
              '連線失敗，保留上次真實快取；不更新最高 R 或自動上移停損。';
        }
      }
    }
    await Future.wait(List.generate(4, (_) => worker()));
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
      source: quotes.isEmpty ? 'Yahoo 直接連網行情尚不可用' :
          quotes.values.any((quote) => quote.isStale) ?
              'Yahoo Finance／部分過期快取（報價可能延遲）' :
              'Yahoo Finance 直接連網（報價可能延遲）');
  }

  Future<Map<String, StockItem>> _loadMetadata() async {
    try {
      final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json')) as List;
      final rows = decoded.map((row) => StockItem.fromJson(row as Map<String, dynamic>));
      return {for (final stock in rows) stock.key: stock};
    } catch (_) { return {}; }
  }

  String _key(StockMarket market, String symbol) => 'martin-live-holding-v1-${market.name}-$symbol';
  Future<SharedPreferences> _prefs() async => _preferences ??= await SharedPreferences.getInstance();
  Future<void> _saveQuote(PortfolioQuote quote) async {
    try {
      await (await _prefs()).setString(_key(quote.market, quote.symbol), jsonEncode({
        'schema': 1, 'saved_at': _now().toUtc().toIso8601String(), 'quote': quote.toJson(),
      }));
    } catch (_) { /* Storage errors do not invalidate a genuine quote. */ }
  }

  Future<PortfolioQuote?> _loadQuote(StockMarket market, String symbol) async {
    try {
      final encoded = (await _prefs()).getString(_key(market, symbol));
      if (encoded == null) return null;
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      if (data['schema'] != 1) return null;
      final saved = DateTime.parse(data['saved_at'] as String).toUtc();
      final age = _now().toUtc().difference(saved);
      if (age.isNegative || age > const Duration(hours: 24)) return null;
      final row = data['quote'] as Map<String, dynamic>;
      row['is_cached'] = true;
      row['is_stale'] = true;
      row['cache_warning'] = '上次真實行情快取，請求失敗；不更新風控狀態。';
      row['source'] = '${row['source']}／過期本機快取';
      final quote = PortfolioQuote.fromJson(row);
      if (quote.market != market || quote.symbol != symbol) return null;
      return quote;
    } catch (_) { return null; }
  }

  @override
  void close() {
    _closed = true;
    if (_ownsApi) _api.close();
  }
}
