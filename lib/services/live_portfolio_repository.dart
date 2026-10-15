import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/market_data.dart';
import '../models/portfolio_position.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'live_batch_deadline.dart';
import 'live_strategy_engine.dart';
import 'market_data_api.dart';
import 'portfolio_repository.dart';

/// Quotes use the provider's actual quote timestamp and EMAs from finalized
/// daily bars. Stale delivery is explicit so it cannot arm a new trailing stop.
class DirectLivePortfolioRepository implements PortfolioRepository {
  DirectLivePortfolioRepository({MarketDataApi? api, SharedPreferences? preferences,
    DateTime Function()? now, this.updateBudget = const Duration(seconds: 6),
    this.batchSize = 4, this.interBatchDelay = const Duration(milliseconds: 100)})
      : _api = api ?? MarketDataApi(preferences: preferences, now: now),
        _ownsApi = api == null, _preferences = preferences, _now = now ?? DateTime.now {
    if (batchSize < 1 || batchSize > 5) throw ArgumentError.value(batchSize, 'batchSize');
    if (interBatchDelay < Duration.zero) throw ArgumentError.value(interBatchDelay, 'interBatchDelay');
  }
  final MarketDataApi _api;
  final bool _ownsApi;
  final DateTime Function() _now;
  final Duration updateBudget;
  final int batchSize;
  final Duration interBatchDelay;
  SharedPreferences? _preferences;
  Future<Map<String, StockItem>>? _metadata;
  final _engine = const LiveStrategyEngine();
  final Map<String, Future<PortfolioQuoteSnapshot>> _pending = {};
  final Map<String, PortfolioQuote> _quoteCache = {};
  final Set<LiveBatchDeadline> _runs = {};
  bool _closed = false;

  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) {
    if (_closed) throw StateError('持股行情服務已關閉。');
    final unique = symbols.toSet().toList();
    final ordered = [...unique]..sort();
    final key = '${market.name}:${ordered.join(',')}';
    final pending = _pending[key];
    if (pending != null) return pending;
    late Future<PortfolioQuoteSnapshot> operation;
    operation = _fetch(market, unique, forceRefresh).whenComplete(() {
      if (identical(_pending[key], operation)) _pending.remove(key);
    });
    _pending[key] = operation;
    return operation;
  }

  Future<PortfolioQuoteSnapshot> _fetch(StockMarket market, List<String> unique,
      bool forceRefresh) async {
    final run = LiveBatchDeadline(updateBudget);
    _runs.add(run);
    final quotes = <String, PortfolioQuote>{};
    final errors = <String, String>{};
    // Preload stale fallbacks before network work. A deadline can then preserve
    // a genuine prior quote without waiting for another storage request.
    final cached = <String, PortfolioQuote>{};
    for (final symbol in unique) {
      final quote = _quoteCache['${market.name}:$symbol'];
      if (quote != null) {
        final age = _now().toUtc().difference(quote.fetchedAt ?? quote.quoteTimestamp);
        if (!age.isNegative && age <= const Duration(hours: 24)) {
          cached[symbol] = _staleQuote(quote);
        }
      }
    }
    try {
      final metadataFuture = _metadata ??= _loadMetadata();
      final cacheFuture = _loadQuotes(market, unique);
      final metadata = await run.wait(metadataFuture);
      final stored = await run.wait(cacheFuture);
      if (_closed || !run.active) throw TimeoutException('持股更新已取消或逾時。');
      for (final entry in stored.entries) {
        // A failed persistent save must not replace a newer in-memory quote
        // with an older on-disk observation during the next offline refresh.
        final prior = cached[entry.key];
        if (prior == null || entry.value.quoteTimestamp.isAfter(prior.quoteTimestamp)) {
          cached[entry.key] = entry.value;
        }
      }
      Future<void> updateSymbol(String symbol) async {
        if (_closed || !run.active) return;
        try {
          final bundle = await _fetchBundleWithinRun(symbol, market, run, forceRefresh);
          if (_closed || !run.active) return;
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
          final stale = daily.isStale || delivery.isStale || bundle.intradayError != null ||
              (sessionOpenNow && !delivery.isQuoteFresh(currentTime));
          // Historical EMA candles may be reused while the intraday quote is
          // freshly requested. Only quote delivery caching freezes observation.
          final isCached = delivery.isCached;
          final quote = PortfolioQuote(symbol: symbol, name: stock.displayName,
            market: market, currentPrice: delivery.latestPrice,
            ema9: _engine.ema(closes, 9), ema21: _engine.ema(closes, 21),
            ema50: _engine.ema(closes, 50), lastClose: confirmed ? last!.close : null,
            closeConfirmed: confirmed, quoteTimestamp: delivery.quoteTimestamp,
            closeTimestamp: confirmed ? closeTime : null,
            source: delivery.source, isLargeLiquid: largeLiquid(stock),
            isCached: isCached, isStale: stale,
            cacheWarning: delivery.cacheWarning ?? daily.cacheWarning ?? bundle.intradayError ??
                (stale ? '正常交易時段內供應商報價超過 15 分鐘未更新，凍結自動風控觀察。' : null),
            fetchedAt: delivery.fetchedAt);
          if (_closed || !run.active) return;
          quotes[symbol] = quote;
          if (stale) errors[symbol] = '行情更新未取得可用的新報價：'
              '${_errorReason(quote.cacheWarning ?? '行情為過期快取。')}；不更新最高 R 或自動上移停損。';
          if (!stale) {
            _quoteCache[quote.key] = quote;
            await _saveQuote(quote, run);
          }
        } catch (error) {
          if (_closed || !run.active) return;
          final fallback = cached[symbol];
          if (fallback != null) quotes[symbol] = fallback;
          final reason = _errorReason(error);
          errors[symbol] = fallback == null ? '真實行情取得失敗：$reason' :
              '行情更新失敗：$reason；保留上次真實快取；不更新最高 R 或自動上移停損。';
        }
      }
      try {
        for (var start = 0; start < unique.length; start += batchSize) {
          if (_closed || !run.active) break;
          final chunk = unique.skip(start).take(batchSize).toList();
          await run.wait(Future.wait(chunk.map(updateSymbol)));
          if (start + chunk.length < unique.length && !_closed && run.active) {
            await run.pause(interBatchDelay);
          }
        }
      } on TimeoutException {
        // Returned snapshot contains only finished quotes. Late workers remain
        // observed by Future.wait and cannot publish or persist their result.
      }
      run.seal();
      for (final symbol in unique) {
        if (quotes.containsKey(symbol)) continue;
        final fallback = cached[symbol];
        if (fallback != null) quotes[symbol] = fallback;
        // A finished HTTP/parse failure has a concrete cause. Do not replace
        // it with a timeout message merely because no quote was returned.
        errors.putIfAbsent(symbol, () => fallback == null
            ? '持股行情更新逾時或已取消；請重試。'
            : '持股行情更新逾時，保留上次真實快取；不更新最高 R 或自動上移停損。');
      }
    } catch (error) {
      run.seal();
      for (final symbol in unique) {
        if (quotes.containsKey(symbol)) continue;
        final fallback = cached[symbol];
        if (fallback != null) quotes[symbol] = fallback;
        errors.putIfAbsent(symbol, () => fallback == null ? '持股行情更新失敗：${_errorReason(error)}'
            : '行情更新失敗：${_errorReason(error)}；保留上次真實快取；不更新最高 R 或自動上移停損。');
      }
    } finally {
      run.seal();
      _runs.remove(run);
    }
    return PortfolioQuoteSnapshot(quotes: quotes, errors: errors,
        source: quotes.isEmpty ? 'Yahoo 直接連網行情尚不可用' :
            quotes.values.any((quote) => quote.isStale) ?
                'Yahoo Finance／部分過期快取（報價可能延遲）' :
            errors.isNotEmpty ? 'Yahoo Finance／部分持股行情尚未更新（報價可能延遲）' :
                'Yahoo Finance 直接連網（報價可能延遲）');
  }

  Future<ChartBundle> _fetchBundleWithinRun(String symbol, StockMarket market,
      LiveBatchDeadline run, bool forceRefresh) async {
    if (_closed || !run.active) throw TimeoutException('持股更新已取消或逾時。');
    final daily = await run.wait(_api.fetchDaily(symbol, market, forceRefresh: forceRefresh));
    if (_closed || !run.active) throw TimeoutException('持股更新已取消或逾時。');
    try {
      final intraday = await run.wait(_api.fetchIntraday(symbol, market, forceRefresh: forceRefresh));
      if (_closed || !run.active) throw TimeoutException('持股更新已取消或逾時。');
      return ChartBundle(daily: daily, intraday: intraday);
    } catch (error) {
      if (_closed || !run.active) rethrow;
      return ChartBundle(daily: daily, intradayError: error.toString());
    }
  }

  Future<Map<String, StockItem>> _loadMetadata() async {
    try {
      final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json')
          .timeout(const Duration(seconds: 2))) as List;
      final result = <String, StockItem>{};
      for (final row in decoded) {
        try {
          final stock = StockItem.fromJson(row as Map<String, dynamic>);
          result[stock.key] = stock;
        } catch (_) { /* One invalid metadata record does not remove valid names. */ }
      }
      return result;
    } catch (_) { return {}; }
  }

  String _key(StockMarket market, String symbol) => 'martin-live-holding-v1-${market.name}-$symbol';
  Future<SharedPreferences> _prefs() async => _preferences ??= await SharedPreferences.getInstance()
      .timeout(const Duration(seconds: 2));
  Future<void> _saveQuote(PortfolioQuote quote, LiveBatchDeadline run) async {
    if (_closed || !run.active) return;
    try {
      final preferences = await run.wait(_prefs(), maximum: const Duration(seconds: 2));
      if (_closed || !run.active || !identical(_quoteCache[quote.key], quote)) return;
      await run.wait(preferences.setString(_key(quote.market, quote.symbol), jsonEncode({
        'schema': 1, 'saved_at': _now().toUtc().toIso8601String(), 'quote': quote.toJson(),
      })), maximum: const Duration(seconds: 2));
    } catch (_) { /* Storage errors do not invalidate a genuine quote. */ }
  }

  Future<Map<String, PortfolioQuote>> _loadQuotes(StockMarket market, List<String> symbols) async {
    try {
      final preferences = await _prefs();
      final result = <String, PortfolioQuote>{};
      for (final symbol in symbols) {
        try {
          final quote = _decodeQuote(market, symbol, preferences.getString(_key(market, symbol)));
          if (quote != null) result[symbol] = quote;
        } catch (_) { /* A corrupt key must not discard other cached holdings. */ }
      }
      return result;
    } catch (_) { return {}; }
  }

  String _errorReason(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 220 ? text : '${text.substring(0, 220)}…';
  }

  PortfolioQuote? _decodeQuote(StockMarket market, String symbol, String? encoded) {
    try {
      if (encoded == null) return null;
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      if (data['schema'] != 1) return null;
      final saved = DateTime.parse(data['saved_at'] as String).toUtc();
      final age = _now().toUtc().difference(saved);
      if (age.isNegative || age > const Duration(hours: 24)) return null;
      final row = data['quote'] as Map<String, dynamic>;
      final quote = PortfolioQuote.fromJson(row);
      if (quote.market != market || quote.symbol != symbol) return null;
      return _staleQuote(quote);
    } catch (_) { return null; }
  }

  PortfolioQuote _staleQuote(PortfolioQuote quote) => PortfolioQuote.fromJson({
    ...quote.toJson(), 'is_cached': true, 'is_stale': true,
    'cache_warning': '上次真實行情快取，請求失敗；不更新風控狀態。',
    'source': '${quote.source}／過期本機快取',
  });

  @override
  void close() {
    _closed = true;
    for (final run in _runs) { run.seal(); }
    if (_ownsApi) _api.close();
  }
}
