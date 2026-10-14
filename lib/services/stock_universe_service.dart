import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';

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
  })  : stocks = List.unmodifiable(stocks),
        warnings = List.unmodifiable(warnings);

  final List<StockItem> stocks;
  final DateTime asOf;
  final String source;
  final bool isComplete;
  final List<String> warnings;
  final bool isCached;

  int get totalCount => stocks.length;
}

/// One request loads a complete provider list, while alias/name lookups reuse
/// the bundled master dictionary. No metadata HTTP is sent per search keystroke.
///
/// This service fetches public HTTPS endpoints without an API secret. These
/// endpoints may change, reject requests or lack browser CORS permission; a
/// failure produces a clearly identified real metadata cache, never fake data.
class StockUniverseService {
  StockUniverseService({
    http.Client? client,
    SharedPreferences? preferences,
    DateTimeFunction? now,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _preferences = preferences,
        _now = now ?? DateTime.now;

  static final Uri usEndpoint = Uri.parse(
    'https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv',
  );
  static final Uri twEndpoint = Uri.parse(
    'https://openapi.twse.com.tw/v1/opendata/t187ap03_L',
  );
  static const Duration cacheLifetime = Duration(hours: 24);
  static const Duration maximumStaleAge = Duration(days: 30);
  static const Duration requestTimeout = Duration(seconds: 20);

  final http.Client _client;
  final bool _ownsClient;
  final DateTimeFunction _now;
  SharedPreferences? _preferences;
  Future<Map<String, StockItem>>? _master;
  final Map<StockMarket, Future<UniverseSnapshot>> _inFlight = {};
  bool _closed = false;

  static String cacheKey(StockMarket market) =>
      'martin_luk.universe.v1.${market.name}';

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
    final cached = _readCache(preferences, market, now, warnings);
    if (!forceRefresh && cached != null &&
        now.difference(cached.asOf) <= cacheLifetime) {
      return _cachedCopy(cached, warnings);
    }

    // A missing alias asset does not prevent live universe retrieval. Missing
    // aliases only affect bilingual display and can be retried on another load.
    Map<String, StockItem> master = const {};
    try {
      master = await (_master ??= _loadMaster());
    } catch (_) {
      _master = null;
      warnings.add('本機中文別名字典無法讀取；連網清單仍使用資料源名稱。');
    }

    try {
      final response = await _client.get(
        market == StockMarket.us ? usEndpoint : twEndpoint,
        headers: const {'Accept': 'application/json,text/csv;q=0.9,*/*;q=0.8'},
      ).timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode}');
      }
      final body = utf8.decode(response.bodyBytes);
      final stocks = market == StockMarket.us
          ? _parseUs(body, master)
          : _parseTw(body, master);
      if (stocks.isEmpty) {
        throw const FormatException('股票池資料源沒有可用普通股。');
      }
      // Membership count fluctuates, including multiple S&P share classes.
      // Broad sanity bounds detect a truncated response, not index membership.
      final complete = market == StockMarket.us
          ? stocks.length >= 450 && stocks.length <= 600
          : stocks.length >= 700 && stocks.length <= 2000;
      if (!complete) {
        warnings.add('資料源只回傳 ${stocks.length} 檔，低於完整股票池合理範圍；掃描覆蓋不足。');
      }
      final snapshot = UniverseSnapshot(
        stocks: stocks,
        asOf: now,
        source: market == StockMarket.us
            ? 'S&P 500 constituents (datasets GitHub)'
            : 'TWSE OpenAPI listed ordinary-stock issuers',
        isComplete: complete,
        warnings: warnings,
      );
      if (preferences != null) {
        try {
          final written = await preferences.setString(
            cacheKey(market), jsonEncode(_encode(snapshot, market)),
          );
          if (!written) throw StateError('快取儲存失敗。');
        } catch (_) {
          return UniverseSnapshot(
            stocks: snapshot.stocks,
            asOf: snapshot.asOf,
            source: snapshot.source,
            isComplete: snapshot.isComplete,
            warnings: [...snapshot.warnings, '最新股票池已取得，但無法儲存本機快取。'],
          );
        }
      }
      return snapshot;
    } catch (error) {
      warnings.add('股票池更新失敗（${_errorLabel(error)}）；沒有使用示範行情。');
      if (cached != null) {
        warnings.add('使用 ${cached.asOf.toIso8601String()} 的股票池快取，成分可能已變更。');
        return _cachedCopy(cached, warnings);
      }
      final fallback = master.values.where((item) => item.market == market).toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      if (fallback.isEmpty) {
        throw StateError('無法取得股票池，且沒有可用本機元資料；請連網後重試。');
      }
      return UniverseSnapshot(
        stocks: fallback,
        // Build-time dictionary date is intentionally distinct from retrieval
        // time: opening the app does not refresh constituent membership.
        asOf: DateTime.utc(2026, 10, 13),
        source: 'bundled stock metadata dictionary (partial, unverified membership)',
        isComplete: false,
        isCached: true,
        warnings: [
          ...warnings,
          '僅使用內建 ${fallback.length} 檔搜尋字典；它不是目前完整 S&P 500／TWSE 股票池，成分日期未驗證。',
        ],
      );
    }
  }

  Future<SharedPreferences?> _getPreferences(List<String> warnings) async {
    try {
      return _preferences ??= await SharedPreferences.getInstance();
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
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1 ||
          decoded['market'] != market.name || decoded['source'] is! String ||
          decoded['is_complete'] is! bool || decoded['stocks'] is! List) {
        throw const FormatException('股票池快取結構無效。');
      }
      final asOf = parseApiTimestamp(decoded['as_of'], 'as_of');
      final age = now.difference(asOf);
      if (age.isNegative || age > maximumStaleAge) {
        warnings.add('股票池快取日期無效或已超過 30 天；不以它當作現行成分。');
        return null;
      }
      final seen = <String>{};
      final stocks = (decoded['stocks'] as List).map((row) {
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
      final storedWarnings = decoded['warnings'];
      if (storedWarnings is! List || storedWarnings.any((entry) => entry is! String)) {
        throw const FormatException('股票池快取提示無效。');
      }
      return UniverseSnapshot(
        stocks: stocks,
        asOf: asOf,
        source: decoded['source'] as String,
        isComplete: decoded['is_complete'] as bool,
        warnings: storedWarnings.cast<String>(),
        isCached: true,
      );
    } catch (_) {
      warnings.add('股票池快取損毀；重新取得連網清單。');
      return null;
    }
  }

  static Map<String, dynamic> _encode(UniverseSnapshot snapshot, StockMarket market) => {
    'version': 1,
    'market': market.name,
    'as_of': snapshot.asOf.toUtc().toIso8601String(),
    'source': snapshot.source,
    'is_complete': snapshot.isComplete,
    'warnings': snapshot.warnings,
    'stocks': snapshot.stocks.map((stock) => stock.toJson()).toList(),
  };

  static UniverseSnapshot _cachedCopy(UniverseSnapshot snapshot, List<String> warnings) =>
      UniverseSnapshot(
        stocks: snapshot.stocks,
        asOf: snapshot.asOf,
        source: snapshot.source,
        isComplete: snapshot.isComplete,
        isCached: true,
        warnings: {...snapshot.warnings, ...warnings}.toList(),
      );

  static Future<Map<String, StockItem>> _loadMaster() async {
    final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json'));
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

  static List<StockItem> _parseUs(String body, Map<String, StockItem> master) {
    final rows = _csv(body);
    if (rows.isEmpty) throw const FormatException('S&P 500 CSV 為空。');
    final headers = rows.first.map((field) => field.trim().toLowerCase()).toList();
    final symbolColumn = headers.indexOf('symbol');
    final nameColumn = headers.indexOf('name');
    if (symbolColumn < 0 || nameColumn < 0) {
      throw const FormatException('S&P 500 CSV 缺少 Symbol／Name 欄位。');
    }
    final seen = <String>{};
    final stocks = <StockItem>[];
    for (final row in rows.skip(1)) {
      if (row.every((field) => field.trim().isEmpty)) continue;
      if (row.length != headers.length) {
        throw const FormatException('S&P 500 CSV 欄位數不一致。');
      }
      final symbol = row[symbolColumn].trim().toUpperCase().replaceAll('.', '-');
      final name = row[nameColumn].trim();
      if (!RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$').hasMatch(symbol) || name.isEmpty) {
        throw const FormatException('S&P 500 CSV 含無效代碼或名稱。');
      }
      if (!seen.add(symbol)) throw const FormatException('S&P 500 CSV 含重複代碼。');
      final known = master['us:$symbol'];
      stocks.add(StockItem(
        market: StockMarket.us,
        symbol: symbol,
        code: symbol,
        nameZh: known?.nameZh ?? '',
        nameFullZh: known?.nameFullZh ?? '',
        nameEn: name,
        abbrEn: known?.abbrEn ?? '',
        aliases: known?.aliases ?? const [],
        shortCodes: known?.shortCodes ?? const [],
      ));
    }
    return stocks..sort((a, b) => a.symbol.compareTo(b.symbol));
  }

  static List<StockItem> _parseTw(String body, Map<String, StockItem> master) {
    final decoded = jsonDecode(body);
    if (decoded is! List) throw const FormatException('TWSE 股票池必須為 JSON 陣列。');
    final stocks = <StockItem>[];
    final seen = <String>{};
    for (final row in decoded) {
      if (row is! Map<String, dynamic> || !row.containsKey('公司代號')) {
        throw const FormatException('TWSE 股票池缺少公司代號。');
      }
      final code = _field(row, ['公司代號']);
      // Listed issuers' ordinary common shares use four digits beginning with
      // 1–9. A 0-prefix identifies a fund/ETF rather than an ordinary issuer.
      if (!RegExp(r'^[1-9]\d{3}$').hasMatch(code)) continue;
      final name = _field(row, ['公司簡稱', '公司名稱']);
      final fullName = _field(row, ['公司名稱', '公司簡稱']);
      final industry = _field(row, ['產業別']);
      final classification = row.entries
          .where((entry) => RegExp(r'股票種類|證券種類|證券別|security.?type|category', caseSensitive: false)
              .hasMatch(entry.key))
          .map((entry) => entry.value.toString()).join(' ');
      if (industry == '91' || RegExp(r'存託憑證|特別股|TDR|preferred', caseSensitive: false)
          .hasMatch('$name $fullName $classification')) continue;
      if (name.isEmpty || !seen.add(code)) {
        throw const FormatException('TWSE 股票池含空白名稱或重複代碼。');
      }
      final symbol = '$code.TW';
      final known = master['tw:$symbol'];
      final sourceEnglish = _field(row, ['英文全名', '英文名稱']);
      final sourceAbbr = _field(row, ['英文簡稱']);
      stocks.add(StockItem(
        market: StockMarket.tw,
        symbol: symbol,
        code: code,
        nameZh: name,
        nameFullZh: fullName,
        nameEn: sourceEnglish.isNotEmpty ? sourceEnglish : known?.nameEn ?? '',
        abbrEn: sourceAbbr.isNotEmpty ? sourceAbbr : known?.abbrEn ?? '',
        aliases: {...?known?.aliases, if (known != null && known.nameZh != name) known.nameZh}.toList(),
        shortCodes: known?.shortCodes ?? const [],
      ));
    }
    return stocks..sort((a, b) => a.symbol.compareTo(b.symbol));
  }

  static String _field(Map<String, dynamic> row, List<String> names) {
    for (final name in names) {
      final value = row[name];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return '';
  }

  /// RFC 4180-style quotes, escaped quotes, embedded commas/newlines and BOM.
  static List<List<String>> _csv(String raw) {
    final input = raw.startsWith('\ufeff') ? raw.substring(1) : raw;
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var quoteClosed = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (quoted) {
        if (char == '"') {
          if (index + 1 < input.length && input[index + 1] == '"') {
            field.write('"');
            index++;
          } else {
            quoted = false;
            quoteClosed = true;
          }
        } else {
          field.write(char);
        }
      } else if (char == ',' || char == '\n' || char == '\r') {
        row.add(field.toString());
        field = StringBuffer();
        quoteClosed = false;
        if (char != ',') {
          rows.add(row);
          row = <String>[];
          if (char == '\r' && index + 1 < input.length && input[index + 1] == '\n') index++;
        }
      } else if (char == '"' && field.isEmpty && !quoteClosed) {
        quoted = true;
      } else {
        if (char == '"' || quoteClosed) throw const FormatException('CSV 引號結構無效。');
        field.write(char);
      }
    }
    if (quoted) throw const FormatException('CSV 引號未閉合。');
    if (field.isNotEmpty || row.isNotEmpty || quoteClosed) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  static String _errorLabel(Object error) {
    if (error is TimeoutException) return '連線逾時';
    if (error is FormatException) return '資料格式無效';
    if (error is http.ClientException && error.message.startsWith('HTTP ')) return error.message;
    return '網路或資料源不可用';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}
