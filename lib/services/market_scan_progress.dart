import '../models/stock_candidate.dart';
import 'candidate_repository.dart';

/// A bounded core scan is different from complete exchange membership.
/// Counts refer to stocks, never to the number of HTTP calls per stock.
class MarketScanProgress {
  const MarketScanProgress({required this.market, required this.universeCount,
    required this.poolSize, required this.attemptedCount,
    required this.completedCount, required this.evaluatedCount,
    required this.adrMatchCount, required this.confirmedCount,
    required this.failedCount, required this.finished, required this.stage,
    this.partialSnapshot});

  final StockMarket market;
  final int universeCount, poolSize, attemptedCount, completedCount;
  final int evaluatedCount, adrMatchCount, confirmedCount, failedCount;
  final bool finished;
  final String stage;

  /// Only completed, validated provider observations are included. A progress
  /// snapshot is not a completed scan or a successful cache transaction; the
  /// controller may keep it if the outer deadline interrupts this run.
  final CandidateSnapshot? partialSnapshot;

  double get fraction => poolSize <= 0 ? 0
      : (completedCount / poolSize).clamp(0.0, 1.0).toDouble();

  String get label => poolSize <= 0 ? stage
      : '$stage · 已掃描 $completedCount/$poolSize 檔'
        ' · ADR $adrMatchCount · 確認 $confirmedCount'
        '${failedCount > 0 ? ' · 失敗 $failedCount' : ''}';
}

/// Existing repositories can continue to implement CandidateRepository only.
/// Controllers opt in to progress when the repository exposes this interface.
abstract interface class ProgressiveCandidateRepository
    implements CandidateRepository {
  Future<CandidateSnapshot> fetchWithProgress(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
    void Function(MarketScanProgress)? onProgress,
  });
}
