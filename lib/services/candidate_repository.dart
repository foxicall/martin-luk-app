import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/stock_candidate.dart';

class CandidateSnapshot {
  CandidateSnapshot({
    required List<StockCandidate> candidates,
    required this.fetchedAt,
    required List<String> warnings,
    required this.source,
    required this.universeCount,
    required this.stale,
    List<String> missingSymbols = const [],
    this.evaluatedCount,
    this.universeIsComplete = true,
    this.universeAsOf,
    this.scanCompletedAt,
  })  : candidates = List<StockCandidate>.unmodifiable(candidates),
        warnings = List<String>.unmodifiable(warnings),
        missingSymbols = List<String>.unmodifiable(missingSymbols);

  final List<StockCandidate> candidates;
  final DateTime fetchedAt;
  final List<String> warnings;
  final String source;
  final int universeCount;
  final bool stale;
  final List<String> missingSymbols;
  final int? evaluatedCount;
  final bool universeIsComplete;
  final DateTime? universeAsOf;
  final DateTime? scanCompletedAt;

  DateTime get generatedAt => fetchedAt;
  bool get isStale => stale;
}

abstract interface class CandidateRepository {
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  });
}

/// A user-readable error. API failures never silently switch to fake data.
class RepositoryException implements Exception {
  const RepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RealCandidateRepository implements CandidateRepository {
  RealCandidateRepository({required String baseUrl, http.Client? client})
      : _baseUri = _parseBaseUrl(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri _baseUri;
  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    _validateThreshold(adrThreshold);
    final endpoint = _baseUri.replace(
      path: '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/candidates',
      queryParameters: {
        'market': market.name,
        'adr_threshold': adrThreshold.toString(),
      },
    );
    try {
      final response = await _client
          .get(endpoint, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw RepositoryException('掃描 API 回應 HTTP ${response.statusCode}，請檢查後端狀態。');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('回應必須為 JSON 物件。');
      }
      return _parseSnapshot(decoded, market);
    } on RepositoryException {
      rethrow;
    } on TimeoutException {
      throw const RepositoryException('掃描 API 連線逾時，請稍後重試。');
    } on http.ClientException {
      throw const RepositoryException('無法連線掃描 API，請檢查網址與網路連線。');
    } on FormatException catch (error) {
      throw RepositoryException('掃描 API 資料格式錯誤：${error.message}');
    } catch (error) {
      throw RepositoryException('無法讀取掃描結果：${error.runtimeType}。');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

CandidateSnapshot _parseSnapshot(Map<String, dynamic> json, StockMarket market) {
  if (json['market'] != market.name) {
    throw const FormatException('回應市場與要求市場不符。');
  }
  final source = json['source'];
  final count = json['universe_count'];
  final stale = json['stale'];
  final warnings = json['warnings'];
  final rows = json['candidates'];
  if (source is! String || source.trim().isEmpty ||
      count is! int || count < 0 || stale is! bool || warnings is! List ||
      warnings.any((warning) => warning is! String) || rows is! List) {
    throw const FormatException('來源、股票池數量、快取狀態或候選清單格式無效。');
  }
  if (RegExp(r'mock|demo|fictit|假|虛構|示範|離線', caseSensitive: false).hasMatch(source)) {
    throw const FormatException('正式掃描 API 回傳了示範來源，已拒絕載入。');
  }
  final candidates = <StockCandidate>[];
  final seenSymbols = <String>{};
  for (final row in rows) {
    if (row is! Map<String, dynamic>) {
      throw const FormatException('個股資料必須為 JSON 物件。');
    }
    final candidate = StockCandidate.fromJson(row);
    if (candidate.market != market || !seenSymbols.add(candidate.symbol)) {
      throw const FormatException('候選資料包含不同市場或重複股票代碼。');
    }
    candidates.add(candidate);
  }
  if (count < candidates.length) {
    throw const FormatException('股票池數量小於候選股票數量。');
  }
  final missing = json['missing_symbols'];
  if (missing != null &&
      (missing is! List || missing.any((item) => item is! String))) {
    throw const FormatException('missing_symbols 必須為字串陣列。');
  }
  return CandidateSnapshot(
    candidates: candidates,
    fetchedAt: parseApiTimestamp(json['generated_at'], 'generated_at'),
    warnings: warnings.cast<String>(),
    source: source,
    universeCount: count,
    stale: stale,
    evaluatedCount: json['evaluated_count'] is int ? json['evaluated_count'] as int : null,
    universeIsComplete: json['universe_is_complete'] != false,
    universeAsOf: json['universe_as_of'] == null ? null : parseApiTimestamp(json['universe_as_of'], 'universe_as_of'),
    scanCompletedAt: parseApiTimestamp(json['generated_at'], 'generated_at'),
    missingSymbols: missing == null ? const [] : (missing as List).cast<String>(),
  );
}

Uri _parseBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty || uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
    throw const RepositoryException('API 網址必須為有效的 HTTP / HTTPS 網址。');
  }
  return uri;
}

void _validateThreshold(double value) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, 'adrThreshold', 'ADR 門檻必須為有限非負數。');
  }
}

/// Fixed, clearly labeled fictitious quotes allow every screen to work offline.
/// Stock identities are real for familiarity; quotes, ranks and signals are not.
class MockCandidateRepository implements CandidateRepository {
  @override
  Future<CandidateSnapshot> fetch(
    StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    _validateThreshold(adrThreshold);
    final candidates = _mockCandidates(market)
        .where((candidate) => candidate.adrPercent >= adrThreshold)
        .toList();
    return CandidateSnapshot(
      candidates: candidates,
      fetchedAt: _demoTime,
      warnings: const [
        '離線示範：報價、ADR、RS 與訊號全部為固定假資料，並非即時掃描。',
        '資料僅含範例股票，未掃描完整 TWSE 或 S&P 500 股票池。',
      ],
      source: '離線示範',
      universeCount: 8,
      evaluatedCount: 8,
      universeIsComplete: false,
      stale: false,
    );
  }
}

final _demoTime = DateTime.utc(2026, 10, 13, 6);

List<StockCandidate> _mockCandidates(StockMarket market) {
  // Prices use the market currency. No USD/TWD conversion is performed.
  final specs = market == StockMarket.tw
      ? <_MockSpec>[
          const _MockSpec('2330.TW', '台積電', '半導體', 1120, 5.3, 99, 1, true, 'PDH 突破', 2.0),
          const _MockSpec('2317.TW', '鴻海', '電子製造', 220, 4.1, 95, 2, true, 'ORH 突破・Episodic Pivot', 2.5),
          const _MockSpec('2454.TW', '聯發科', 'IC 設計', 1390, 4.9, 93, 3, true, '均線密集收斂', null),
          const _MockSpec('2382.TW', '廣達', '電腦週邊', 320, 6.1, 90, 4, true, 'PDH 突破', 1.5),
          const _MockSpec('3017.TW', '奇鋐', '散熱', 650, 6.8, 88, 5, false, 'ORH 突破', 3.0),
          const _MockSpec('1519.TW', '華城', '電機機械', 710, 7.2, 86, 6, false, 'PDH 突破', 2.0),
          const _MockSpec('2308.TW', '台達電', '電子零組件', 420, 4.0, 82, 7, true, '均線密集收斂', null),
          const _MockSpec('2376.TW', '技嘉', '電腦週邊', 295, 5.6, 80, 8, false, 'ORH 突破', 2.5),
        ]
      : <_MockSpec>[
          const _MockSpec('NVDA', 'NVIDIA', '資訊科技', 140, 7.1, 99, 1, true, 'PDH 突破', 2.0),
          const _MockSpec('TSLA', 'Tesla', '非必需消費品', 270, 8.2, 96, 2, true, 'ORH 突破・Episodic Pivot', 2.5),
          const _MockSpec('AMD', 'Advanced Micro Devices', '資訊科技', 165, 6.9, 93, 3, true, '均線密集收斂', null),
          const _MockSpec('META', 'Meta Platforms', '通訊服務', 610, 5.6, 90, 4, true, 'PDH 突破', 1.5),
          const _MockSpec('AVGO', 'Broadcom', '資訊科技', 188, 6.2, 88, 5, true, 'ORH 突破', 3.0),
          const _MockSpec('PLTR', 'Palantir Technologies', '資訊科技', 45, 8.8, 85, 6, false, 'PDH 突破', 2.0),
          const _MockSpec('NFLX', 'Netflix', '通訊服務', 720, 5.3, 83, 7, true, '均線密集收斂', null),
          const _MockSpec('MU', 'Micron Technology', '資訊科技', 106, 6.5, 80, 8, false, 'ORH 突破', 2.5),
        ];
  return specs.map((spec) {
    final stop = spec.stopPercent == null
        ? null
        : double.parse((spec.price * (1 - spec.stopPercent! / 100)).toStringAsFixed(4));
    return StockCandidate(
      id: '${market.name}:${spec.symbol}',
      symbol: spec.symbol,
      name: spec.name,
      sector: spec.sector,
      market: market,
      adrPercent: spec.adr,
      rsScore: spec.rs,
      rsRank: spec.rank,
      patterns: [spec.pattern],
      entryPrice: spec.price,
      stopPrice: stop,
      triggerPrice: spec.price,
      triggerType: spec.pattern.contains('PDH') ? 'PDH' : spec.pattern.contains('ORH') ? 'ORH' : null,
      stopSource: stop == null ? null : 'day_low',
      dayLow: stop,
      isLargeLiquid: spec.large,
      status: stop == null ? 'watchlist' : 'confirmed',
      dataTimestamp: _demoTime,
      signalTimestamp: stop == null ? null : _demoTime,
      notes: const ['假資料示範；不可據此認定當前報價或真實突破。', '風險預算未包含跳空、滑價與交易成本。'],
      dailyCloses: List<double>.generate(
        40,
        (index) => double.parse((spec.price * (0.83 + index * 0.004 + (index % 5 - 2) * 0.003)).toStringAsFixed(2)),
      ),
    );
  }).toList();
}

class _MockSpec {
  const _MockSpec(this.symbol, this.name, this.sector, this.price, this.adr,
      this.rs, this.rank, this.large, this.pattern, this.stopPercent);
  final String symbol;
  final String name;
  final String sector;
  final double price;
  final double adr;
  final double rs;
  final int rank;
  final bool large;
  final String pattern;
  final double? stopPercent;
}
