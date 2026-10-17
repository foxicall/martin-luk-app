import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/market_data.dart';
import '../models/stock_candidate.dart';

class MarketDataException implements Exception {
  const MarketDataException(this.message, {this.statusCode, this.symbol,
    this.interval, this.stage, this.endpointHost});
  final String message;
  final int? statusCode;
  final String? symbol, interval, stage, endpointHost;
  @override
  String toString() {
    final context = [symbol, interval, endpointHost, stage]
        .whereType<String>().where((value) => value.isNotEmpty).join(' / ');
    return context.isEmpty ? message : '[$context] $message';
  }
}

/// Direct HTTPS Yahoo chart transport, independent of a privately hosted
/// backend. Public endpoints may throttle, delay quotes or change without
/// notice. No request failure is ever substituted with fictitious prices.
class MarketDataApi {
  MarketDataApi({
    http.Client? client,
    SharedPreferences? preferences,
    Future<SharedPreferences> Function()? preferencesLoader,
    Future<bool> Function(SharedPreferences, String, String)? cacheWriter,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.requestTimeout = defaultTimeout,
    this.storageTimeout = defaultStorageTimeout,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _preferences = preferences,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _cacheWriter = cacheWriter,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    if (requestTimeout <= Duration.zero || requestTimeout > defaultTimeout) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout',
          'HTTP 逾時必須大於零且不得超過 8 秒。');
    }
    if (storageTimeout <= Duration.zero ||
        storageTimeout > defaultStorageTimeout) {
      throw ArgumentError.value(storageTimeout, 'storageTimeout',
          '本機快取等待必須大於零且不得超過 2 秒。');
    }
  }

  static const Duration defaultTimeout = Duration(seconds: 8);
  static const Duration defaultStorageTimeout = Duration(seconds: 2);
  static const int maximumConcurrentRequests = 5;
  /// These limits apply to expendable OHLC payloads, never to holdings,
  /// account settings, exchange metadata or the rolling scan journal.
  static const int maximumCacheEntries = 96;
  static const int maximumCacheBytes = 8 * 1024 * 1024;
  static const int maximumCacheEntryBytes = 512 * 1024;
  static const Duration maximumCacheAge = Duration(days: 7);
  static const String cachePrefix = 'market-data-yahoo-v1:';
  static final _cacheStores = Expando<_ChartCacheStore>('bounded Yahoo cache');
  static const Map<String, String> requestHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  // Shared by every MarketDataApi, including candidate and holdings updates.
  static final _requestSlots = _YahooRequestSlots(maximumConcurrentRequests);

  final http.Client _client;
  final bool _ownsClient;
  final Set<_YahooPendingRequest> _activeRequests = {};
  SharedPreferences? _preferences;
  Future<SharedPreferences?>? _preferencesFuture;
  final Future<SharedPreferences> Function() _preferencesLoader;
  // Optional storage seam for verifying a hung platform write. Production
  // uses SharedPreferences.setString; the live verification gate injects none.
  final Future<bool> Function(SharedPreferences, String, String)? _cacheWriter;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Duration requestTimeout;
  final Duration storageTimeout;
  final _memoryCache = LinkedHashMap<String, _CachedChart>();
  int _memoryCacheBytes = 0;
  final Map<String, Future<MarketChart>> _pending = {};
  DateTime? _rateLimitedUntil;
  bool _closed = false;
  bool _cachePrepared = false;

  @visibleForTesting
  int get debugMemoryCacheEntries => _memoryCache.length;
  /// Encoded payload bytes are a deterministic budget, not a Dart heap profiler.
  @visibleForTesting
  int get debugMemoryCacheBytes => _memoryCacheBytes;

  Future<MarketChart> fetchDaily(String symbol, StockMarket market,
      {bool forceRefresh = false}) => _fetch(symbol, market,
      interval: '1d', range: '6mo', forceRefresh: forceRefresh);

  Future<MarketChart> fetchIntraday(String symbol, StockMarket market,
      {bool forceRefresh = false, String interval = '5m'}) {
    if (!['1m', '5m'].contains(interval)) {
      throw ArgumentError.value(interval, 'interval', '僅支援 1m 或 5m。');
    }
    return _fetch(symbol, market, interval: interval, range: '5d',
        forceRefresh: forceRefresh);
  }

  Future<MarketChart> fetchBenchmark(StockMarket market,
      {bool forceRefresh = false}) => fetchDaily(
      market == StockMarket.tw ? '^TWII' : '^GSPC', market,
      forceRefresh: forceRefresh);

  /// Intraday transport failures leave valid daily observations available, but
  /// carry an explicit error so callers cannot confirm an opening breakout.
  Future<ChartBundle> fetchBundle(String symbol, StockMarket market,
      {bool forceRefresh = false, bool includeIntraday = true}) async {
    final daily = await fetchDaily(symbol, market, forceRefresh: forceRefresh);
    if (!includeIntraday) return ChartBundle(daily: daily);
    try {
      return ChartBundle(daily: daily, intraday: await fetchIntraday(
          symbol, market, forceRefresh: forceRefresh));
    } catch (error) {
      return ChartBundle(daily: daily, intradayError: error.toString());
    }
  }

  Future<MarketChart> _fetch(String symbol, StockMarket market,
      {required String interval, required String range,
      required bool forceRefresh}) async {
    if (_closed) throw StateError('行情服務已關閉。');
    final canonical = canonicalSymbol(symbol, market);
    debugPrint('[MarketAPI] [LOAD] $canonical 週期: $interval，強制更新: $forceRefresh');
    final key = '${market.name}:$canonical:$interval:$range';
    // Acquire the in-flight slot before awaiting storage. A stuck preferences
    // plugin must not admit overlapping requests for the same chart.
    final pending = _pending[key];
    if (pending != null) {
      debugPrint('[MarketAPI] [WAIT] $canonical 共用進行中的 $interval 請求');
      return pending;
    }
    final future = _loadAndRequest(canonical, market, interval, range, key,
        forceRefresh: forceRefresh);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  Future<MarketChart> _loadAndRequest(String canonical, StockMarket market,
      String interval, String range, String key,
      {required bool forceRefresh}) async {
    final cached = await _readCache(key);
    if (_closed) throw StateError('行情服務已關閉。');
    final ttl = interval == '1d'
        ? const Duration(minutes: 15) : const Duration(seconds: 30);
    final age = cached == null ? null : _now().toUtc().difference(cached.fetchedAt);
    if (!forceRefresh && cached != null && age != null &&
        !age.isNegative && age <= ttl) {
      try {
        return _parse(cached.json, symbol: canonical, market: market,
            interval: interval, fetchedAt: cached.fetchedAt, isCached: true);
      } on FormatException {
        await _removeCache(key);
      }
    }
    return _request(canonical, market, interval, range, key, cached);
  }

  Future<MarketChart> _request(String symbol, StockMarket market,
      String interval, String range, String key, _CachedChart? cached) async {
    var stage = 'http';
    var endpointHost = 'query1.finance.yahoo.com';
    try {
      if (_rateLimitedUntil != null && _now().toUtc().isBefore(_rateLimitedUntil!)) {
        throw MarketDataException(
            'Yahoo 暫時限制請求，請於 ${_rateLimitedUntil!.toIso8601String()} 後重試。',
            statusCode: 429);
      }
      final uri = Uri.https('query1.finance.yahoo.com',
          '/v8/finance/chart/$symbol', {
        'interval': interval,
        'range': range,
        'includePrePost': 'true',
        'events': 'div,splits',
      });
      // The retry helper always returns a non-null Response or throws.
      // Nullable response mutation cannot break type promotion here.
      final http.Response received = await _getWithRetry(uri,
          onEndpoint: (endpoint) { endpointHost = endpoint.host; });
      endpointHost = received.request?.url.host ?? endpointHost;
      if (received.statusCode != 200) {
        throw MarketDataException(received.statusCode == 429
            ? 'Yahoo 行情請求過於頻繁（HTTP 429），請稍後重試。'
            : received.statusCode == 403
                ? 'Yahoo 拒絕行情請求（HTTP 403）；請稍後重試或使用設定中的行情中繼。'
            : 'Yahoo 行情 HTTP ${received.statusCode}，請稍後重試。',
            statusCode: received.statusCode);
      }
      stage = 'json';
      if (_isHtmlResponse(received)) {
        debugPrint('[MarketAPI] [ERROR] $symbol 收到 HTML 而非 JSON: '
            '${_bodyPreview(received)}');
        throw const MarketDataException('Yahoo 回傳 HTML／驗證頁而非行情 JSON。');
      }
      final body = utf8.decode(received.bodyBytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      if (body.trim().isEmpty) {
        throw const MarketDataException('Yahoo 回傳空白本文，沒有行情 JSON。');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Yahoo 行情必須為 JSON 物件。');
      }
      // Store provenance beside provider data, without altering any candle.
      decoded['_martin_provider_host'] = endpointHost;
      final fetchedAt = _now().toUtc();
      stage = 'chart';
      final chart = _parse(decoded, symbol: symbol, market: market,
          interval: interval, fetchedAt: fetchedAt);
      if (_closed) throw StateError('行情服務已關閉。');
      // A valid but unexpectedly huge provider response may be displayed; it
      // must not become a permanent payload copied into Android preferences.
      if (received.bodyBytes.length <= maximumCacheEntryBytes) {
        await _saveCache(key, _CachedChart.encode(decoded, fetchedAt));
      }
      if (_closed) throw StateError('行情服務已關閉。');
      return chart;
    } catch (error) {
      if (_closed) throw StateError('行情服務已關閉。');
      if (error is TimeoutException) {
        debugPrint('[MarketAPI] [TIMEOUT] $symbol ($interval / $endpointHost): $error');
      } else {
        debugPrint('[MarketAPI] [ERROR] $symbol ($interval / $endpointHost / $stage) '
            '${error.runtimeType}: $error');
      }
      final String reason = error is MarketDataException ? error.message :
          error is TimeoutException ? 'Yahoo 行情連線逾時，請下拉重試。' :
          error is http.ClientException ? '無法連線 Yahoo 行情：${error.message}' :
          error is FormatException ? 'Yahoo 資料格式錯誤：${error.message}' :
          'Yahoo 行情解析或連線失敗：$error';
      final diagnostic = MarketDataException(reason,
          statusCode: error is MarketDataException ? error.statusCode : null,
          symbol: symbol, interval: interval, stage: stage, endpointHost: endpointHost);
      // Failed refresh retains the original provider/request timestamps and is
      // always marked stale. A cache never turns itself into a new live quote.
      if (cached != null) {
        try {
          return _parse(cached.json, symbol: symbol, market: market,
              interval: interval, fetchedAt: cached.fetchedAt, isCached: true,
              isStale: true, cacheWarning: '更新失敗，顯示上次真實行情快取：$diagnostic');
        } on FormatException {
          await _removeCache(key);
        }
      }
      throw diagnostic;
    }
  }

  Future<http.Response> _getWithRetry(Uri uri, {void Function(Uri)? onEndpoint}) async {
    // Queueing, body download, Retry-After and the retry share one deadline.
    final elapsed = Stopwatch()..start();
    var endpoint = uri;
    final symbol = uri.pathSegments.last;
    for (var attempt = 0; attempt < 2; attempt++) {
      final remaining = requestTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Yahoo 重試超過請求期限。', requestTimeout);
      }
      onEndpoint?.call(endpoint);
      debugPrint('[MarketAPI] >>> 開始抓取: $symbol');
      debugPrint('[MarketAPI] [REQUEST] $symbol 端點: ${endpoint.host}，'
          '週期: ${uri.queryParameters['interval']}，嘗試: ${attempt + 1}/2');
      final http.Response response = await _sendWithTimeout(endpoint, remaining);
      if (response.statusCode != 200) {
        debugPrint('[MarketAPI] [ERROR] $symbol HTTP ${response.statusCode} 失敗: '
            '${_bodyPreview(response)}');
      }
      if (response.statusCode != 429) {
        // One alternate official Yahoo chart endpoint for access/server errors.
        // Rate limits never switch hosts, and all attempts retain one budget.
        final mayRetry = response.statusCode == 403 || response.statusCode == 408 ||
            response.statusCode >= 500 ||
            (response.statusCode == 200 && _isHtmlResponse(response));
        if (attempt == 0 && mayRetry) {
          endpoint = uri.replace(host: 'query2.finance.yahoo.com');
          continue;
        }
        return response;
      }

      final String? header = response.headers['retry-after'];
      final wait = int.tryParse(header ?? '') ?? (header == null ? 1 : 30);
      if (attempt == 1 || wait > 3) {
        _rateLimitedUntil = _now().toUtc().add(
            Duration(seconds: math.max(1, math.min(wait, 300))));
        return response;
      }
      final delayBudget = requestTimeout - elapsed.elapsed;
      if (delayBudget <= Duration.zero) {
        throw TimeoutException('Yahoo 重試超過請求期限。', requestTimeout);
      }
      await _delay(Duration(seconds: math.max(1, wait))).timeout(delayBudget);
      if (_closed) throw StateError('行情服務已關閉。');
    }
    throw const MarketDataException('Yahoo 行情重試次數已達上限。');
  }

  /// Keep logging bounded and Unicode-safe, even for invalid response UTF-8.
  /// String.take is not a Dart API; runes are the appropriate iterable here.
  String _bodyPreview(http.Response response) => String.fromCharCodes(
      utf8.decode(response.bodyBytes.take(1024).toList(), allowMalformed: true)
          .runes.take(200));

  bool _isHtmlResponse(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('text/html') || contentType.contains('application/xhtml')) {
      return true;
    }
    final prefix = utf8.decode(response.bodyBytes.take(256).toList(), allowMalformed: true)
        .replaceFirst(RegExp(r'^\uFEFF'), '').trimLeft().toLowerCase();
    return prefix.startsWith('<!doctype') || prefix.startsWith('<html') ||
        prefix.startsWith('<head') || prefix.startsWith('<body');
  }

  Future<http.Response> _sendWithTimeout(Uri uri, Duration timeout) async {
    if (_closed) throw StateError('行情服務已關閉。');
    final pending = _YahooPendingRequest(_requestSlots.acquire());
    _activeRequests.add(pending);
    var succeeded = false;
    try {
      // Timeout covers waiting for a slot AND the complete response stream.
      final http.Response response = await Future.any<http.Response>([
        _sendWhenReady(uri, pending),
        pending.abort.future.then<http.Response>(
            (_) => throw http.RequestAbortedException(uri)),
      ]).timeout(timeout, onTimeout: () {
        pending.cancel();
        throw TimeoutException('Yahoo HTTP 請求超過期限。', timeout);
      });
      if (_closed) throw StateError('行情服務已關閉。');
      succeeded = true;
      return response;
    } finally {
      _activeRequests.remove(pending);
      if (!succeeded) pending.cancel();
      pending.slot.release();
    }
  }

  Future<http.Response> _sendWhenReady(
      Uri uri, _YahooPendingRequest pending) async {
    await pending.slot.ready;
    if (_closed || pending.abort.isCompleted || !pending.slot.isActive) {
      throw http.RequestAbortedException(uri);
    }
    final request = http.AbortableRequest('GET', uri,
        abortTrigger: pending.abort.future);
    request.headers.addAll(requestHeaders);
    final response = await _client.send(request);
    final symbol = uri.pathSegments.last;
    // Log arrival of headers before awaiting the full body. A stalled body
    // therefore has a status log followed by the existing timeout message.
    debugPrint('[MarketAPI] <<< 標的 $symbol 狀態碼: ${response.statusCode}');
    return http.Response.fromStream(response);
  }

  MarketChart _parse(Map<String, dynamic> document,
      {required String symbol, required StockMarket market,
      required String interval, required DateTime fetchedAt,
      bool isCached = false, bool isStale = false, String? cacheWarning}) {
    final chart = document['chart'];
    if (chart is! Map<String, dynamic>) {
      throw const FormatException('Yahoo 回應缺少 chart 物件。');
    }
    final providerError = chart['error'];
    if (providerError != null) {
      final details = providerError is Map
          ? [providerError['code'], providerError['description']]
              .where((value) => value != null && value.toString().trim().isNotEmpty)
              .join('：')
          : providerError.toString();
      throw FormatException('Yahoo 行情錯誤：${details.isEmpty ? '供應商拒絕提供資料。' : details}');
    }
    final result = chart['result'];
    if (result == null || (result is List && result.isEmpty)) {
      throw const FormatException('Yahoo 未回傳股票行情（result 為空），請確認代碼或稍後重試。');
    }
    if (result is! List || result.length != 1 || result.first is! Map<String, dynamic>) {
      throw const FormatException('Yahoo chart result 格式無效。');
    }
    final row = result.first as Map<String, dynamic>;
    final rawMeta = row['meta'];
    if (rawMeta != null && rawMeta is! Map<String, dynamic>) {
      throw const FormatException('Yahoo meta 元資料必須為物件。');
    }
    final meta = rawMeta is Map<String, dynamic> ? rawMeta : <String, dynamic>{};
    final metadataWarnings = <String>[];
    final providerSymbol = _optionalMetadataText(meta['symbol'], 'symbol');
    if (providerSymbol == null) {
      metadataWarnings.add('供應商未提供代碼，依已請求的標準代碼 $symbol 識別');
    } else if (canonicalSymbol(providerSymbol, market) != symbol) {
      throw const FormatException('Yahoo 股票代碼與要求不一致。');
    }
    final providerCurrency = _optionalMetadataText(meta['currency'], 'currency');
    if (providerCurrency == null) {
      metadataWarnings.add('供應商未提供幣別，依請求市場使用 ${market.currency}');
    } else if (providerCurrency.toUpperCase() != market.currency) {
      throw const FormatException('Yahoo 幣別與要求市場不一致。');
    }
    final expectedZone = market == StockMarket.tw ? 'Asia/Taipei' : 'America/New_York';
    final providerZone = _optionalMetadataText(meta['exchangeTimezoneName'], 'exchangeTimezoneName');
    if (providerZone == null) {
      metadataWarnings.add('供應商未提供交易所時區，依請求市場使用 $expectedZone');
    } else if (providerZone != expectedZone &&
        !(market == StockMarket.us && providerZone == 'US/Eastern')) {
      throw const FormatException('Yahoo 交易所時區與要求市場不一致。');
    } else if (providerZone != expectedZone) {
      metadataWarnings.add('交易所時區 $providerZone 已正規化為 $expectedZone');
    }
    final rawOffset = meta['gmtoffset'];
    final providerOffset = _finiteNumber(rawOffset);
    final int offset;
    if (rawOffset == null) {
      offset = _marketUtcOffset(expectedZone, fetchedAt);
      metadataWarnings.add('供應商未提供 UTC 時差，依 $expectedZone 的實際夏令時間計算');
    } else if (providerOffset == null || providerOffset != providerOffset.toInt() ||
        providerOffset.abs() > 14 * 3600) {
      throw const FormatException('Yahoo UTC 時差必須為有效的整數秒數。');
    } else {
      offset = providerOffset.toInt();
    }
    final timestamps = row['timestamp'];
    final indicators = row['indicators'];
    if (timestamps is! List || indicators is! Map<String, dynamic> ||
        indicators['quote'] is! List || (indicators['quote'] as List).isEmpty ||
        (indicators['quote'] as List).first is! Map<String, dynamic>) {
      throw const FormatException('Yahoo OHLCV 或 K 棒時間缺漏。');
    }
    final values = (indicators['quote'] as List).first as Map<String, dynamic>;
    for (final column in ['open', 'high', 'low', 'close', 'volume']) {
      if (values[column] is! List || (values[column] as List).length != timestamps.length) {
        throw FormatException('Yahoo $column 與時間陣列長度不一致。');
      }
    }
    final duration = switch (interval) {
      '1m' => const Duration(minutes: 1),
      '5m' => const Duration(minutes: 5),
      _ => const Duration(days: 1),
    };
    final bars = <PriceBar>[];
    DateTime? previousProviderTime;
    var discardedRows = 0;
    for (var index = 0; index < timestamps.length; index++) {
      final time = _timestamp(timestamps[index]);
      final open = _positive((values['open'] as List)[index]);
      final high = _positive((values['high'] as List)[index]);
      final low = _positive((values['low'] as List)[index]);
      final close = _positive((values['close'] as List)[index]);
      final volume = _finiteNumber((values['volume'] as List)[index]);
      // Yahoo uses null OHLC rows for unavailable minutes/days. A null row is
      // absent data, not a zero-price candle or an invitation to forward-fill.
      if (time == null || open == null || high == null || low == null ||
          close == null || volume == null ||
          volume < 0 || high < math.max(open, close) ||
          low > math.min(open, close) || time.isAfter(fetchedAt)) {
        discardedRows++;
        continue;
      }
      if (previousProviderTime != null && !time.isAfter(previousProviderTime)) {
        throw const FormatException('Yahoo K 棒時間重複或倒序。');
      }
      previousProviderTime = time;
      bars.add(PriceBar(timestamp: time, open: open, high: high, low: low,
          close: close, volume: volume, interval: duration));
    }
    if (bars.isEmpty) throw const FormatException('Yahoo 沒有可驗證的 OHLCV K 棒。');
    if (discardedRows > 0) {
      metadataWarnings.add('已忽略 $discardedRows 根不完整、無效或未來時間的 K 棒；未補值');
    }
    var price = _positive(meta['regularMarketPrice']);
    var quoteTime = _timestamp(meta['regularMarketTime']);
    // A quote price and timestamp are a pair. Never attach an unrelated candle
    // timestamp to a metadata quote whose original time is absent.
    if (price == null || quoteTime == null) {
      price = null;
      quoteTime = null;
    }
    for (final prefix in ['preMarket', 'postMarket']) {
      final alternativePrice = _positive(meta['${prefix}Price']);
      final alternativeTime = _timestamp(meta['${prefix}Time']);
      if (alternativePrice != null && alternativeTime != null &&
          (quoteTime == null || alternativeTime.isAfter(quoteTime))) {
        price = alternativePrice;
        quoteTime = alternativeTime;
      }
    }
    // The chart endpoint does not always expose pre/post quote fields. Its
    // most recent intraday candle is a valid observation with its own age.
    if (price == null || quoteTime == null ||
        (interval != '1d' && bars.last.timestamp.isAfter(quoteTime))) {
      price = bars.last.close;
      quoteTime = bars.last.timestamp;
      metadataWarnings.add('以最後有效 K 棒的實際收盤值與原始起始時間顯示；非獨立即時成交報價');
    }
    if (price == null || quoteTime == null ||
        quoteTime.isAfter(fetchedAt.add(const Duration(minutes: 1)))) {
      throw const FormatException('Yahoo 缺少可驗證的市價或報價時間。');
    }
    DateTime? sessionStart;
    DateTime? sessionEnd;
    final periods = meta['currentTradingPeriod'];
    if (periods is Map<String, dynamic> && periods['regular'] is Map<String, dynamic>) {
      final regular = periods['regular'] as Map<String, dynamic>;
      sessionStart = _timestamp(regular['start']);
      sessionEnd = _timestamp(regular['end']);
      if (sessionStart == null || sessionEnd == null || !sessionEnd.isAfter(sessionStart)) {
        throw const FormatException('Yahoo 常規交易時段格式無效。');
      }
    } else {
      metadataWarnings.add('供應商未提供當日常規交易時段；不建立開盤區間確認');
    }
    final rawProviderHost = document['_martin_provider_host'];
    final providerHost = rawProviderHost is String &&
        const {'query1.finance.yahoo.com', 'query2.finance.yahoo.com'}.contains(rawProviderHost)
        ? rawProviderHost : 'query1.finance.yahoo.com';
    final parsed = MarketChart(symbol: symbol, market: market,
        currency: market.currency,
        exchangeTimezoneName: expectedZone,
        gmtoffset: offset, bars: bars,
        latestPrice: price, quoteTimestamp: quoteTime, fetchedAt: fetchedAt,
        interval: interval, regularSessionStart: sessionStart,
        regularSessionEnd: sessionEnd, isCached: isCached, isStale: isStale,
        cacheWarning: cacheWarning,
        source: [
          isCached ? 'Yahoo Finance 真實行情本機快取（可能延遲）'
              : 'Yahoo Finance 公開行情（可能延遲，不保證即時）',
          '資料端點：$providerHost',
          ...metadataWarnings,
        ].join('；'));
    debugPrint('[MarketAPI] [SUCCESS] $symbol 取得成功 '
        '(價格: ${parsed.latestPrice}, K線筆數: ${parsed.bars.length})');
    if (isCached) {
      debugPrint('[MarketAPI] [CACHE] $symbol 快取: true，過期: $isStale，'
          '報價時間: ${parsed.quoteTimestamp.toIso8601String()}');
    }
    return parsed;
  }

  Future<SharedPreferences?> _getPreferences() async {
    if (_preferences != null) return _preferences;
    final pending = _preferencesFuture;
    if (pending != null) return pending;
    final operation = () async {
      try {
        final preferences = await _preferencesLoader().timeout(storageTimeout);
        if (!_closed) _preferences = preferences;
        return preferences;
      } catch (_) {
        // Browser privacy mode or an unavailable plugin does not disable HTTP.
        // The in-process cache still works; persistence is best effort.
        return null;
      }
    }();
    _preferencesFuture = operation;
    try {
      return await operation;
    } finally {
      if (identical(_preferencesFuture, operation)) _preferencesFuture = null;
    }
  }

  bool _isRetained(DateTime fetchedAt) {
    final age = _now().toUtc().difference(fetchedAt);
    return !age.isNegative && age <= maximumCacheAge;
  }

  void _forgetMemory(String key) {
    final previous = _memoryCache.remove(key);
    if (previous != null) _memoryCacheBytes -= previous.bytes;
  }

  void _remember(String key, _CachedChart chart) {
    _forgetMemory(key);
    if (_closed || chart.bytes > maximumCacheEntryBytes ||
        !_isRetained(chart.fetchedAt)) return;
    // Both disk reads and HTTP successes use this path. In particular, an
    // offline sweep cannot bypass the old save-only 96-entry limit.
    _memoryCache[key] = chart;
    _memoryCacheBytes += chart.bytes;
    while (_memoryCache.length > maximumCacheEntries ||
        _memoryCacheBytes > maximumCacheBytes) {
      _forgetMemory(_memoryCache.keys.first);
    }
  }

  _ChartCacheStore _store(SharedPreferences preferences) =>
      _cacheStores[preferences] ??= _ChartCacheStore();

  /// Remove only expendable market data. Never call preferences.clear(): that
  /// would destroy account capital, holdings and the saved universe cursor.
  /// Reserve room BEFORE a write so even an interrupted write cannot exceed
  /// the budget. Access order is shared by API instances using the same prefs.
  Future<void> _trimDisk(SharedPreferences preferences, _ChartCacheStore store,
      _ChartCacheLease lease, {String? replacementKey, _CachedChart? replacement}) async {
    final discovered = <String, _ChartDiskEntry>{};
    final remove = <String>[];
    if (!store.initialized) {
      var inspected = 0;
      for (final key in preferences.getKeys()) {
        if (!key.startsWith(cachePrefix)) continue;
        if (++inspected % 32 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!lease.active) return;
        }
        try {
          final raw = preferences.getString(key);
          if (raw == null || raw.length > maximumCacheEntryBytes) {
            remove.add(key);
            continue;
          }
          final bytes = utf8.encode(raw).length;
          // Inspect the short envelope, never decode all cached candle arrays.
          final stamp = RegExp(r'"fetched_at"\s*:\s*"([^"\\]+)"')
              .firstMatch(raw.substring(0, math.min(raw.length, 160)))?.group(1);
          final fetchedAt = stamp == null ? null : DateTime.tryParse(stamp)?.toUtc();
          if (bytes > maximumCacheEntryBytes || fetchedAt == null ||
              !_isRetained(fetchedAt)) {
            remove.add(key);
            continue;
          }
          discovered[key] = _ChartDiskEntry(key, bytes, fetchedAt);
        } catch (_) {
          remove.add(key);
        }
      }
    }
    // After the one-time scan, only tiny metadata is inspected. A full market
    // sweep must not repeatedly encode/decode every retained 8 MiB cache.
    final indexed = store.initialized ? store.entries : discovered;
    final records = <_ChartDiskEntry>[];
    for (final entry in indexed.values) {
      if (entry.key == replacementKey) continue;
      if (!_isRetained(entry.fetchedAt)) {
        remove.add(entry.key);
      } else {
        records.add(entry);
      }
    }
    records.sort((left, right) {
      final leftAccess = store.accessed[left.key];
      final rightAccess = store.accessed[right.key];
      if (leftAccess != null && rightAccess != null) {
        return rightAccess.compareTo(leftAccess);
      }
      if (leftAccess != null) return -1;
      if (rightAccess != null) return 1;
      final time = right.fetchedAt.compareTo(left.fetchedAt);
      return time != 0 ? time : left.key.compareTo(right.key);
    });
    var count = replacement == null ? 0 : 1;
    var bytes = replacement?.bytes ?? 0;
    for (final entry in records) {
      if (count >= maximumCacheEntries || bytes + entry.bytes > maximumCacheBytes) {
        remove.add(entry.key);
      } else {
        count++;
        bytes += entry.bytes;
      }
    }
    for (final key in remove) {
      if (!lease.active) return;
      if (!await lease.write(() => preferences.remove(key))) return;
      store.accessed.remove(key);
      indexed.remove(key);
    }
    if (!lease.active) return;
    if (!store.initialized) {
      store.entries.addAll(discovered);
      store.initialized = true;
    }
    store.accessed.removeWhere((key, _) => !store.entries.containsKey(key));
  }

  Future<_CachedChart?> _readCache(String key) async {
    final memory = _memoryCache[key];
    if (memory != null) {
      if (_isRetained(memory.fetchedAt)) {
        _remember(key, memory);
        final preferences = _preferences;
        if (preferences != null) _store(preferences).touch('$cachePrefix$key');
        return memory;
      }
      _forgetMemory(key);
    }
    final preferences = await _getPreferences();
    if (_closed || preferences == null) return null;
    final store = _store(preferences);
    // Old versions may have persisted one large JSON value for every stock.
    // Android also performs a native pre-engine cleanup; this is the bounded
    // cross-platform safety net and never blocks a real HTTP request forever.
    if (!_cachePrepared) {
      _cachePrepared = await store.run(storageTimeout, () => _closed, (lease) =>
          _trimDisk(preferences, store, lease));
      if (_closed) return null;
    }
    try {
      final raw = preferences.getString('$cachePrefix$key');
      if (raw == null) {
        store.entries.remove('$cachePrefix$key');
        return null;
      }
      if (raw.length > maximumCacheEntryBytes ||
          utf8.encode(raw).length > maximumCacheEntryBytes) {
        throw const FormatException('行情快取超過單筆容量上限。');
      }
      final row = jsonDecode(raw);
      if (row is! Map<String, dynamic> || row['document'] is! Map<String, dynamic> ||
          row['fetched_at'] is! String) throw const FormatException('快取格式無效。');
      final time = DateTime.parse(row['fetched_at'] as String).toUtc();
      if (!_isRetained(time)) throw const FormatException('行情快取已超過保留期限。');
      final cache = _CachedChart(row['document'] as Map<String, dynamic>, time, raw);
      _remember(key, cache);
      store.touch('$cachePrefix$key');
      return cache;
    } catch (_) {
      await _removeCache(key);
      return null;
    }
  }

  Future<void> _saveCache(String key, _CachedChart chart) async {
    if (_closed || chart.bytes > maximumCacheEntryBytes) return;
    _remember(key, chart);
    try {
      final preferences = await _getPreferences();
      if (_closed || preferences == null) return;
      final store = _store(preferences);
      await store.run(storageTimeout, () => _closed, (lease) async {
        await _trimDisk(preferences, store, lease,
            replacementKey: '$cachePrefix$key', replacement: chart);
        if (!lease.active) return;
        if (!await lease.write(() => _cacheWriter?.call(
            preferences, '$cachePrefix$key', chart.raw) ??
            preferences.setString('$cachePrefix$key', chart.raw))) return;
        // Updating the lightweight index is valid even if close() happened
        // during a native write: that write already exists on disk. It does
        // not resurrect this API's RAM cache or start another native write.
        store.entries['$cachePrefix$key'] =
            _ChartDiskEntry('$cachePrefix$key', chart.bytes, chart.fetchedAt);
        if (lease.active) store.touch('$cachePrefix$key');
      });
    } catch (_) {
      // Cache failures cannot discard a valid quote or hold the refresh lock.
    }
  }

  Future<void> _removeCache(String key) async {
    _forgetMemory(key);
    if (_closed) return;
    try {
      final preferences = await _getPreferences();
      if (_closed || preferences == null) return;
      final store = _store(preferences);
      await store.run(storageTimeout, () => _closed, (lease) async {
        if (!await lease.write(() => preferences.remove('$cachePrefix$key'))) return;
        store.accessed.remove('$cachePrefix$key');
        store.entries.remove('$cachePrefix$key');
      });
    } catch (_) { /* Removal is best effort. */ }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _memoryCache.clear();
    _memoryCacheBytes = 0;
    for (final pending in _activeRequests) { pending.cancel(); }
    _activeRequests.clear();
    if (_ownsClient) _client.close();
  }
}

/// File-private cancellation and FIFO slots keep this service self-contained.
class _YahooPendingRequest {
  _YahooPendingRequest(this.slot);
  final _YahooRequestSlot slot;
  final abort = Completer<void>();
  void cancel() {
    if (!abort.isCompleted) abort.complete();
    slot.release();
  }
}

class _YahooRequestSlots {
  _YahooRequestSlots(this.limit);
  final int limit;
  int _used = 0;
  final Queue<_YahooRequestSlot> _queue = Queue<_YahooRequestSlot>();

  _YahooRequestSlot acquire() {
    final slot = _YahooRequestSlot(this);
    _queue.addLast(slot);
    _drain();
    return slot;
  }

  void _release(_YahooRequestSlot slot) {
    if (slot._released) return;
    slot._released = true;
    if (slot._granted) {
      _used--;
    } else {
      _queue.remove(slot);
    }
    if (!slot._ready.isCompleted) slot._ready.complete();
    _drain();
  }

  void _drain() {
    while (_used < limit && _queue.isNotEmpty) {
      final slot = _queue.removeFirst();
      if (slot._released) continue;
      slot._granted = true;
      _used++;
      slot._ready.complete();
    }
  }
}

class _YahooRequestSlot {
  _YahooRequestSlot(this._pool);
  final _YahooRequestSlots _pool;
  final _ready = Completer<void>();
  bool _granted = false;
  bool _released = false;
  Future<void> get ready => _ready.future;
  bool get isActive => _granted && !_released;
  void release() => _pool._release(this);
}

class _CachedChart {
  _CachedChart(this.json, this.fetchedAt, this.raw)
      : bytes = utf8.encode(raw).length;
  factory _CachedChart.encode(Map<String, dynamic> json, DateTime fetchedAt) =>
      _CachedChart(json, fetchedAt, jsonEncode({
        'fetched_at': fetchedAt.toIso8601String(), 'document': json,
      }));
  final Map<String, dynamic> json;
  final DateTime fetchedAt;
  final String raw;
  final int bytes;
}

class _ChartDiskEntry {
  const _ChartDiskEntry(this.key, this.bytes, this.fetchedAt);
  final String key;
  final int bytes;
  final DateTime fetchedAt;
}

/// A shared, bounded writer lane for one preferences instance. Only eight
/// operations may be queued; excess cache work is expendable. A timed-out
/// platform write quarantines this cache writer for this instance, so stalled
/// native callbacks cannot accumulate indefinitely behind repeated scans.
class _ChartCacheStore {
  static const maximumPending = 8;
  final accessed = LinkedHashMap<String, int>();
  int _accessSequence = 0;
  final entries = <String, _ChartDiskEntry>{};
  bool initialized = false;
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  bool _disabled = false;

  void touch(String key) {
    if (!entries.containsKey(key)) return;
    accessed.remove(key);
    accessed[key] = ++_accessSequence;
    while (accessed.length > MarketDataApi.maximumCacheEntries) {
      accessed.remove(accessed.keys.first);
    }
  }

  Future<bool> run(Duration timeout, bool Function() closed,
      Future<void> Function(_ChartCacheLease) action) {
    if (_disabled || closed() || _pending >= maximumPending) {
      return Future<bool>.value(false);
    }
    _pending++;
    final lease = _ChartCacheLease(timeout, closed, () { _disabled = true; });
    final operation = _tail.then<bool>((_) async {
      if (_disabled || !lease.active) return false;
      try {
        await action(lease);
        return lease.active;
      } catch (_) {
        return false;
      }
    });
    final bounded = operation.timeout(timeout, onTimeout: () {
      // Both timers share a deadline. Quarantine synchronously here as well,
      // before the next lane item can run, if a native write is still pending.
      if (lease.writing) lease.stalled();
      lease.cancel();
      return false;
    });
    _tail = bounded.then<void>((_) {});
    return bounded.whenComplete(() { _pending--; });
  }
}

class _ChartCacheLease {
  _ChartCacheLease(this.timeout, this.closed, this.onStalledWrite);
  final Duration timeout;
  final bool Function() closed;
  final void Function() onStalledWrite;
  final _watch = Stopwatch()..start();
  bool _cancelled = false;
  bool writing = false;
  bool get active => !_cancelled && !closed() && _watch.elapsed < timeout;
  void cancel() { _cancelled = true; }
  void stalled() {
    cancel();
    onStalledWrite();
  }

  Future<bool> write(Future<bool> Function() operation) async {
    if (!active) return false;
    final left = timeout - _watch.elapsed;
    writing = true;
    try {
      final saved = await operation().timeout(left);
      if (!saved) throw StateError('行情快取未能儲存。');
      return true;
    } on TimeoutException {
      stalled();
      rethrow;
    } finally {
      writing = false;
    }
  }
}

/// Canonical Yahoo class-share spelling and TWSE/TPEx suffix. Index IDs are only
/// accepted for their own market, avoiding an accidental USD/TWD benchmark mix.
String canonicalSymbol(String raw, StockMarket market) {
  var symbol = raw.trim().toUpperCase();
  if (market == StockMarket.tw) {
    if (symbol == '^TWII') return symbol;
    if (RegExp(r'^\d{4}$').hasMatch(symbol)) symbol = '$symbol.TW';
    if (!RegExp(r'^\d{4}\.(?:TW|TWO)$').hasMatch(symbol)) {
      throw FormatException('台股行情僅接受四位普通股代碼與 .TW（上市）或 .TWO（上櫃）：$raw');
    }
  } else {
    if (symbol == '^GSPC') return symbol;
    // A dot is only a class-share alias (BRK.B), never a foreign suffix.
    if (symbol.contains('.') &&
        !RegExp(r'^[A-Z][A-Z0-9]{0,12}\.[A-Z]$').hasMatch(symbol)) {
      throw FormatException('美股代碼不可包含其他市場後綴：$raw');
    }
    symbol = symbol.replaceAll('.', '-');
    if (!RegExp(r'^[A-Z][A-Z0-9-]{0,14}$').hasMatch(symbol)) {
      throw FormatException('美股代碼格式無效：$raw');
    }
  }
  return symbol;
}

double? _finiteNumber(Object? value) {
  final numeric = value is num ? value
      : value is String ? num.tryParse(value.trim()) : null;
  if (numeric == null) return null;
  final converted = numeric.toDouble();
  return converted.isFinite ? converted : null;
}

double? _positive(Object? value) {
  final number = _finiteNumber(value);
  return number != null && number > 0 ? number : null;
}

DateTime? _timestamp(Object? value) {
  final number = _finiteNumber(value);
  if (number == null || number <= 0 || number > 8640000000000 ||
      number != number.toInt()) return null;
  try {
    return DateTime.fromMillisecondsSinceEpoch(number.toInt() * 1000, isUtc: true);
  } catch (_) { return null; }
}

String? _optionalMetadataText(Object? value, String field) {
  if (value == null) return null;
  if (value is! String) throw FormatException('Yahoo $field 元資料必須為字串。');
  final text = value.trim();
  return text.isEmpty ? null : text;
}

bool _yahooTimeZonesInitialized = false;

int _marketUtcOffset(String timezone, DateTime at) {
  if (!_yahooTimeZonesInitialized) {
    timezone_data.initializeTimeZones();
    _yahooTimeZonesInitialized = true;
  }
  return tz.TZDateTime.from(at.toUtc(), tz.getLocation(timezone))
      .timeZoneOffset.inSeconds;
}
