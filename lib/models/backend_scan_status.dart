import 'stock_candidate.dart';

/// Server-side scan progress. Its timestamps describe work, never quote age.
class BackendScanStatus {
  const BackendScanStatus({
    required this.market,
    required this.jobId,
    required this.status,
    required this.stage,
    required this.updatedAt,
    required this.completedCount,
    required this.totalCount,
    required this.evaluatedCount,
    required this.adrMatchCount,
    required this.failedCount,
    required this.universeCount,
    this.startedAt,
    this.completedAt,
    this.error,
    this.retryAfterSeconds = 3,
    this.coverageTotalCount,
    this.coverageScannedCount,
    this.coverageEvaluatedCount,
    this.coverageRemainingCount,
    this.coverageRound,
    this.scanPageStart,
    this.scanPageSize,
    this.universeFingerprint,
  });

  final StockMarket market;
  final String jobId;
  final String status;
  final String stage;
  final DateTime? startedAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final int completedCount;
  final int totalCount;
  final int evaluatedCount;
  final int adrMatchCount;
  final int failedCount;
  final int universeCount;
  final String? error;
  final int retryAfterSeconds;
  final int? coverageTotalCount;
  final int? coverageScannedCount;
  final int? coverageEvaluatedCount;
  final int? coverageRemainingCount;
  final int? coverageRound;
  final int? scanPageStart;
  final int? scanPageSize;
  final String? universeFingerprint;

  bool get isRunning => status == 'queued' || status == 'running';
  bool get isFailed => status == 'failed';

  factory BackendScanStatus.fromJson(
    Map<String, dynamic> json, {
    required StockMarket market,
    int retryAfterSeconds = 3,
  }) {
    String text(String field) {
      final value = json[field];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('scan.$field 必須為非空字串。');
      }
      return value.trim();
    }

    int count(String field) {
      final value = json[field];
      if (value is! int || value < 0) {
        throw FormatException('scan.$field 必須為非負整數。');
      }
      return value;
    }

    // The envelope owns the market. If a provider duplicates it in scan,
    // require consistency instead of silently accepting mixed-market state.
    if (json.containsKey('market') && json['market'] != market.name) {
      throw const FormatException('掃描進度市場與要求市場不符。');
    }
    final jobId = text('job_id');
    final status = text('status');
    final stage = text('stage');
    if (!const ['queued', 'running', 'completed', 'failed'].contains(status)) {
      throw const FormatException('scan.status 無法辨識。');
    }
    if (retryAfterSeconds < 1 || retryAfterSeconds > 60) {
      throw const FormatException('retry_after_seconds 必須介於 1–60 秒。');
    }
    final startedAt = json['started_at'] == null
        ? null
        : parseApiTimestamp(json['started_at'], 'scan.started_at');
    final updatedAt = parseApiTimestamp(json['updated_at'], 'scan.updated_at');
    final completedAt = json['completed_at'] == null
        ? null
        : parseApiTimestamp(json['completed_at'], 'scan.completed_at');
    if ((startedAt != null && updatedAt.isBefore(startedAt)) ||
        (completedAt != null && updatedAt.isBefore(completedAt)) ||
        (startedAt != null && completedAt != null &&
            completedAt.isBefore(startedAt))) {
      throw const FormatException('掃描進度時間先後順序無效。');
    }
    final completed = count('completed_count');
    final total = count('total_count');
    final evaluated = count('evaluated_count');
    final adr = count('adr_match_count');
    final failed = count('failed_count');
    final universe = count('universe_count');
    final coverage = RollingScanCoverage.fromJson(json, universeCount: universe);
    if (completed > total || total > universe || evaluated > completed ||
        failed > completed || evaluated + failed > completed || adr > evaluated) {
      throw const FormatException('掃描進度計數互相矛盾。');
    }
    final terminal = status == 'completed' || status == 'failed';
    if ((terminal && completedAt == null) ||
        (!terminal && completedAt != null) ||
        (status == 'completed' && completed != total)) {
      throw const FormatException('掃描完成狀態、完成時間或已處理數量不一致。');
    }
    final error = json['error'];
    if (error != null && (error is! String || error.trim().isEmpty)) {
      throw const FormatException('scan.error 必須為非空字串或 null。');
    }
    return BackendScanStatus(
      market: market,
      jobId: jobId,
      status: status,
      stage: stage,
      startedAt: startedAt,
      updatedAt: updatedAt,
      completedAt: completedAt,
      completedCount: completed,
      totalCount: total,
      evaluatedCount: evaluated,
      adrMatchCount: adr,
      failedCount: failed,
      universeCount: universe,
      error: error is String ? _bounded(error, 400) : null,
      retryAfterSeconds: retryAfterSeconds,
      coverageTotalCount: coverage.totalCount,
      coverageScannedCount: coverage.scannedCount,
      coverageEvaluatedCount: coverage.evaluatedCount,
      coverageRemainingCount: coverage.remainingCount,
      coverageRound: coverage.round,
      scanPageStart: coverage.pageStart,
      scanPageSize: coverage.pageSize,
      universeFingerprint: coverage.fingerprint,
    );
  }

  /// A stopped client poll is distinct from a new server result. In particular,
  /// do not move updatedAt forward or imply that a quote was refreshed.
  BackendScanStatus withClientFailure(String message) => BackendScanStatus(
    market: market,
    jobId: jobId,
    status: 'failed',
    stage: 'client_error',
    startedAt: startedAt,
    updatedAt: updatedAt,
    completedAt: completedAt,
    completedCount: completedCount,
    totalCount: totalCount,
    evaluatedCount: evaluatedCount,
    adrMatchCount: adrMatchCount,
    failedCount: failedCount,
    universeCount: universeCount,
    error: _bounded(message.trim().isEmpty ? '無法繼續讀取掃描進度。' : message, 400),
    retryAfterSeconds: retryAfterSeconds,
    coverageTotalCount: coverageTotalCount,
    coverageScannedCount: coverageScannedCount,
    coverageEvaluatedCount: coverageEvaluatedCount,
    coverageRemainingCount: coverageRemainingCount,
    coverageRound: coverageRound,
    scanPageStart: scanPageStart,
    scanPageSize: scanPageSize,
    universeFingerprint: universeFingerprint,
  );
}

/// Validated optional wire extension. A legacy response omits the whole group;
/// a partial group must not claim complete rolling-universe coverage.
class RollingScanCoverage {
  RollingScanCoverage({
    this.totalCount,
    this.scannedCount,
    this.evaluatedCount,
    this.remainingCount,
    this.round,
    this.pageStart,
    this.pageSize,
    this.fingerprint,
    int? universeCount,
  }) {
    final counts = [totalCount, scannedCount, evaluatedCount, remainingCount,
      round, pageStart, pageSize];
    if (counts.every((value) => value == null) && fingerprint == null) return;
    if (counts.any((value) => value == null || value < 0) ||
        fingerprint == null || fingerprint!.trim().isEmpty ||
        fingerprint!.length > 256) {
      throw const FormatException('輪巡股票池統計必須提供完整非負整數及有效指紋。');
    }
    if (totalCount != scannedCount! + remainingCount! ||
        evaluatedCount! > scannedCount! || round! < 1 ||
        pageStart! > totalCount! || pageSize! > totalCount! ||
        pageStart! + pageSize! > totalCount! ||
        (universeCount != null && totalCount! > universeCount)) {
      throw const FormatException('輪巡股票池覆蓋數量、頁面範圍或輪次互相矛盾。');
    }
  }

  final int? totalCount;
  final int? scannedCount;
  final int? evaluatedCount;
  final int? remainingCount;
  final int? round;
  final int? pageStart;
  final int? pageSize;
  final String? fingerprint;

  factory RollingScanCoverage.fromJson(Map<String, dynamic> json,
      {required int universeCount}) {
    int? count(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int || value < 0) {
        throw FormatException('$key 必須為非負整數或 null。');
      }
      return value;
    }
    final fingerprint = json['universe_fingerprint'];
    if (fingerprint != null && fingerprint is! String) {
      throw const FormatException('universe_fingerprint 必須為字串或 null。');
    }
    return RollingScanCoverage(
      totalCount: count('coverage_total_count'),
      scannedCount: count('coverage_scanned_count'),
      evaluatedCount: count('coverage_evaluated_count'),
      remainingCount: count('coverage_remaining_count'),
      round: count('coverage_round'),
      pageStart: count('scan_page_start'),
      pageSize: count('scan_page_size'),
      fingerprint: fingerprint as String?,
      universeCount: universeCount,
    );
  }
}

String _bounded(String value, int maximum) =>
    value.length <= maximum ? value : '${value.substring(0, maximum)}…';
