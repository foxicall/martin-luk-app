import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/backend_scan_status.dart';
import '../models/stock_candidate.dart';
import '../models/hybrid_protocol.dart';
import 'network_request.dart';

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
    this.scanPoolSize,
    this.adrMatchCount,
    this.universeIsComplete = true,
    this.universeAsOf,
    this.scanCompletedAt,
    this.isFallback = false,
    this.attemptedAt,
    this.backendScan,
    this.isPending = false,
    this.coverageTotalCount,
    this.coverageScannedCount,
    this.coverageEvaluatedCount,
    this.coverageRemainingCount,
    this.coverageRound,
    this.scanPageStart,
    this.scanPageSize,
    this.universeFingerprint,
    this.candidatesAreCumulative = false,
  }) : candidates = List<StockCandidate>.unmodifiable(candidates),
       warnings = List<String>.unmodifiable(warnings),
       missingSymbols = List<String>.unmodifiable(missingSymbols) {
    RollingScanCoverage(
      totalCount: coverageTotalCount,
      scannedCount: coverageScannedCount,
      evaluatedCount: coverageEvaluatedCount,
      remainingCount: coverageRemainingCount,
      round: coverageRound,
      pageStart: scanPageStart,
      pageSize: scanPageSize,
      fingerprint: universeFingerprint,
      universeCount: universeCount,
    );
  }

  /// A diagnostic terminal state, never a successful scan or a quote cache.
  /// Zero means the universe has not yet been loaded; no prices are invented.
  factory CandidateSnapshot.fallback({
    required StockMarket marketType,
    required DateTime updatedAt,
    int universeCount = 0,
    int scanPoolSize = 0,
    String reason = '市場評估未完成，請檢查連線後重試。',
  }) => CandidateSnapshot(
    candidates: const [],
    fetchedAt: updatedAt.toUtc(),
    attemptedAt: updatedAt.toUtc(),
    warnings: [reason],
    source: '${marketType == StockMarket.tw ? '台股' : '美股'}市場評估未完成',
    universeCount: universeCount,
    scanPoolSize: scanPoolSize,
    evaluatedCount: 0,
    adrMatchCount: 0,
    universeIsComplete: false,
    stale: true,
    isFallback: true,
  );

  final List<StockCandidate> candidates;
  final DateTime fetchedAt;
  final List<String> warnings;
  final String source;
  final int universeCount;
  final bool stale;
  final List<String> missingSymbols;
  final int? evaluatedCount;

  /// Actual foreground pool, distinct from full market membership.
  final int? scanPoolSize;

  /// Successfully evaluated stocks meeting the configured ADR threshold.
  final int? adrMatchCount;
  final bool universeIsComplete;
  final DateTime? universeAsOf;
  final DateTime? scanCompletedAt;

  /// This timestamp records the failed attempt, not a verified market quote.
  final DateTime? attemptedAt;
  final bool isFallback;

  /// Background job progress is not a generated market snapshot.
  final BackendScanStatus? backendScan;
  final bool isPending;

  /// Round coverage is distinct from this page's scanPoolSize/evaluatedCount.
  /// Failed symbols count as attempted; only verified symbols count as evaluated.
  final int? coverageTotalCount;
  final int? coverageScannedCount;
  final int? coverageEvaluatedCount;
  final int? coverageRemainingCount;
  final int? coverageRound;
  final int? scanPageStart;
  final int? scanPageSize;
  final String? universeFingerprint;

  /// Mobile rolling scans retain candidates from previously evaluated pages.
  final bool candidatesAreCumulative;

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
  RealCandidateRepository({
    required String baseUrl,
    http.Client? client,
    Duration requestTimeout = NetworkRequest.defaultTimeout,
  }) : _baseUri = _parseBaseUrl(baseUrl),
       _network = NetworkRequest(client: client, timeout: requestTimeout);

  final Uri _baseUri;
  final NetworkRequest _network;

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
        'background': 'true',
        'force_refresh': forceRefresh ? 'true' : 'false',
      },
    );
    int? responseStatus;
    try {
      final response = await _network.get(
        endpoint,
        headers: {'Accept': 'application/json'},
      );
      responseStatus = response.statusCode;
      if (response.statusCode != 200 &&
          response.statusCode != 202 &&
          response.statusCode != 503) {
        throw RepositoryException(
          '掃描 API 回應 HTTP ${response.statusCode}，請檢查後端狀態。',
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('回應必須為 JSON 物件。');
      }
      if (decoded.containsKey('scan')) {
        return _parseBackgroundResponse(decoded, market, response.statusCode);
      }
      if (response.statusCode != 200) {
        throw RepositoryException(
          '掃描 API 回應 HTTP ${response.statusCode}，未提供有效掃描進度。',
        );
      }
      // Compatibility with an older server that returns a completed snapshot.
      return _parseSnapshot(decoded, market);
    } on RepositoryException {
      rethrow;
    } on TimeoutException {
      throw const RepositoryException('掃描 API 連線逾時，請稍後重試。');
    } on http.ClientException {
      throw const RepositoryException('無法連線掃描 API，請檢查網址與網路連線。');
    } on FormatException catch (error) {
      // Preserve the HTTP status even when a proxy/server returns non-JSON.
      throw RepositoryException('掃描 API${responseStatus == null ? '' : ' HTTP $responseStatus'} 資料格式錯誤：${error.message}');
    } catch (error) {
      throw RepositoryException('無法讀取掃描結果：${error.runtimeType}。');
    }
  }

  void close() {
    _network.close();
  }
}

CandidateSnapshot _parseBackgroundResponse(
  Map<String, dynamic> json,
  StockMarket market,
  int statusCode,
) {
  if (json['market'] != market.name) {
    throw const FormatException('回應市場與要求市場不符。');
  }
  final scan = json['scan'];
  final retry = json['retry_after_seconds'] ?? 3;
  if (scan is! Map<String, dynamic> || retry is! int) {
    throw const FormatException('掃描進度或重試秒數格式無效。');
  }
  final progress = BackendScanStatus.fromJson(
    scan,
    market: market,
    retryAfterSeconds: retry,
  );
  if (statusCode == 503) {
    throw RepositoryException(
      '後端市場掃描失敗：'
      '${progress.error ?? 'HTTP 503，請稍後重試或檢查伺服器紀錄。'}',
    );
  }
  final snapshot = json['snapshot'];
  if (snapshot != null) {
    if (snapshot is! Map<String, dynamic>) {
      throw const FormatException('snapshot 必須為 JSON 物件或 null。');
    }
    return _parseSnapshot(snapshot, market, backendScan: progress);
  }
  if (statusCode != 202 || !progress.isRunning) {
    throw RepositoryException(
      progress.isFailed
          ? '後端市場掃描失敗：${progress.error ?? '請檢查伺服器紀錄。'}'
          : '後端未回傳已完成的市場快照，請重試。',
    );
  }
  // A 202 settles immediately. The controller owns future polls and must not
  // persist or publish this empty placeholder as an actual completed scan.
  return CandidateSnapshot(
    candidates: const [],
    fetchedAt: progress.updatedAt,
    warnings: const ['後端正在分批掃描；尚未取得已完成的評估快照。'],
    source: 'Python API 背景掃描進度',
    universeCount: progress.universeCount,
    stale: true,
    evaluatedCount: progress.evaluatedCount,
    scanPoolSize: progress.totalCount,
    adrMatchCount: progress.adrMatchCount,
    universeIsComplete: false,
    backendScan: progress,
    isPending: true,
    coverageTotalCount: progress.coverageTotalCount,
    coverageScannedCount: progress.coverageScannedCount,
    coverageEvaluatedCount: progress.coverageEvaluatedCount,
    coverageRemainingCount: progress.coverageRemainingCount,
    coverageRound: progress.coverageRound,
    scanPageStart: progress.scanPageStart,
    scanPageSize: progress.scanPageSize,
    universeFingerprint: progress.universeFingerprint,
  );
}

CandidateSnapshot _parseSnapshot(
  Map<String, dynamic> json,
  StockMarket market, {
  BackendScanStatus? backendScan,
}) {
  if (json['market'] != market.name) {
    throw const FormatException('回應市場與要求市場不符。');
  }
  final source = json['source'];
  final count = json['universe_count'];
  final stale = json['stale'];
  final warnings = json['warnings'];
  final rows = json['candidates'];
  if (source is! String ||
      source.trim().isEmpty ||
      count is! int ||
      count < 0 ||
      stale is! bool ||
      warnings is! List ||
      warnings.any((warning) => warning is! String) ||
      rows is! List) {
    throw const FormatException('來源、股票池數量、快取狀態或候選清單格式無效。');
  }
  if (RegExp(
    r'mock|demo|fictit|假|虛構|示範|離線',
    caseSensitive: false,
  ).hasMatch(source)) {
    throw const FormatException('正式掃描 API 回傳了示範來源，已拒絕載入。');
  }
  final coverage = RollingScanCoverage.fromJson(json, universeCount: count);
  // Envelope failures invalidate the response; a bad individual stock does
  // not invalidate independently verified rows from the same response.
  final generatedAt = parseApiTimestamp(json['generated_at'], 'generated_at');
  final scanCompletedAt =
      json['scan_completed_at'] == null
          ? generatedAt
          : parseApiTimestamp(json['scan_completed_at'], 'scan_completed_at');
  final universeAsOf =
      json['universe_as_of'] == null
          ? null
          : parseApiTimestamp(json['universe_as_of'], 'universe_as_of');
  final evaluated = json['evaluated_count'];
  final scanPoolSize = json['scan_pool_size'];
  final adrMatchCount = json['adr_match_count'];
  final complete = json['universe_is_complete'];
  if ((evaluated != null &&
          (evaluated is! int || evaluated < 0 || evaluated > count)) ||
      (scanPoolSize != null &&
          (scanPoolSize is! int ||
              scanPoolSize < 0 ||
              scanPoolSize > count ||
              (evaluated is int && evaluated > scanPoolSize))) ||
      (adrMatchCount != null &&
          (adrMatchCount is! int ||
              adrMatchCount < 0 ||
              adrMatchCount > (evaluated is int ? evaluated : count))) ||
      (complete != null && complete is! bool)) {
    throw const FormatException('已評估數量或完整股票池旗標格式無效。');
  }
  final missing = json['missing_symbols'];
  if (missing != null &&
      (missing is! List ||
          missing.any((item) => item is! String || item.trim().isEmpty))) {
    throw const FormatException('missing_symbols 必須為非空字串陣列。');
  }
  final candidates = <String, StockCandidate>{};
  final seenSymbols = <String>{};
  final failedSymbols = <String>{};
  final rowWarnings = <String>[];
  var rejectedRows = 0;
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final rawSymbol = row is Map<String, dynamic> ? row['symbol'] : null;
    final symbol =
        rawSymbol is String && rawSymbol.trim().isNotEmpty
            ? rawSymbol.trim()
            : null;
    try {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('個股資料必須為 JSON 物件。');
      }
      if (symbol != null && !seenSymbols.add(symbol)) {
        // A duplicate is ambiguous. Remove every copy of this stock, retaining
        // unrelated symbols instead of choosing whichever copy arrived first.
        if (candidates.remove(symbol) != null) rejectedRows++;
        throw const FormatException('重複股票代碼，該股票所有候選已排除。');
      }
      final candidate = StockCandidate.fromJson(row);
      final validSymbol = (market == StockMarket.tw
              ? RegExp(r'^\d{4}\.(?:TW|TWO)$')
              : RegExp(r'^[A-Z][A-Z0-9-]{0,14}$'))
          .hasMatch(candidate.symbol);
      if (candidate.market != market || !validSymbol) {
        throw const FormatException('個股市場或標準股票代碼與要求不符。');
      }
      final latestAllowed = generatedAt.add(const Duration(minutes: 1));
      if (candidate.dataTimestamp.isAfter(latestAllowed) ||
          (candidate.signalTimestamp?.isAfter(latestAllowed) ?? false)) {
        throw const FormatException('個股行情或訊號時間晚於掃描回應時間。');
      }
      candidates[candidate.symbol] = candidate;
    } catch (error) {
      rejectedRows++;
      if (symbol != null && failedSymbols.length < 1000) {
        failedSymbols.add(_boundedCandidateMessage(symbol, 40));
      }
      if (rowWarnings.length < 20) {
        final label = symbol ?? '第 ${index + 1} 筆候選';
        final reason =
            error is FormatException
                ? error.message
                : error.runtimeType.toString();
        rowWarnings.add(
          '${_boundedCandidateMessage(label, 40)} 已排除：'
          '${_boundedCandidateMessage(reason.toString(), 160)}',
        );
      }
    }
  }
  if (count < candidates.length ||
      (evaluated is int && evaluated < candidates.length)) {
    throw const FormatException('股票池或已評估數量小於有效候選股票數量。');
  }
  if (rows.isNotEmpty && candidates.isEmpty) {
    // A valid genuinely empty scan is allowed. A nonempty corrupt response
    // must fail so the controller retains its previous timestamped snapshot.
    throw FormatException('非空候選清單全部無法驗證：${rowWarnings.join('；')}');
  }
  final combinedWarnings = <String>[
    ...warnings
        .cast<String>()
        .take(100)
        .map((warning) => _boundedCandidateMessage(warning, 240)),
    if (rejectedRows > 0) '已隔離 $rejectedRows 筆無效候選，其他有效股票仍可查看。',
    ...rowWarnings,
    if (rejectedRows > rowWarnings.length)
      '另有 ${rejectedRows - rowWarnings.length} 筆無效候選；詳細警告最多顯示 20 筆。',
  ];
  return CandidateSnapshot(
    candidates: candidates.values.toList(),
    fetchedAt: generatedAt,
    warnings: combinedWarnings,
    source: source,
    universeCount: count,
    stale: stale,
    backendScan: backendScan,
    evaluatedCount: evaluated is int ? evaluated : null,
    scanPoolSize: scanPoolSize is int ? scanPoolSize : null,
    adrMatchCount: adrMatchCount is int ? adrMatchCount : null,
    universeIsComplete: complete != false,
    universeAsOf: universeAsOf,
    scanCompletedAt: scanCompletedAt,
    coverageTotalCount: coverage.totalCount,
    coverageScannedCount: coverage.scannedCount,
    coverageEvaluatedCount: coverage.evaluatedCount,
    coverageRemainingCount: coverage.remainingCount,
    coverageRound: coverage.round,
    scanPageStart: coverage.pageStart,
    scanPageSize: coverage.pageSize,
    universeFingerprint: coverage.fingerprint,
    missingSymbols:
        <String>{
          if (missing is List)
            ...missing
                .cast<String>()
                .take(1000)
                .map((symbol) => _boundedCandidateMessage(symbol, 40)),
          ...failedSymbols.where((symbol) => !candidates.containsKey(symbol)),
        }.take(1000).toList(),
  );
}

String _boundedCandidateMessage(String value, int maximum) =>
    value.length <= maximum ? value : '${value.substring(0, maximum)}…';

Uri _parseBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
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
    final candidates =
        _mockCandidates(
          market,
        ).where((candidate) => candidate.adrPercent >= adrThreshold).toList();
    return CandidateSnapshot(
      candidates: candidates,
      fetchedAt: _demoTime,
      warnings: const [
        '離線示範：報價、ADR、RS 與訊號全部為固定假資料，並非即時掃描。',
        '資料僅含範例股票，未掃描完整台股上市櫃或美股三大交易所股票池。',
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
  final specs =
      market == StockMarket.tw
          ? <_MockSpec>[
            const _MockSpec(
              '2330.TW',
              '台積電',
              '半導體',
              1120,
              5.3,
              99,
              1,
              true,
              'PDH 突破',
              2.0,
            ),
            const _MockSpec(
              '2317.TW',
              '鴻海',
              '電子製造',
              220,
              4.1,
              95,
              2,
              true,
              'ORH 突破・Episodic Pivot',
              2.5,
            ),
            const _MockSpec(
              '2454.TW',
              '聯發科',
              'IC 設計',
              1390,
              4.9,
              93,
              3,
              true,
              '均線密集收斂',
              null,
            ),
            const _MockSpec(
              '2382.TW',
              '廣達',
              '電腦週邊',
              320,
              6.1,
              90,
              4,
              true,
              'PDH 突破',
              1.5,
            ),
            const _MockSpec(
              '3017.TW',
              '奇鋐',
              '散熱',
              650,
              6.8,
              88,
              5,
              false,
              'ORH 突破',
              3.0,
            ),
            const _MockSpec(
              '1519.TW',
              '華城',
              '電機機械',
              710,
              7.2,
              86,
              6,
              false,
              'PDH 突破',
              2.0,
            ),
            const _MockSpec(
              '2308.TW',
              '台達電',
              '電子零組件',
              420,
              4.0,
              82,
              7,
              true,
              '均線密集收斂',
              null,
            ),
            const _MockSpec(
              '2376.TW',
              '技嘉',
              '電腦週邊',
              295,
              5.6,
              80,
              8,
              false,
              'ORH 突破',
              2.5,
            ),
          ]
          : <_MockSpec>[
            const _MockSpec(
              'NVDA',
              'NVIDIA',
              '資訊科技',
              140,
              7.1,
              99,
              1,
              true,
              'PDH 突破',
              2.0,
            ),
            const _MockSpec(
              'TSLA',
              'Tesla',
              '非必需消費品',
              270,
              8.2,
              96,
              2,
              true,
              'ORH 突破・Episodic Pivot',
              2.5,
            ),
            const _MockSpec(
              'AMD',
              'Advanced Micro Devices',
              '資訊科技',
              165,
              6.9,
              93,
              3,
              true,
              '均線密集收斂',
              null,
            ),
            const _MockSpec(
              'META',
              'Meta Platforms',
              '通訊服務',
              610,
              5.6,
              90,
              4,
              true,
              'PDH 突破',
              1.5,
            ),
            const _MockSpec(
              'AVGO',
              'Broadcom',
              '資訊科技',
              188,
              6.2,
              88,
              5,
              true,
              'ORH 突破',
              3.0,
            ),
            const _MockSpec(
              'PLTR',
              'Palantir Technologies',
              '資訊科技',
              45,
              8.8,
              85,
              6,
              false,
              'PDH 突破',
              2.0,
            ),
            const _MockSpec(
              'NFLX',
              'Netflix',
              '通訊服務',
              720,
              5.3,
              83,
              7,
              true,
              '均線密集收斂',
              null,
            ),
            const _MockSpec(
              'MU',
              'Micron Technology',
              '資訊科技',
              106,
              6.5,
              80,
              8,
              false,
              'ORH 突破',
              2.5,
            ),
          ];
  return specs.map((spec) {
    final stop =
        spec.stopPercent == null
            ? null
            : double.parse(
              (spec.price * (1 - spec.stopPercent! / 100)).toStringAsFixed(4),
            );
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
      triggerType:
          spec.pattern.contains('PDH')
              ? 'PDH'
              : spec.pattern.contains('ORH')
              ? 'ORH'
              : null,
      stopSource:
          stop == null
              ? null
              : spec.pattern.contains('ORH')
              ? 'opening_range_low'
              : 'day_low',
      openingRangeLow: spec.pattern.contains('ORH') ? stop : null,
      hybrid: HybridAssessment(
        checks: {
          for (final key in HybridAssessment.requiredChecks)
            key: CheckState.passed,
        },
        notes: const ['僅為離線展示的合成驗證狀態，非真實行情證據'],
      ),
      dayLow: stop,
      isLargeLiquid: spec.large,
      status: stop == null ? 'watchlist' : 'confirmed',
      dataTimestamp: _demoTime,
      signalTimestamp: stop == null ? null : _demoTime,
      notes: const ['假資料示範；不可據此認定當前報價或真實突破。', '風險預算未包含跳空、滑價與交易成本。'],
      dailyCloses: List<double>.generate(
        40,
        (index) => double.parse(
          (spec.price * (0.83 + index * 0.004 + (index % 5 - 2) * 0.003))
              .toStringAsFixed(2),
        ),
      ),
    );
  }).toList();
}

class _MockSpec {
  const _MockSpec(
    this.symbol,
    this.name,
    this.sector,
    this.price,
    this.adr,
    this.rs,
    this.rank,
    this.large,
    this.pattern,
    this.stopPercent,
  );
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
