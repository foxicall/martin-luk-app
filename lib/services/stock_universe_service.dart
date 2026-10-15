import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'network_request.dart';

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
    this.requestTimeout = NetworkRequest.defaultTimeout,
    this.storageTimeout = NetworkRequest.defaultStorageTimeout,
  })  : _network = NetworkRequest(client: client, timeout: requestTimeout),
        _preferences = preferences,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now {
    if (storageTimeout <= Duration.zero ||
        storageTimeout > NetworkRequest.storageTimeout) {
      throw ArgumentError.value(storageTimeout, 'storageTimeout',
          '本機快取等待必須大於零且不得超過 5 秒。');
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
  bool _closed = false;

  static String cacheKey(StockMarket market) =>
      'martin_luk.universe.v2.all_common.${market.name}';

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
        now.difference(cached.asOf) <=
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

    try {
      // Exactly two metadata feeds per market, independent failure isolation.
      // This is not an unbounded market-price request fan-out.
      final endpoints = market == StockMarket.us
          ? [usEndpoint, usOtherEndpoint]
          : [twEndpoint, twOtcEndpoint];
      final requestBudget = requestTimeout < NetworkRequest.defaultTimeout
          ? requestTimeout : NetworkRequest.defaultTimeout;
      final replies = await Future.wait(endpoints.asMap().entries.map((entry) async {
        try {
          final response = await _network.get(entry.value, timeout: requestBudget);
          if (response.statusCode != 200) {
            throw http.ClientException('HTTP ${response.statusCode}', entry.value);
          }
          final body = utf8.decode(response.bodyBytes);
          final parsed = market == StockMarket.us
              ? _parseUs(body, master, nasdaq: entry.key == 0)
              : _parseTw(body, master, otc: entry.key == 1);
          if (parsed.stocks.isEmpty) {
            throw const FormatException('資料源沒有可識別的普通股。');
          }
          return parsed;
        } catch (error) {
          return _SourceStocks.failure(
            '${entry.value.host}/${entry.value.pathSegments.last}：${_errorLabel(error)}',
          );
        }
      }));
      final successful = replies.where((reply) => reply.success).length;
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
      final stocks = bySymbol.values.toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      final complete = successful == 2 && (market == StockMarket.us
          ? stocks.length >= 2500 && stocks.length <= 15000
          : stocks.length >= 1500 && stocks.length <= 3500);
      if (!complete) {
        warnings.add('僅取得 $successful/2 個交易所清單、${stocks.length} 檔普通股；全市場覆蓋不足。');
      }
      if (market == StockMarket.us) {
        warnings.add('美股目錄沒有完整 CFI；以普通股名稱保守分類，未能確認的證券已排除，非百分之百分類認證。');
      }
      if (market == StockMarket.tw) {
        warnings.add('台股使用官方上市／上櫃發行公司清單，並保守排除91開頭存託憑證及非四碼證券；此為啟發式分類，未逐筆取得證券 CFI 認證。');
      }
      final snapshot = UniverseSnapshot(
        stocks: stocks,
        asOf: now,
        source: market == StockMarket.us
            ? 'Nasdaq Trader symbol directories: Nasdaq / NYSE / NYSE American common stocks'
            : 'TWSE / TPEx official ordinary-stock issuers',
        isComplete: complete,
        warnings: warnings,
      );
      if (preferences != null) {
        try {
          final written = await preferences.setString(
            cacheKey(market), jsonEncode(_encode(snapshot, market)),
          ).timeout(storageTimeout);
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
          '僅使用內建 ${fallback.length} 檔搜尋字典；它不是目前完整台股上市櫃／美股三大交易所股票池，成分日期未驗證。',
        ],
      );
    }
  }

  Future<SharedPreferences?> _getPreferences(List<String> warnings) async {
    try {
      return _preferences ??= await _preferencesLoader().timeout(storageTimeout);
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
      if (decoded is! Map<String, dynamic> || decoded['version'] != 2 ||
          decoded['scope'] != 'all_common' || decoded['market'] != market.name || decoded['source'] is! String ||
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
    'version': 2,
    'scope': 'all_common',
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

  static _SourceStocks _parseUs(
    String body,
    Map<String, StockItem> master, {
    required bool nasdaq,
  }) {
    final lines = const LineSplitter().convert(body.replaceFirst('\ufeff', ''));
    if (lines.isEmpty) throw const FormatException('美股交易所目錄為空。');
    final headers = lines.first.split('|').map((cell) => cell.trim()).toList();
    final expected = nasdaq
        ? ['Symbol', 'Security Name', 'Test Issue', 'ETF']
        : ['ACT Symbol', 'Security Name', 'Exchange', 'Test Issue', 'ETF'];
    if (expected.any((name) => !headers.contains(name))) {
      throw const FormatException('美股目錄缺少代碼、證券名稱或分類欄位。');
    }
    final stocks = <StockItem>[];
    final seen = <String>{};
    var unknown = 0;
    var footerSeen = false;
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      if (line.startsWith('File Creation Time:')) {
        footerSeen = true;
        continue;
      }
      if (footerSeen) throw const FormatException('美股目錄結尾後含未知紀錄。');
      final cells = line.split('|');
      if (cells.length != headers.length) {
        throw const FormatException('美股目錄欄位數不一致。');
      }
      String field(String name) => cells[headers.indexOf(name)].trim();
      if (field('Test Issue') != 'N' || field('ETF') != 'N') continue;
      // Nasdaq is this file; otherlisted also includes exchanges outside scope.
      if (!nasdaq && !{'N', 'A'}.contains(field('Exchange'))) continue;
      final name = field('Security Name');
      if (RegExp(
        r'\b(?:preferred|preference|pfd|depositary|depository|ADR|ADS|warrants?|units?|rights?|ET[FN]|funds?|notes?|bonds?)\b|exchange[- ]traded|\bshares?\s+of\s+beneficial\s+interest\b',
        caseSensitive: false,
      ).hasMatch(name)) continue;
      // Corporate REIT ordinary shares remain in scope. An investment trust
      // or beneficial-interest fund is not made ordinary by its name alone.
      final withoutCorporateReit = name.replaceAll(
        RegExp(r'\breal\s+estate\s+investment\s+trust\b', caseSensitive: false), '',
      );
      if (RegExp(r'\binvestment\s+trust\b', caseSensitive: false)
          .hasMatch(withoutCorporateReit)) continue;
      if (!RegExp(r'\bcommon\s+(?:stock|shares?)\b|\bordinary\s+(?:stock|shares?)\b|\bcapital\s+stock\b', caseSensitive: false)
          .hasMatch(name)) {
        unknown++;
        continue;
      }
      final rawSymbol = field(nasdaq ? 'Symbol' : 'ACT Symbol');
      final symbol = rawSymbol.toUpperCase().replaceAll('.', '-');
      if (!RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$').hasMatch(symbol) || name.isEmpty) {
        unknown++;
        continue;
      }
      if (!seen.add(symbol)) throw const FormatException('美股目錄含重複普通股代碼。');
      final known = master['us:$symbol'];
      stocks.add(StockItem(
        market: StockMarket.us, symbol: symbol, code: symbol,
        nameZh: known?.nameZh ?? '', nameFullZh: known?.nameFullZh ?? '',
        nameEn: name, abbrEn: known?.abbrEn ?? '',
        aliases: known?.aliases ?? const [], shortCodes: known?.shortCodes ?? const [],
      ));
    }
    if (!footerSeen) throw const FormatException('美股目錄缺少檔案完成標記，可能下載不完整。');
    return _SourceStocks(stocks, warnings: [
      if (unknown > 0) '美股${nasdaq ? ' Nasdaq' : ' NYSE/NYSE American'}目錄 $unknown 筆未能確認為普通股，未納入。',
    ]);
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
          (!row.containsKey('公司代號') && !row.containsKey('SecuritiesCompanyCode'))) {
        throw const FormatException('台股股票池缺少公司代號。');
      }
      final code = _field(row, ['公司代號', 'SecuritiesCompanyCode']);
      if (!RegExp(r'^[1-9]\d{3}$').hasMatch(code) ||
          RegExp(r'^91\d{2}$').hasMatch(code)) continue;
      final name = _field(row, ['公司簡稱', 'CompanyAbbreviation', '公司名稱', 'CompanyName']);
      final fullName = _field(row, ['公司名稱', 'CompanyName', '公司簡稱', 'CompanyAbbreviation']);
      final industry = _field(row, ['產業別', 'SecuritiesIndustryCode']);
      final classification = row.entries
          .where((entry) => RegExp(r'股票種類|證券種類|證券別|security.?type|category', caseSensitive: false)
              .hasMatch(entry.key))
          .map((entry) => entry.value.toString()).join(' ');
      if (industry == '91' || RegExp(r'存託憑證|特別股|TDR|preferred', caseSensitive: false)
          .hasMatch('$name $fullName $classification')) continue;
      if (name.isEmpty || !seen.add(code)) {
        throw const FormatException('台股股票池含空白名稱或重複代碼。');
      }
      final symbol = '$code.${otc ? 'TWO' : 'TW'}';
      final known = master['tw:$symbol'];
      final sourceEnglish = _field(row, ['英文全名', '英文名稱', 'EnglishCompanyName', 'CompanyEnglishName']);
      final sourceAbbr = _field(row, ['英文簡稱', 'Symbol']);
      stocks.add(StockItem(
        market: StockMarket.tw, symbol: symbol, code: code,
        nameZh: name, nameFullZh: fullName,
        nameEn: sourceEnglish.isNotEmpty ? sourceEnglish : known?.nameEn ?? '',
        abbrEn: sourceAbbr.isNotEmpty ? sourceAbbr : known?.abbrEn ?? '',
        aliases: {...?known?.aliases, if (known != null && known.nameZh != name) known.nameZh}.toList(),
        shortCodes: known?.shortCodes ?? const [],
      ));
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
    if (error is FormatException) return '資料格式無效';
    if (error is http.ClientException && error.message.startsWith('HTTP ')) return error.message;
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
  _SourceStocks(this.stocks, {this.warnings = const []}) : success = true;
  _SourceStocks.failure(String warning)
      : stocks = const [], warnings = [warning], success = false;
  final List<StockItem> stocks;
  final List<String> warnings;
  final bool success;
}
