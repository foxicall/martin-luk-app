import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/market_data.dart';
import '../models/stock_candidate.dart';

class MarketDataException implements Exception {
  const MarketDataException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Yahoo 行情服務。
///
/// HTTP、取消、限流、重試與快取皆位於本檔案。
/// 連線失敗不會替換為 Mock 行情。
class MarketDataApi {
  MarketDataApi({
    http.Client? client,
    SharedPreferences? preferences,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.requestTimeout = defaultTimeout,
    this.storageTimeout = defaultStorageTimeout,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _preferences = preferences,
       _preferencesLoader =
           preferencesLoader ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > defaultTimeout) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'HTTP 逾時必須大於零且不得超過 8 秒。',
      );
    }

    if (storageTimeout <= Duration.zero ||
        storageTimeout > defaultStorageTimeout) {
      throw ArgumentError.value(
        storageTimeout,
        'storageTimeout',
        '本機快取等待必須大於零且不得超過 2 秒。',
      );
    }
  }

  static const Duration defaultTimeout = Duration(seconds: 8);
  static const Duration defaultStorageTimeout = Duration(seconds: 2);
  static const int maximumConcurrentRequests = 5;

  // 所有行情服務實例共用名額，包括推薦與持股行情。
  static final _requestSlots = _YahooRequestSlots(
    maximumConcurrentRequests,
  );

  final http.Client _client;
  final bool _ownsClient;
  final Set<_YahooPendingRequest> _activeRequests = {};

  SharedPreferences? _preferences;
  Future<SharedPreferences?>? _preferencesFuture;

  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final Duration requestTimeout;
  final Duration storageTimeout;

  final Map<String, _CachedChart> _memoryCache = {};
  final Map<String, Future<MarketChart>> _pending = {};

  DateTime? _rateLimitedUntil;
  bool _closed = false;

  static const _prefix = 'market-data-yahoo-v1:';

  Future<MarketChart> fetchDaily(
    String symbol,
    StockMarket market, {
    bool forceRefresh = false,
  }) =>
      _fetch(
        symbol,
        market,
        interval: '1d',
        range: '6mo',
        forceRefresh: forceRefresh,
      );

  Future<MarketChart> fetchIntraday(
    String symbol,
    StockMarket market, {
    bool forceRefresh = false,
    String interval = '5m',
  }) {
    if (!['1m', '5m'].contains(interval)) {
      throw ArgumentError.value(
        interval,
        'interval',
        '僅支援 1m 或 5m。',
      );
    }

    return _fetch(
      symbol,
      market,
      interval: interval,
      range: '5d',
      forceRefresh: forceRefresh,
    );
  }

  Future<MarketChart> fetchBenchmark(
    StockMarket market, {
    bool forceRefresh = false,
  }) =>
      fetchDaily(
        market == StockMarket.tw ? '^TWII' : '^GSPC',
        market,
        forceRefresh: forceRefresh,
      );

  /// 分鐘行情失敗時保留日 K，但明確傳遞錯誤。
  /// 缺少分鐘資料時，策略不得虛構開盤突破訊號。
  Future<ChartBundle> fetchBundle(
    String symbol,
    StockMarket market, {
    bool forceRefresh = false,
    bool includeIntraday = true,
  }) async {
    final daily = await fetchDaily(
      symbol,
      market,
      forceRefresh: forceRefresh,
    );

    if (!includeIntraday) {
      return ChartBundle(daily: daily);
    }

    try {
      final intraday = await fetchIntraday(
        symbol,
        market,
        forceRefresh: forceRefresh,
      );

      return ChartBundle(
        daily: daily,
        intraday: intraday,
      );
    } catch (error) {
      return ChartBundle(
        daily: daily,
        intradayError: error.toString(),
      );
    }
  }

  Future<MarketChart> _fetch(
    String symbol,
    StockMarket market, {
    required String interval,
    required String range,
    required bool forceRefresh,
  }) async {
    if (_closed) {
      throw StateError('行情服務已關閉。');
    }

    final canonical = canonicalSymbol(symbol, market);
    final key = '${market.name}:$canonical:$interval:$range';

    // 相同股票與週期共用進行中的請求。
    // 在等待快取之前取得同步槽，避免儲存服務卡住時重複請求。
    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    final future = _loadAndRequest(
      canonical,
      market,
      interval,
      range,
      key,
      forceRefresh: forceRefresh,
    );

    _pending[key] = future;

    try {
      return await future;
    } finally {
      // 遲到的舊操作不能清除新操作的同步槽。
      if (identical(_pending[key], future)) {
        _pending.remove(key);
      }
    }
  }

  Future<MarketChart> _loadAndRequest(
    String canonical,
    StockMarket market,
    String interval,
    String range,
    String key, {
    required bool forceRefresh,
  }) async {
    final cached = await _readCache(key);

    if (_closed) {
      throw StateError('行情服務已關閉。');
    }

    final ttl = interval == '1d'
        ? const Duration(minutes: 15)
        : const Duration(seconds: 30);

    final age = cached == null
        ? null
        : _now().toUtc().difference(cached.fetchedAt);

    if (!forceRefresh &&
        cached != null &&
        age != null &&
        !age.isNegative &&
        age <= ttl) {
      try {
        return _parse(
          cached.json,
          symbol: canonical,
          market: market,
          interval: interval,
          fetchedAt: cached.fetchedAt,
          isCached: true,
        );
      } on FormatException {
        await _removeCache(key);
      }
    }

    return _request(
      canonical,
      market,
      interval,
      range,
      key,
      cached,
    );
  }

  Future<MarketChart> _request(
    String symbol,
    StockMarket market,
    String interval,
    String range,
    String key,
    _CachedChart? cached,
  ) async {
    try {
      if (_rateLimitedUntil != null &&
          _now().toUtc().isBefore(_rateLimitedUntil!)) {
        throw MarketDataException(
          'Yahoo 暫時限制請求，請於 '
          '${_rateLimitedUntil!.toIso8601String()} 後重試。',
          statusCode: 429,
        );
      }

      final uri = Uri.https(
        'query1.finance.yahoo.com',
        '/v8/finance/chart/$symbol',
        {
          'interval': interval,
          'range': range,
          'includePrePost': 'true',
          'events': 'div,splits',
        },
      );

      // 明確非空：方法只會回傳 Response 或拋出例外。
      final http.Response received = await _getWithRetry(uri);

      if (received.statusCode != 200) {
        throw MarketDataException(
          received.statusCode == 429
              ? 'Yahoo 行情請求過於頻繁（HTTP 429），請稍後重試。'
              : 'Yahoo 行情 HTTP ${received.statusCode}，請稍後重試。',
          statusCode: received.statusCode,
        );
      }

      final decoded = jsonDecode(
        utf8.decode(received.bodyBytes),
      );

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Yahoo 行情必須為 JSON 物件。',
        );
      }

      final fetchedAt = _now().toUtc();

      final chart = _parse(
        decoded,
        symbol: symbol,
        market: market,
        interval: interval,
        fetchedAt: fetchedAt,
      );

      if (_closed) {
        throw StateError('行情服務已關閉。');
      }

      await _saveCache(
        key,
        _CachedChart(decoded, fetchedAt),
      );

      return chart;
    } catch (error) {
      // 捕獲逾時、ClientException 與原生 SocketException。
      // 真實快取保留原始時間，並標記過期。
      if (cached != null) {
        try {
          return _parse(
            cached.json,
            symbol: symbol,
            market: market,
            interval: interval,
            fetchedAt: cached.fetchedAt,
            isCached: true,
            isStale: true,
            cacheWarning: '更新失敗，顯示上次真實行情快取：$error',
          );
        } on FormatException {
          await _removeCache(key);
        }
      }

      if (error is MarketDataException) {
        rethrow;
      }

      if (error is TimeoutException) {
        throw const MarketDataException(
          'Yahoo 行情連線逾時，請下拉重試。',
        );
      }

      if (error is http.ClientException) {
        throw MarketDataException(
          '無法連線 Yahoo 行情，請檢查網路後重試：${error.message}',
        );
      }

      // 不引用 dart:io，維持 Flutter Web 相容。
      throw MarketDataException(
        'Yahoo 行情解析或連線失敗：$error',
      );
    }
  }

  Future<http.Response> _getWithRetry(Uri uri) async {
    // 排隊、下載本文、429 等待與重試共用同一網路期限。
    final elapsed = Stopwatch()..start();

    for (var attempt = 0; attempt < 2; attempt++) {
      final remaining = requestTimeout - elapsed.elapsed;

      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Yahoo 重試超過請求期限。',
          requestTimeout,
        );
      }

      // 每次回應使用不可為空的區域變數。
      final http.Response response = await _sendWithTimeout(
        uri,
        remaining,
      );

      if (response.statusCode != 429) {
        return response;
      }

      final String? header = response.headers['retry-after'];
      final wait =
          int.tryParse(header ?? '') ?? (header == null ? 1 : 30);

      // 長 Retry-After 不阻塞 UI，也不繼續轟炸供應商。
      if (attempt == 1 || wait > 3) {
        _rateLimitedUntil = _now().toUtc().add(
          Duration(
            seconds: math.max(1, math.min(wait, 300)),
          ),
        );

        return response;
      }

      final delayBudget = requestTimeout - elapsed.elapsed;

      if (delayBudget <= Duration.zero) {
        throw TimeoutException(
          'Yahoo 重試超過請求期限。',
          requestTimeout,
        );
      }

      await _delay(
        Duration(seconds: math.max(1, wait)),
      ).timeout(delayBudget);

      if (_closed) {
        throw StateError('行情服務已關閉。');
      }
    }

    throw const MarketDataException(
      'Yahoo 行情重試次數已達上限。',
    );
  }

  Future<http.Response> _sendWithTimeout(
    Uri uri,
    Duration timeout,
  ) async {
    if (_closed) {
      throw StateError('行情服務已關閉。');
    }

    final pending = _YahooPendingRequest(
      _requestSlots.acquire(),
    );

    _activeRequests.add(pending);
    var succeeded = false;

    try {
      // 期限包含等待名額、連線、標頭及完整回應本文。
      final http.Response response =
          await Future.any<http.Response>([
        _sendWhenReady(uri, pending),
        pending.abort.future.then<http.Response>(
          (_) => throw http.RequestAbortedException(uri),
        ),
      ]).timeout(
        timeout,
        onTimeout: () {
          pending.cancel();

          throw TimeoutException(
            'Yahoo HTTP 請求超過期限。',
            timeout,
          );
        },
      );

      if (_closed) {
        throw StateError('行情服務已關閉。');
      }

      succeeded = true;
      return response;
    } finally {
      _activeRequests.remove(pending);

      if (!succeeded) {
        pending.cancel();
      }

      pending.slot.release();
    }
  }

  Future<http.Response> _sendWhenReady(
    Uri uri,
    _YahooPendingRequest pending,
  ) async {
    await pending.slot.ready;

    if (_closed ||
        pending.abort.isCompleted ||
        !pending.slot.isActive) {
      throw http.RequestAbortedException(uri);
    }

    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: pending.abort.future,
    );

    request.headers['Accept'] = 'application/json';

    // Response.fromStream 會等待完整本文，納入外層 timeout。
    return _client.send(request).then<http.Response>(
      http.Response.fromStream,
    );
  }

  MarketChart _parse(
    Map<String, dynamic> document, {
    required String symbol,
    required StockMarket market,
    required String interval,
    required DateTime fetchedAt,
    bool isCached = false,
    bool isStale = false,
    String? cacheWarning,
  }) {
    final chart = document['chart'];

    if (chart is! Map<String, dynamic> ||
        chart['error'] != null) {
      throw const FormatException(
        'Yahoo 未提供有效行情，可能代碼不存在或供應商拒絕請求。',
      );
    }

    final result = chart['result'];

    if (result is! List ||
        result.length != 1 ||
        result.first is! Map<String, dynamic>) {
      throw const FormatException(
        'Yahoo chart result 格式無效。',
      );
    }

    final row = result.first as Map<String, dynamic>;
    final meta = row['meta'];

    if (meta is! Map<String, dynamic> ||
        meta['symbol'] is! String ||
        canonicalSymbol(meta['symbol'] as String, market) != symbol ||
        meta['currency'] != market.currency ||
        meta['exchangeTimezoneName'] !=
            (market == StockMarket.tw
                ? 'Asia/Taipei'
                : 'America/New_York') ||
        meta['gmtoffset'] is! num ||
        !(meta['gmtoffset'] as num).toDouble().isFinite) {
      throw const FormatException(
        'Yahoo 股票代碼、幣別或交易所時區與要求不一致。',
      );
    }

    final timestamps = row['timestamp'];
    final indicators = row['indicators'];

    if (timestamps is! List ||
        indicators is! Map<String, dynamic> ||
        indicators['quote'] is! List ||
        (indicators['quote'] as List).isEmpty ||
        (indicators['quote'] as List).first
            is! Map<String, dynamic>) {
      throw const FormatException(
        'Yahoo OHLCV 或 K 棒時間缺漏。',
      );
    }

    final values =
        (indicators['quote'] as List).first as Map<String, dynamic>;

    for (final column in ['open', 'high', 'low', 'close', 'volume']) {
      if (values[column] is! List ||
          (values[column] as List).length != timestamps.length) {
        throw FormatException(
          'Yahoo $column 與時間陣列長度不一致。',
        );
      }
    }

    final duration = switch (interval) {
      '1m' => const Duration(minutes: 1),
      '5m' => const Duration(minutes: 5),
      _ => const Duration(days: 1),
    };

    final bars = <PriceBar>[];

    for (var index = 0; index < timestamps.length; index++) {
      final time = _timestamp(timestamps[index]);
      final open = _positive((values['open'] as List)[index]);
      final high = _positive((values['high'] as List)[index]);
      final low = _positive((values['low'] as List)[index]);
      final close = _positive((values['close'] as List)[index]);
      final volume = (values['volume'] as List)[index];

      // 缺漏 K 棒不填成零，也不以前值補成假行情。
      if (time == null ||
          open == null ||
          high == null ||
          low == null ||
          close == null ||
          volume is! num ||
          !volume.toDouble().isFinite ||
          volume < 0 ||
          high < math.max(open, close) ||
          low > math.min(open, close) ||
          time.isAfter(fetchedAt)) {
        continue;
      }

      if (bars.isNotEmpty &&
          !time.isAfter(bars.last.timestamp)) {
        throw const FormatException(
          'Yahoo K 棒時間重複或倒序。',
        );
      }

      bars.add(
        PriceBar(
          timestamp: time,
          open: open,
          high: high,
          low: low,
          close: close,
          volume: volume.toDouble(),
          interval: duration,
        ),
      );
    }

    if (bars.isEmpty) {
      throw const FormatException(
        'Yahoo 沒有可驗證的 OHLCV K 棒。',
      );
    }

    var price = _positive(meta['regularMarketPrice']);
    var quoteTime = _timestamp(meta['regularMarketTime']);

    for (final prefix in ['preMarket', 'postMarket']) {
      final alternativePrice = _positive(meta['${prefix}Price']);
      final alternativeTime = _timestamp(meta['${prefix}Time']);

      if (alternativePrice != null &&
          alternativeTime != null &&
          (quoteTime == null ||
              alternativeTime.isAfter(quoteTime))) {
        price = alternativePrice;
        quoteTime = alternativeTime;
      }
    }

    if (interval != '1d' &&
        (quoteTime == null ||
            bars.last.timestamp.isAfter(quoteTime))) {
      price = bars.last.close;
      quoteTime = bars.last.timestamp;
    }

    if (price == null ||
        quoteTime == null ||
        quoteTime.isAfter(
          fetchedAt.add(const Duration(minutes: 1)),
        )) {
      throw const FormatException(
        'Yahoo 缺少可驗證的市價或報價時間。',
      );
    }

    DateTime? sessionStart;
    DateTime? sessionEnd;

    final periods = meta['currentTradingPeriod'];

    if (periods is Map<String, dynamic> &&
        periods['regular'] is Map<String, dynamic>) {
      final regular = periods['regular'] as Map<String, dynamic>;

      sessionStart = _timestamp(regular['start']);
      sessionEnd = _timestamp(regular['end']);

      if (sessionStart == null ||
          sessionEnd == null ||
          !sessionEnd.isAfter(sessionStart)) {
        throw const FormatException(
          'Yahoo 常規交易時段格式無效。',
        );
      }
    }

    return MarketChart(
      symbol: symbol,
      market: market,
      currency: meta['currency'] as String,
      exchangeTimezoneName: meta['exchangeTimezoneName'] as String,
      gmtoffset: (meta['gmtoffset'] as num).toInt(),
      bars: bars,
      latestPrice: price,
      quoteTimestamp: quoteTime,
      fetchedAt: fetchedAt,
      interval: interval,
      regularSessionStart: sessionStart,
      regularSessionEnd: sessionEnd,
      isCached: isCached,
      isStale: isStale,
      cacheWarning: cacheWarning,
      source: isCached
          ? 'Yahoo Finance 真實行情本機快取（可能延遲）'
          : 'Yahoo Finance 公開行情（可能延遲，不保證即時）',
    );
  }

  Future<SharedPreferences?> _getPreferences() async {
    if (_preferences != null) {
      return _preferences;
    }

    final pending = _preferencesFuture;

    if (pending != null) {
      return pending;
    }

    final operation = () async {
      try {
        final preferences =
            await _preferencesLoader().timeout(storageTimeout);

        if (!_closed) {
          _preferences = preferences;
        }

        return preferences;
      } catch (_) {
        // 儲存不可用時仍可使用 HTTP 與記憶體快取。
        return null;
      }
    }();

    _preferencesFuture = operation;

    try {
      return await operation;
    } finally {
      if (identical(_preferencesFuture, operation)) {
        _preferencesFuture = null;
      }
    }
  }

  Future<_CachedChart?> _readCache(String key) async {
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }

    final preferences = await _getPreferences();

    try {
      final raw = preferences?.getString('$_prefix$key');

      if (raw == null) {
        return null;
      }

      final row = jsonDecode(raw);

      if (row is! Map<String, dynamic> ||
          row['document'] is! Map<String, dynamic> ||
          row['fetched_at'] is! String) {
        throw const FormatException('快取格式無效。');
      }

      final time = DateTime.parse(
        row['fetched_at'] as String,
      ).toUtc();

      final cache = _CachedChart(
        row['document'] as Map<String, dynamic>,
        time,
      );

      _memoryCache[key] = cache;
      return cache;
    } catch (_) {
      try {
        await preferences
            ?.remove('$_prefix$key')
            .timeout(storageTimeout);
      } catch (_) {
        // 快取刪除失敗不阻塞新行情。
      }

      return null;
    }
  }

  Future<void> _saveCache(
    String key,
    _CachedChart chart,
  ) async {
    _memoryCache[key] = chart;

    if (_memoryCache.length > 96) {
      _memoryCache.remove(_memoryCache.keys.first);
    }

    try {
      final preferences = await _getPreferences();

      await preferences
          ?.setString(
            '$_prefix$key',
            jsonEncode({
              'fetched_at': chart.fetchedAt.toIso8601String(),
              'document': chart.json,
            }),
          )
          .timeout(storageTimeout);
    } catch (_) {
      // 寫入快取失敗不丟棄已成功取得的行情。
    }
  }

  Future<void> _removeCache(String key) async {
    _memoryCache.remove(key);

    try {
      await (await _getPreferences())
          ?.remove('$_prefix$key')
          .timeout(storageTimeout);
    } catch (_) {
      // 最佳努力清理。
    }
  }

  void close() {
    if (_closed) {
      return;
    }

    _closed = true;

    for (final pending in _activeRequests) {
      pending.cancel();
    }

    _activeRequests.clear();

    // 外部注入的 Client 由呼叫者管理。
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// 本檔案私有的請求取消狀態。
class _YahooPendingRequest {
  _YahooPendingRequest(this.slot);

  final _YahooRequestSlot slot;
  final abort = Completer<void>();

  void cancel() {
    if (!abort.isCompleted) {
      abort.complete();
    }

    slot.release();
  }
}

/// FIFO 名額池，取消時立即移除等待項目。
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
    if (slot._released) {
      return;
    }

    slot._released = true;

    if (slot._granted) {
      _used--;
    } else {
      _queue.remove(slot);
    }

    // 喚醒已取消的等待者；它不會再送出 HTTP。
    if (!slot._ready.isCompleted) {
      slot._ready.complete();
    }

    _drain();
  }

  void _drain() {
    while (_used < limit && _queue.isNotEmpty) {
      final slot = _queue.removeFirst();

      if (slot._released) {
        continue;
      }

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

  void release() {
    _pool._release(this);
  }
}

class _CachedChart {
  const _CachedChart(this.json, this.fetchedAt);

  final Map<String, dynamic> json;
  final DateTime fetchedAt;
}

/// 正規化 Yahoo 美股類別股及台股 .TW 代碼。
String canonicalSymbol(String raw, StockMarket market) {
  var symbol = raw.trim().toUpperCase();

  if (market == StockMarket.tw) {
    if (symbol == '^TWII') {
      return symbol;
    }

    if (RegExp(r'^\d{4}$').hasMatch(symbol)) {
      symbol = '$symbol.TW';
    }

    if (!RegExp(r'^\d{4}\.TW$').hasMatch(symbol)) {
      throw FormatException(
        '台股行情僅接受四位上市股票代碼與 .TW：$raw',
      );
    }
  } else {
    if (symbol == '^GSPC') {
      return symbol;
    }

    symbol = symbol.replaceAll('.', '-');

    if (!RegExp(r'^[A-Z][A-Z0-9-]{0,14}$').hasMatch(symbol)) {
      throw FormatException('美股代碼格式無效：$raw');
    }
  }

  return symbol;
}

double? _positive(Object? value) =>
    value is num && value.toDouble().isFinite && value > 0
        ? value.toDouble()
        : null;

DateTime? _timestamp(Object? value) {
  if (value is! num ||
      !value.toDouble().isFinite ||
      value <= 0 ||
      value != value.toInt()) {
    return null;
  }

  try {
    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt() * 1000,
      isUtc: true,
    );
  } catch (_) {
    return null;
  }
}