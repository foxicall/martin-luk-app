import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'network_request.dart';
import 'tw_issuer_csv.dart';
import 'us_stock_directory.dart';

typedef DateTimeFunction = DateTime Function();

/// A universe is metadata, not market prices or a recommendation. A partial
/// local dictionary must never be presented as the latest full constituent list.
class UniverseSnapshot {
  UniverseSnapshot({
    required List<StockItem> stocks,
    required this.asOf,
    required this.source,
    required this.isComplete,
    List<String> warnings = const [],
    this.isCached = false,
    this.retrievedAt,
  }) : stocks = List.unmodifiable(stocks),
       warnings = List.unmodifiable(warnings);

  final List<StockItem> stocks;
  final DateTime asOf;
  final String source;
  final bool isComplete;
  final List<String> warnings;
  final bool isCached;

  /// Retrieval time is distinct from the source file date.
  final DateTime? retrievedAt;

  int get totalCount => stocks.length;
}

/// Two bounded requests load exchange metadata, while alias/name lookups reuse
/// the bundled master dictionary. No metadata HTTP is sent per search keystroke.
///
/// This service fetches public HTTPS endpoints without an API secret. These
/// endpoints may change, reject requests or lack browser CORS permission; a
/// failure produces a clearly identified real metadata cache, never fake data.
class StockUniverseService {
  StockUniverseService({
    http.Client? client,
    SharedPreferences? preferences,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTimeFunction? now,
    this.useUsMirrorFallback = true,
    this.useTwCsvFallback = true,
    this.requestTimeout = NetworkRequest.defaultTimeout,
    this.storageTimeout = NetworkRequest.defaultStorageTimeout,
  }) : _network = NetworkRequest(
         client: client,
         timeout: requestTimeout,
         acceptedContentTypes:
             'text/plain,text/csv;q=0.95,application/json;q=0.9,*/*;q=0.8',
       ),
       _preferences = preferences,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now {
    if (storageTimeout <= Duration.zero ||
        storageTimeout > NetworkRequest.storageTimeout) {
      throw ArgumentError.value(
        storageTimeout,
        'storageTimeout',
        '本機快取等待必須大於零且不得超過 5 秒。',
      );
    }
  }

  static final Uri usEndpoint = Uri.parse(
    'https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt',
  );
  static final Uri usOtherEndpoint = Uri.parse(
    'https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt',
  );
  static final Uri twEndpoint = Uri.parse(
    'https://openapi.twse.com.tw/v1/opendata/t187ap03_L',
  );
  static final Uri twOtcEndpoint = Uri.parse(
    'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O',
  );
  // The official issuer CSVs are published on a separate TWSE host. They are
  // metadata backups, not third-party membership mirrors or price feeds.
  static final Uri twCsvEndpoint = Uri.parse(
    'https://mopsfin.twse.com.tw/opendata/t187ap03_L.csv',
  );
  static final Uri twOtcCsvEndpoint = Uri.parse(
    'https://mopsfin.twse.com.tw/opendata/t187ap03_O.csv',
  );
  // Public copies of the exchange directories, not price feeds. Their file
  // dates are checked before use; unavailable/stale mirrors never become a
  // successful official source or replace a quote with demonstration data.
  static final Uri usMirrorEndpoint = Uri.parse(
    'https://raw.githubusercontent.com/Cperkin/CanadianStats/main/data/sources/nasdaqlisted.txt',
  );
  static final Uri usOtherMirrorEndpoint = Uri.parse(
    'https://raw.githubusercontent.com/Cperkin/CanadianStats/main/data/sources/otherlisted.txt',
  );
  static const Duration maximumMirrorAge = Duration(days: 7);
  final bool useUsMirrorFallback;
  final bool useTwCsvFallback;
  static const Duration cacheLifetime = Duration(hours: 24);
  static const Duration maximumStaleAge = Duration(days: 30);
  final Duration requestTimeout;
  final Duration storageTimeout;
  final NetworkRequest _network;
  final DateTimeFunction _now;
  SharedPreferences? _preferences;
  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<Map<String, StockItem>>? _master;
  final Map<StockMarket, Future<UniverseSnapshot>> _inFlight = {};
  // Keep each exchange independently. A TPEx-only reply must not erase the
  // latest usable TWSE membership (or renew its original retrieval date).
  final Map<String, _TwSourceCache> _twSources = {};
  bool _closed = false;

  static String cacheKey(StockMarket market) =>
      'martin_luk.universe.v3.directory.${market.name}';

  Future<UniverseSnapshot> load(
    StockMarket market, {
    bool forceRefresh = false,
  }) async {
    if (_closed) throw StateError('股票池服務已關閉。');
    final pending = _inFlight[market];
    if (pending != null) return pending;
    final operation = _load(market, forceRefresh: forceRefresh);
    _inFlight[market] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[market], operation)) _inFlight.remove(market);
    }
  }

  Future<UniverseSnapshot> _load(
    StockMarket market, {
    required bool forceRefresh,
  }) async {
    final now = _now().toUtc();
    final warnings = <String>[];
    final preferences = await _getPreferences(warnings);
    if (_closed) throw StateError('股票池服務已關閉。');
    final cached = _readCache(preferences, market, now, warnings);
    if (market == StockMarket.tw) {
      _readTwSources(preferences, cached, now, warnings);
    }
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.retrievedAt ?? cached.asOf) <=
            (cached.isComplete ? cacheLifetime : const Duration(minutes: 5))) {
      return _cachedCopy(cached, warnings);
    }

    // A missing alias asset does not prevent live universe retrieval. Missing
    // aliases only affect bilingual display and can be retried on another load.
    Map<String, StockItem> master = const {};
    try {
      master = await (_master ??= _loadMaster()).timeout(storageTimeout);
    } catch (_) {
      _master = null;
      warnings.add('本機中文別名字典無法讀取；連網清單仍使用資料源名稱。');
    }

    if (_closed) throw StateError('股票池服務已關閉。');
    try {
      // Two independent exchange feeds. Each US feed may use one dated
      // public mirror within the SAME request budget, never a second 8s wait.
      final endpoints =
          market == StockMarket.us
              ? [usEndpoint, usOtherEndpoint]
              : [twEndpoint, twOtcEndpoint];
      final requestBudget =
          requestTimeout < NetworkRequest.defaultTimeout
              ? requestTimeout
              : NetworkRequest.defaultTimeout;
      var replies = await Future.wait(
        endpoints.asMap().entries.map((entry) {
          if (market == StockMarket.us) {
            return _loadUsSource(
              entry.value,
              nasdaq: entry.key == 0,
              master: master,
              budget: requestBudget,
              now: now,
            );
          }
          return _loadTwSource(
            entry.value,
            otc: entry.key == 1,
            master: master,
            budget: requestBudget,
            now: now,
          );
        }),
      );
      if (_closed) throw StateError('股票池服務已關閉。');
      if (market == StockMarket.tw) {
        replies = _retainTwSources(replies, now, master);
      }
      final successful =
          replies.where((reply) => reply.success && !reply.fromCache).length;
      final bySymbol = <String, StockItem>{};
      for (final reply in replies) {
        warnings.addAll(reply.warnings);
        for (final stock in reply.stocks) {
          if (bySymbol.containsKey(stock.symbol)) {
            warnings.add('資料源含重複代碼 ${stock.symbol}；保留第一筆。');
          } else {
            bySymbol[stock.symbol] = stock;
          }
        }
      }
      if (bySymbol.isEmpty) {
        throw const FormatException('兩個股票池資料源都沒有可用普通股。');
      }
      final stocks =
          bySymbol.values.toList()
            ..sort((a, b) => a.symbol.compareTo(b.symbol));
      final complete =
          successful == 2 &&
          replies.every((reply) => reply.isComplete) &&
          (market == StockMarket.us
              ? stocks.length >= 2500 && stocks.length <= 15000
              : stocks.length >= 1500 && stocks.length <= 3500);
      if (!complete) {
        warnings.add(
          '已取得 $successful/2 個交易所清單、${stocks.length} 檔可確認普通股；全市場覆蓋不足，請查看來源與排除提示。',
        );
      }
      if (market == StockMarket.us) {
        warnings.add('美股目錄沒有完整 CFI；以普通股名稱保守分類，未能確認的證券已排除，非百分之百分類認證。');
      }
      if (market == StockMarket.tw) {
        warnings.add(
          '台股使用官方上市／上櫃發行公司清單，並保守排除91開頭存託憑證及非四碼證券；此為啟發式分類，未逐筆取得證券 CFI 認證。',
        );
      }
      final sourceDates =
          replies
              .where((reply) => reply.stocks.isNotEmpty)
              .map((reply) => reply.fileDate)
              .whereType<DateTime>()
              .toList();
      final asOf =
          sourceDates.isEmpty
              ? now
              : sourceDates.reduce((a, b) => a.isBefore(b) ? a : b);
      final mirrored = replies.any((reply) => reply.mirrored);
      final snapshot = UniverseSnapshot(
        stocks: stocks,
        asOf: asOf,
        retrievedAt: now,
        source:
            market == StockMarket.us
                ? 'Nasdaq Trader symbol directories: Nasdaq / NYSE / NYSE American common stocks'
                    '${mirrored ? ' / dated public mirror (partial)' : ''}'
                : 'TWSE / TPEx official ordinary-stock issuers'
                    '${replies.any((reply) => reply.fromCache) ? ' / cached or bundled exchange metadata (partial)' : ''}',
        isComplete: complete,
        isCached: replies.any((reply) => reply.fromCache),
        warnings: warnings,
      );
      if (_closed) throw StateError('股票池服務已關閉。');
      if (preferences != null) {
        try {
          final written = await preferences
              .setString(
                cacheKey(market),
                jsonEncode(
                  _encode(
                    snapshot,
                    market,
                    twSources: market == StockMarket.tw ? _twSources : null,
                  ),
                ),
              )
              .timeout(storageTimeout);
          if (_closed) throw StateError('股票池服務已關閉。');
          if (!written) throw StateError('快取儲存失敗。');
        } catch (_) {
          if (_closed) rethrow;
          return UniverseSnapshot(
            stocks: snapshot.stocks,
            asOf: snapshot.asOf,
            retrievedAt: snapshot.retrievedAt,
            source: snapshot.source,
            isComplete: snapshot.isComplete,
            isCached: snapshot.isCached,
            warnings: [...snapshot.warnings, '最新股票池已取得，但無法儲存本機快取。'],
          );
        }
      }
      return snapshot;
    } catch (error, stack) {
      if (_closed) {
        // Closing aborts transport work with RequestAbortedException. Expose
        // this service's lifecycle contract on the shared _load future, so both
        // its original caller and coalesced callers receive the same error.
        // Do not turn disposal into a cached/bundled successful result.
        Error.throwWithStackTrace(StateError('股票池服務已關閉。'), stack);
      }
      warnings.add('股票池更新失敗（${_errorLabel(error)}）；沒有使用示範行情。');
      if (cached != null) {
        warnings.add('使用 ${cached.asOf.toIso8601String()} 的股票池快取，成分可能已變更。');
        return _cachedCopy(cached, warnings);
      }
      final fallback =
          master.values.where((item) => item.market == market).toList()
            ..sort((a, b) => a.symbol.compareTo(b.symbol));
      if (fallback.isEmpty) {
        throw StateError('無法取得股票池，且沒有可用本機元資料；請連網後重試。');
      }
      return UniverseSnapshot(
        stocks: fallback,
        // Build-time dictionary date is intentionally distinct from retrieval
        // time: opening the app does not refresh constituent membership.
        asOf: DateTime.utc(2026, 10, 6),
        source:
            'bundled stock metadata dictionary (partial, unverified membership)',
        isComplete: false,
        isCached: true,
        warnings: [
          ...warnings,
          '僅使用內建 ${fallback.length} 檔搜尋字典；它不是目前完整台股上市櫃／美股三大交易所股票池，成分日期未驗證。',
        ],
      );
    }
  }

  Future<SharedPreferences?> _getPreferences(List<String> warnings) async {
    try {
      return _preferences ??= await _preferencesLoader().timeout(
        storageTimeout,
      );
    } catch (_) {
      warnings.add('本機儲存不可用，股票池快取暫停。');
      return null;
    }
  }

  UniverseSnapshot? _readCache(
    SharedPreferences? preferences,
    StockMarket market,
    DateTime now,
    List<String> warnings,
  ) {
    if (preferences == null) return null;
    try {
      final raw = preferences.getString(cacheKey(market));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 3 ||
          decoded['scope'] != 'all_common' ||
          decoded['market'] != market.name ||
          decoded['source'] is! String ||
          decoded['is_complete'] is! bool ||
          decoded['stocks'] is! List) {
        throw const FormatException('股票池快取結構無效。');
      }
      final asOf = parseApiTimestamp(decoded['as_of'], 'as_of');
      final retrievedAt =
          decoded['retrieved_at'] == null
              ? asOf
              : parseApiTimestamp(decoded['retrieved_at'], 'retrieved_at');
      if (retrievedAt.isAfter(now) || retrievedAt.isBefore(asOf)) {
        throw const FormatException('股票池取得時間與來源日期不一致。');
      }
      final seen = <String>{};
      final stocks =
          (decoded['stocks'] as List).map((row) {
            if (row is! Map<String, dynamic>) {
              throw const FormatException('股票池快取紀錄無效。');
            }
            final stock = StockItem.fromJson(row);
            if (stock.market != market || !seen.add(stock.key)) {
              throw const FormatException('股票池快取含跨市場或重複紀錄。');
            }
            return stock;
          }).toList();
      if (stocks.isEmpty) throw const FormatException('股票池快取不得為空。');
      final twExchangeSources = decoded['tw_exchange_sources'];
      if (market == StockMarket.tw && twExchangeSources != null) {
        _validateTwAggregateCache(
          twExchangeSources,
          stocks: stocks,
          asOf: asOf,
          retrievedAt: retrievedAt,
          now: now,
          source: decoded['source'] as String,
        );
      } else {
        // Legacy JSON-only metadata and US caches retain the original strict
        // 30-day rule. A monthly CSV exception requires validated, matching
        // per-exchange provenance; it is never inferred from aggregate age.
        final age = now.difference(asOf);
        if (age.isNegative || age > maximumStaleAge) {
          warnings.add('股票池快取日期無效或已超過 30 天；不以它當作現行成分。');
          return null;
        }
      }
      final storedWarnings = decoded['warnings'];
      if (storedWarnings is! List ||
          storedWarnings.any((entry) => entry is! String)) {
        throw const FormatException('股票池快取提示無效。');
      }
      return UniverseSnapshot(
        stocks: stocks,
        asOf: asOf,
        retrievedAt: retrievedAt,
        source: decoded['source'] as String,
        isComplete: decoded['is_complete'] as bool,
        warnings: storedWarnings.cast<String>(),
        isCached: true,
      );
    } catch (_) {
      warnings.add('股票池快取未通過來源、日期或格式檢查；重新取得連網清單。');
      return null;
    }
  }

  static void _validateTwAggregateCache(
    Object field, {
    required List<StockItem> stocks,
    required DateTime asOf,
    required DateTime retrievedAt,
    required DateTime now,
    required String source,
  }) {
    if (field is! Map<String, dynamic> ||
        field['version'] != 1 ||
        field['sources'] is! Map<String, dynamic> ||
        !const [
          'TWSE / TPEx official ordinary-stock issuers',
          'TWSE / TPEx official ordinary-stock issuers / cached or bundled exchange metadata (partial)',
        ].contains(source)) {
      throw const FormatException('台股快取缺少可驗證的交易所來源。');
    }
    final rows = field['sources'] as Map<String, dynamic>;
    if (rows.isEmpty ||
        rows.keys.any((key) => key != 'TWSE' && key != 'TPEx')) {
      throw const FormatException('台股快取交易所來源無效。');
    }
    final union = <String, String>{};
    DateTime? oldest;
    for (final exchange in rows.keys) {
      final raw = rows[exchange];
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('台股快取交易所紀錄無效。');
      }
      // Validate each policy on EVERY aggregate-cache read. In particular,
      // TPEx's 7-day CSV may expire within the aggregate's 24-hour TTL.
      final value = _TwSourceCache.fromJson(raw, exchange: exchange, now: now);
      if (value.retrievedAt.isAfter(retrievedAt)) {
        throw const FormatException('台股快取交易所取得時間不一致。');
      }
      if (oldest == null || value.asOf.isBefore(oldest)) oldest = value.asOf;
      for (final stock in value.stocks) {
        if (union.containsKey(stock.symbol)) {
          throw const FormatException('台股快取交易所成分重複。');
        }
        union[stock.symbol] = jsonEncode(stock.toJson());
      }
    }
    if (oldest != asOf ||
        union.length != stocks.length ||
        stocks.any(
          (stock) => union[stock.symbol] != jsonEncode(stock.toJson()),
        )) {
      throw const FormatException('台股快取成分或來源日期與交易所紀錄不一致。');
    }
  }

  static Map<String, dynamic> _encode(
    UniverseSnapshot snapshot,
    StockMarket market, {
    Map<String, _TwSourceCache>? twSources,
  }) => {
    'version': 3,
    'scope': 'all_common',
    'market': market.name,
    'as_of': snapshot.asOf.toUtc().toIso8601String(),
    'retrieved_at':
        (snapshot.retrievedAt ?? snapshot.asOf).toUtc().toIso8601String(),
    'source': snapshot.source,
    'is_complete': snapshot.isComplete,
    'warnings': snapshot.warnings,
    'stocks': snapshot.stocks.map((stock) => stock.toJson()).toList(),
    if (twSources != null)
      'tw_exchange_sources': {
        'version': 1,
        'sources': twSources.map(
          (exchange, value) => MapEntry(exchange, value.toJson()),
        ),
      },
  };

  /// The optional field extends only the TW v3 cache. Existing US and TW cache
  /// readers keep working; old official TW caches can be conservatively split
  /// by their actual .TW/.TWO symbols without inventing exchange membership.
  void _readTwSources(
    SharedPreferences? preferences,
    UniverseSnapshot? cached,
    DateTime now,
    List<String> warnings,
  ) {
    var hasExchangeField = false;
    if (preferences != null) {
      try {
        final raw = preferences.getString(cacheKey(StockMarket.tw));
        final decoded = raw == null ? null : jsonDecode(raw);
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == 3 &&
            decoded['scope'] == 'all_common' &&
            decoded['market'] == 'tw') {
          final exchangeField = decoded['tw_exchange_sources'];
          if (exchangeField != null) {
            hasExchangeField = true;
            if (exchangeField is! Map<String, dynamic> ||
                exchangeField['version'] != 1 ||
                exchangeField['sources'] is! Map<String, dynamic>) {
              throw const FormatException('交易所快取結構無效。');
            }
            final rows = exchangeField['sources'] as Map<String, dynamic>;
            for (final exchange in ['TWSE', 'TPEx']) {
              final value = rows[exchange];
              if (value == null) continue;
              try {
                if (value is! Map<String, dynamic>) {
                  throw const FormatException('交易所快取紀錄無效。');
                }
                final source = _TwSourceCache.fromJson(
                  value,
                  exchange: exchange,
                  now: now,
                );
                final memory = _twSources[exchange];
                if (memory == null ||
                    source.retrievedAt.isAfter(memory.retrievedAt)) {
                  _twSources[exchange] = source;
                }
              } catch (_) {
                final rawAge =
                    value is Map<String, dynamic>
                        ? value['maximum_age_days']
                        : null;
                final limit = const [7, 30, 45].contains(rawAge) ? rawAge : 30;
                warnings.add(
                  '$exchange 交易所快取無效或已超過 $limit 天的來源保存期限'
                  '（JSON 30 天／上市 CSV 45 天／上櫃 CSV 7 天）；'
                  '不將它視為現行成分。',
                );
              }
            }
          }
        }
      } catch (_) {
        warnings.add('台股分交易所快取無法讀取；不推測缺少的成分。');
      }
    }
    _twSources.removeWhere((_, source) => !source.isUsable(now));
    if (hasExchangeField ||
        cached == null ||
        cached.source != 'TWSE / TPEx official ordinary-stock issuers') {
      return;
    }
    // Only migration from the old format: do not overwrite a per-source record
    // with a blended aggregate's timestamp. The minimum aggregate date is safe
    // when the old version did not retain independent exchange provenance.
    for (final exchange in ['TWSE', 'TPEx']) {
      if (_twSources.containsKey(exchange)) continue;
      final suffix = exchange == 'TWSE' ? '.TW' : '.TWO';
      final stocks =
          cached.stocks
              .where((stock) => stock.symbol.endsWith(suffix))
              .toList();
      if (stocks.isEmpty) continue;
      _twSources[exchange] = _TwSourceCache(
        stocks: stocks,
        asOf: cached.asOf,
        retrievedAt: cached.retrievedAt ?? cached.asOf,
      );
    }
  }

  List<_SourceStocks> _retainTwSources(
    List<_SourceStocks> replies,
    DateTime now,
    Map<String, StockItem> master,
  ) {
    return List.generate(2, (index) {
      final exchange = index == 0 ? 'TWSE' : 'TPEx';
      final current = replies[index];
      if (current.success && current.stocks.isNotEmpty) {
        // A successful exchange replaces ONLY that exchange, so removals in a
        // genuinely new source are respected rather than unioned indefinitely.
        _twSources[exchange] = _TwSourceCache(
          stocks: current.stocks,
          asOf: current.fileDate ?? now,
          retrievedAt: now,
          maximumAgeDays: current.metadataMaximumAgeDays,
          metadataFormat: current.metadataFormat,
        );
        return _SourceStocks(
          current.stocks,
          warnings: current.warnings,
          isComplete: current.isComplete,
          fileDate: current.fileDate ?? now,
          metadataMaximumAgeDays: current.metadataMaximumAgeDays,
          metadataFormat: current.metadataFormat,
        );
      }
      final previous = _twSources[exchange];
      if (previous != null && previous.isUsable(now)) {
        return _SourceStocks(
          previous.stocks,
          isComplete: false,
          fromCache: true,
          fileDate: previous.asOf,
          warnings: [
            ...current.warnings,
            '$exchange 更新失敗；沿用最後成功取得的 ${previous.stocks.length} 檔名單'
                '（取得時間 ${previous.retrievedAt.toIso8601String()}）。'
                '本次未刷新該交易所成分，不能視為最新完整名單。',
          ],
        );
      }
      _twSources.remove(exchange);
      final suffix = exchange == 'TWSE' ? '.TW' : '.TWO';
      final bundled =
          master.values
              .where(
                (stock) =>
                    stock.market == StockMarket.tw &&
                    stock.symbol.endsWith(suffix),
              )
              .toList();
      if (bundled.isNotEmpty) {
        // Identity-only fallback, never promoted to last successful exchange
        // metadata. In particular a later TPEx success cannot refresh the date
        // or validation status of a bundled TWSE identity list.
        return _SourceStocks(
          bundled,
          isComplete: false,
          fromCache: true,
          fileDate: DateTime.utc(2026, 10, 6),
          warnings: [
            ...current.warnings,
            '$exchange 無可用的官方名單快取；只為該失敗交易所保留內建 '
                '${bundled.length} 檔股票身份字典（2026-10-06，成分日期未驗證）。'
                '它不是最新完整名單，也不是示範行情。',
          ],
        );
      }
      return current;
    });
  }

  static UniverseSnapshot _cachedCopy(
    UniverseSnapshot snapshot,
    List<String> warnings,
  ) => UniverseSnapshot(
    stocks: snapshot.stocks,
    asOf: snapshot.asOf,
    retrievedAt: snapshot.retrievedAt,
    source: snapshot.source,
    isComplete: snapshot.isComplete,
    isCached: true,
    warnings: {...snapshot.warnings, ...warnings}.toList(),
  );

  static Future<Map<String, StockItem>> _loadMaster() async {
    final decoded = jsonDecode(
      await rootBundle.loadString('stocks_master.json'),
    );
    if (decoded is! List) throw const FormatException('股票字典必須為陣列。');
    final index = <String, StockItem>{};
    for (final row in decoded) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('股票字典紀錄無效。');
      }
      final stock = StockItem.fromJson(row);
      if (index.containsKey(stock.key)) {
        throw const FormatException('股票字典有重複股票。');
      }
      index[stock.key] = stock;
    }
    return index;
  }

  Future<_SourceStocks> _loadUsSource(
    Uri official, {
    required bool nasdaq,
    required Map<String, StockItem> master,
    required Duration budget,
    required DateTime now,
  }) async {
    final elapsed = Stopwatch()..start();
    final warnings = <String>[];
    final label = nasdaq ? 'Nasdaq' : 'NYSE/NYSE American';
    final firstBudget =
        useUsMirrorFallback
            ? Duration(
              microseconds:
                  (budget.inMicroseconds ~/ 2)
                      .clamp(1, budget.inMicroseconds)
                      .toInt(),
            )
            : budget;
    Future<_SourceStocks> read(
      Uri url,
      Duration timeout, {
      required bool mirror,
    }) async {
      if (_closed) throw StateError('股票池服務已關閉。');
      debugPrint('[StockUniverse] >>> $label ${url.host}${url.path}');
      final response = await _network.get(url, timeout: timeout);
      final contentType = response.headers['content-type'] ?? '';
      debugPrint(
        '[StockUniverse] <<< $label HTTP ${response.statusCode} '
        'type=$contentType bytes=${response.bodyBytes.length}',
      );
      if (response.statusCode != 200) {
        throw http.ClientException(
          'HTTP ${response.statusCode}；'
          '${_preview(response.bodyBytes)}',
          url,
        );
      }
      try {
        final parsed = UsStockDirectory.parseBytes(
          response.bodyBytes,
          nasdaq: nasdaq,
          contentType: contentType,
          master: master,
        );
        final date = parsed.fileDate;
        final today = DateTime.utc(now.year, now.month, now.day);
        if (date == null || date.isAfter(today)) {
          throw const FormatException('名錄檔案日期缺失或超前，請確認手機時間。');
        }
        if (mirror && today.difference(date) > maximumMirrorAge) {
          throw FormatException(
            '公開鏡像日期 ${date.toIso8601String().substring(0, 10)} '
            '超過 7 天，不採用過期名單。',
          );
        }
        debugPrint(
          '[StockUniverse] [SUCCESS] $label ${parsed.stocks.length} identities '
          'fileDate=${date.toIso8601String()} mirror=$mirror',
        );
        return _SourceStocks(
          parsed.stocks,
          warnings: [
            ...parsed.warnings,
            '$label 名錄日期：${date.toIso8601String().substring(0, 10)}（原檔未提供時區）。',
            if (mirror)
              '$label 官方來源暫不可用，改讀公開備援鏡像；'
                  '這是有日期的股票身份名單，不是交易所即時行情，不能保證目前完整成分。',
          ],
          isComplete: parsed.isComplete && !mirror,
          mirrored: mirror,
          fileDate: date,
        );
      } catch (error) {
        debugPrint(
          '[StockUniverse] [ERROR] $label ${url.host} '
          '${_errorLabel(error)} body=${_preview(response.bodyBytes)}',
        );
        rethrow;
      }
    }

    try {
      return await read(official, firstBudget, mirror: false);
    } catch (error) {
      final reason = '$label 官方來源 ${official.host}：${_errorLabel(error)}';
      debugPrint('[StockUniverse] [WARN] $reason');
      warnings.add(reason);
    }
    final remaining = budget - elapsed.elapsed;
    if (useUsMirrorFallback && !_closed && remaining > Duration.zero) {
      final mirror = nasdaq ? usMirrorEndpoint : usOtherMirrorEndpoint;
      try {
        final result = await read(mirror, remaining, mirror: true);
        return _SourceStocks(
          result.stocks,
          warnings: [...warnings, ...result.warnings],
          isComplete: false,
          mirrored: true,
          fileDate: result.fileDate,
        );
      } catch (error) {
        warnings.add('$label 備援 ${mirror.host}：${_errorLabel(error)}');
      }
    }
    return _SourceStocks.failure(warnings.join('；'));
  }

  Future<_SourceStocks> _loadTwSource(
    Uri url, {
    required bool otc,
    required Map<String, StockItem> master,
    required Duration budget,
    required DateTime now,
  }) async {
    // Primary and backup share ONE monotonic deadline, including waiting for
    // the global HTTP permits. A stalled JSON feed cannot consume a second 8s
    // wait on CSV, or hold the scan's foreground loading state indefinitely.
    final elapsed = Stopwatch()..start();
    final label = otc ? 'TPEx' : 'TWSE';
    final warnings = <String>[];
    final primaryBudget =
        useTwCsvFallback
            ? Duration(
              microseconds:
                  (budget.inMicroseconds ~/ 2)
                      .clamp(1, budget.inMicroseconds)
                      .toInt(),
            )
            : budget;
    Future<_SourceStocks> read(
      Uri endpoint,
      Duration timeout, {
      required bool csv,
    }) async {
      if (_closed) throw StateError('股票池服務已關閉。');
      debugPrint('[StockUniverse] >>> $label ${endpoint.host}${endpoint.path}');
      final response = await _network.get(endpoint, timeout: timeout);
      if (_closed) throw StateError('股票池服務已關閉。');
      debugPrint(
        '[StockUniverse] <<< $label ${endpoint.host} '
        'HTTP ${response.statusCode} bytes=${response.bodyBytes.length}',
      );
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}', endpoint);
      }
      final _SourceStocks parsed;
      if (csv) {
        // TWSE's government catalogue specifies monthly publication; TPEx is
        // daily. Preserve the actual document day instead of relabelling a
        // valid monthly file as newly published or rejecting it after 7 days.
        final document = TwIssuerCsv.parseBytes(
          response.bodyBytes,
          now: now,
          maximumAgeDays: otc ? 7 : 45,
        );
        final rows = _parseTw(jsonEncode(document.rows), master, otc: otc);
        parsed = _SourceStocks(
          rows.stocks,
          fileDate: document.asOf,
          metadataMaximumAgeDays: otc ? 7 : 45,
          metadataFormat: 'official_csv',
          warnings: [
            '$label 官方 JSON 名單暫不可用，已改用官方 CSV 備援 '
                '${endpoint.host}${endpoint.path}；原始出表日期 '
                '${document.asOf.add(const Duration(hours: 8)).toIso8601String().substring(0, 10)}（台北日期）。'
                '${otc ? '官方目錄為每日更新。' : '官方目錄為每月更新，不表示本日所有新上市異動均已納入。'}'
                '這是股票身份名單，不是即時行情。',
          ],
        );
      } else {
        parsed = _parseTw(utf8.decode(response.bodyBytes), master, otc: otc);
      }
      if (parsed.stocks.isEmpty) {
        throw const FormatException('台股交易所名單沒有可用普通股。');
      }
      debugPrint(
        '[StockUniverse] [SUCCESS] $label ${endpoint.host} '
        '${parsed.stocks.length} identities csv=$csv',
      );
      return parsed;
    }

    try {
      return await read(url, primaryBudget, csv: false);
    } catch (error) {
      if (_closed) rethrow;
      final reason =
          '${url.host}/${url.pathSegments.last}：${_errorLabel(error)}';
      debugPrint('[StockUniverse] [WARN] $label $reason');
      warnings.add(reason);
    }
    final remaining = budget - elapsed.elapsed;
    if (useTwCsvFallback && !_closed && remaining > Duration.zero) {
      final backup = otc ? twOtcCsvEndpoint : twCsvEndpoint;
      try {
        final parsed = await read(backup, remaining, csv: true);
        return _SourceStocks(
          parsed.stocks,
          warnings: [...warnings, ...parsed.warnings],
          fileDate: parsed.fileDate,
          isComplete: parsed.isComplete,
          metadataMaximumAgeDays: parsed.metadataMaximumAgeDays,
          metadataFormat: parsed.metadataFormat,
        );
      } catch (error) {
        if (_closed) rethrow;
        final reason =
            '${backup.host}/${backup.pathSegments.last}：${_errorLabel(error)}';
        debugPrint('[StockUniverse] [WARN] $label $reason');
        warnings.add(reason);
      }
    }
    return _SourceStocks.failure(warnings.join('；'));
  }

  static String _preview(List<int> bytes) =>
      _short(utf8.decode(bytes.take(400).toList(), allowMalformed: true), 180);

  static String _short(String text, int limit) {
    final value =
        text
            .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return value.length <= limit ? value : '${value.substring(0, limit)}…';
  }

  static _SourceStocks _parseTw(
    String body,
    Map<String, StockItem> master, {
    required bool otc,
  }) {
    final decoded = jsonDecode(body);
    if (decoded is! List) throw const FormatException('台股股票池必須為 JSON 陣列。');
    final stocks = <StockItem>[];
    final seen = <String>{};
    for (final row in decoded) {
      if (row is! Map<String, dynamic> ||
          (!row.containsKey('公司代號') &&
              !row.containsKey('SecuritiesCompanyCode'))) {
        throw const FormatException('台股股票池缺少公司代號。');
      }
      final code = _field(row, ['公司代號', 'SecuritiesCompanyCode']);
      if (!RegExp(r'^[1-9]\d{3}$').hasMatch(code) ||
          RegExp(r'^91\d{2}$').hasMatch(code))
        continue;
      final name = _field(row, [
        '公司簡稱',
        'CompanyAbbreviation',
        '公司名稱',
        'CompanyName',
      ]);
      final fullName = _field(row, [
        '公司名稱',
        'CompanyName',
        '公司簡稱',
        'CompanyAbbreviation',
      ]);
      final industry = _field(row, ['產業別', 'SecuritiesIndustryCode']);
      final classification = row.entries
          .where(
            (entry) => RegExp(
              r'股票種類|證券種類|證券別|security.?type|category',
              caseSensitive: false,
            ).hasMatch(entry.key),
          )
          .map((entry) => entry.value.toString())
          .join(' ');
      if (industry == '91' ||
          RegExp(
            r'存託憑證|特別股|TDR|preferred',
            caseSensitive: false,
          ).hasMatch('$name $fullName $classification'))
        continue;
      if (name.isEmpty || !seen.add(code)) {
        throw const FormatException('台股股票池含空白名稱或重複代碼。');
      }
      final symbol = '$code.${otc ? 'TWO' : 'TW'}';
      final known = master['tw:$symbol'];
      final sourceEnglish = _field(row, [
        '英文全名',
        '英文名稱',
        'EnglishCompanyName',
        'CompanyEnglishName',
      ]);
      final sourceAbbr = _field(row, ['英文簡稱', 'Symbol']);
      stocks.add(
        StockItem(
          market: StockMarket.tw,
          symbol: symbol,
          code: code,
          nameZh: name,
          nameFullZh: fullName,
          nameEn:
              sourceEnglish.isNotEmpty ? sourceEnglish : known?.nameEn ?? '',
          abbrEn: sourceAbbr.isNotEmpty ? sourceAbbr : known?.abbrEn ?? '',
          aliases:
              {
                ...?known?.aliases,
                if (known != null && known.nameZh != name) known.nameZh,
              }.toList(),
          shortCodes: known?.shortCodes ?? const [],
        ),
      );
    }
    return _SourceStocks(stocks);
  }

  static String _field(Map<String, dynamic> row, List<String> names) {
    for (final name in names) {
      final value = row[name];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return '';
  }

  static String _errorLabel(Object error) {
    if (error is TimeoutException) return '連線逾時';
    if (error is FormatException)
      return '資料格式無效：${_short(error.message.toString(), 140)}';
    if (error is http.ClientException && error.message.startsWith('HTTP '))
      return _short(error.message, 180);
    return '網路或資料源不可用';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _network.close();
  }
}

/// A source failure is data, never an uncaught rejection of the other source.
class _SourceStocks {
  _SourceStocks(
    this.stocks, {
    this.warnings = const [],
    this.isComplete = true,
    this.mirrored = false,
    this.fromCache = false,
    this.fileDate,
    this.metadataMaximumAgeDays = 30,
    this.metadataFormat = 'official_json',
  }) : success = true;
  _SourceStocks.failure(String warning)
    : stocks = const [],
      warnings = [warning],
      success = false,
      isComplete = false,
      mirrored = false,
      fromCache = false,
      fileDate = null,
      metadataMaximumAgeDays = 30,
      metadataFormat = 'official_json';
  final List<StockItem> stocks;
  final List<String> warnings;
  final bool success;
  final bool isComplete;
  final bool mirrored;
  final bool fromCache;
  final DateTime? fileDate;
  final int metadataMaximumAgeDays;
  final String metadataFormat;
}

/// Exchange membership is dated metadata only; prices/signals are never cached
/// here. Old membership expires independently, even if its peer refreshes daily.
class _TwSourceCache {
  _TwSourceCache({
    required List<StockItem> stocks,
    required this.asOf,
    required this.retrievedAt,
    this.maximumAgeDays = 30,
    this.metadataFormat = 'official_json',
  }) : stocks = List.unmodifiable(stocks);

  final List<StockItem> stocks;
  final DateTime asOf;
  final DateTime retrievedAt;
  final int maximumAgeDays;
  final String metadataFormat;

  bool isUsable(DateTime now) =>
      !asOf.isAfter(now) &&
      !retrievedAt.isAfter(now) &&
      !retrievedAt.isBefore(asOf) &&
      (maximumAgeDays == 30
          ? now.difference(asOf) <= StockUniverseService.maximumStaleAge
          : now.difference(asOf).inDays <= maximumAgeDays);

  Map<String, dynamic> toJson() => {
    'as_of': asOf.toUtc().toIso8601String(),
    'retrieved_at': retrievedAt.toUtc().toIso8601String(),
    'maximum_age_days': maximumAgeDays,
    'metadata_format': metadataFormat,
    'stocks': stocks.map((stock) => stock.toJson()).toList(),
  };

  factory _TwSourceCache.fromJson(
    Map<String, dynamic> json, {
    required String exchange,
    required DateTime now,
  }) {
    final raw = json['stocks'];
    if (raw is! List || raw.isEmpty || raw.length > 3500) {
      throw const FormatException('交易所名單大小無效。');
    }
    final seen = <String>{};
    final suffix = exchange == 'TWSE' ? '.TW' : '.TWO';
    final stocks =
        raw.map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException('交易所名單紀錄無效。');
          }
          final stock = StockItem.fromJson(value);
          if (stock.market != StockMarket.tw ||
              !stock.symbol.endsWith(suffix) ||
              !seen.add(stock.symbol)) {
            throw const FormatException('交易所名單含跨市場、錯誤後綴或重複代碼。');
          }
          return stock;
        }).toList();
    final age = json['maximum_age_days'] ?? 30;
    final format = json['metadata_format'] ?? 'official_json';
    if (age is! int ||
        format is! String ||
        !const ['official_json', 'official_csv'].contains(format) ||
        (format == 'official_json'
            ? age != 30
            : age != (exchange == 'TWSE' ? 45 : 7))) {
      throw const FormatException('交易所名單保存期限無效。');
    }
    final source = _TwSourceCache(
      stocks: stocks,
      asOf: parseApiTimestamp(json['as_of'], 'as_of'),
      retrievedAt: parseApiTimestamp(json['retrieved_at'], 'retrieved_at'),
      maximumAgeDays: age,
      metadataFormat: format,
    );
    if (!source.isUsable(now)) {
      throw const FormatException('交易所名單已過期或日期無效。');
    }
    return source;
  }
}
