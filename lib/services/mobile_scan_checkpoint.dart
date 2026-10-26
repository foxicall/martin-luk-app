import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'candidate_repository.dart';

/// An immutable, versioned market scan journal. Quote timestamps remain on
/// each candidate; [updatedAt] only records progress, never a refreshed quote.
/// The attempted set MUST be a contiguous prefix of the sorted member list,
/// so a deadline cannot accidentally skip unvisited members on the next page.
class MobileScanCheckpoint {
  MobileScanCheckpoint({
    this.market = StockMarket.tw,
    required List<String> symbols,
    required this.threshold,
    required this.day,
    required this.round,
    required Set<String> attempted,
    required Set<String> evaluated,
    required List<StockCandidate> candidates,
    required this.updatedAt,
    required this.universeAsOf,
    required this.universeIsComplete,
    required List<String> warnings,
    List<StockItem> members = const [],
    List<String> universeWarnings = const [],
    this.roundCompletedAt,
    this.pageStart = 0,
    this.pageSize = 0,
    this.pageEvaluated = 0,
    this.pageAdrMatches = 0,
    this.pageScanCompletedAt,
    this.pageStale = false,
  }) : symbols = List<String>.unmodifiable(symbols),
       attempted = Set<String>.unmodifiable(attempted),
       evaluated = Set<String>.unmodifiable(evaluated),
       candidates = List<StockCandidate>.unmodifiable(candidates),
       members = List<StockItem>.unmodifiable(members),
       universeWarnings = List<String>.unmodifiable(universeWarnings),
       warnings = List<String>.unmodifiable(warnings) {
    if (!threshold.isFinite ||
        threshold < 0 ||
        round < 1 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        this.symbols.isEmpty ||
        this.symbols.length > 20000 ||
        this.symbols.toSet().length != this.symbols.length ||
        this.symbols.any((s) => !isCanonicalSymbol(s, market))) {
      throw const FormatException('手機掃描檢查點的市場、名單或參數無效。');
    }
    for (var index = 1; index < this.symbols.length; index++) {
      if (this.symbols[index - 1].compareTo(this.symbols[index]) >= 0) {
        throw const FormatException('檢查點股票名單必須唯一且依標準代碼排序。');
      }
    }
    final prefix = this.symbols.take(this.attempted.length).toSet();
    final knownSymbols = this.symbols.toSet();
    if (this.attempted.length > this.symbols.length ||
        !this.attempted.containsAll(prefix) ||
        !this.attempted.containsAll(this.evaluated) ||
        this.candidates.map((row) => row.symbol).toSet().length !=
            this.candidates.length ||
        this.candidates.any(
          (row) =>
              row.market != market ||
              !this.evaluated.contains(row.symbol) ||
              row.adrPercent < threshold,
        ) ||
        this.members.map((row) => row.symbol).toSet().length !=
            this.members.length ||
        this.members.any(
          (row) => row.market != market || !knownSymbols.contains(row.symbol),
        ) ||
        pageStart < 0 ||
        pageStart > this.attempted.length ||
        pageSize < 0 ||
        pageSize > 30 ||
        pageStart + pageSize > this.symbols.length ||
        pageEvaluated < 0 ||
        pageEvaluated > pageSize ||
        pageEvaluated > this.evaluated.length ||
        pageAdrMatches < 0 ||
        pageAdrMatches > pageEvaluated ||
        (roundCompletedAt != null &&
            this.attempted.length != this.symbols.length)) {
      throw const FormatException('手機輪掃的嘗試、成功、候選或頁面數量不一致。');
    }
  }

  final StockMarket market;
  final List<String> symbols;
  final double threshold;
  final String day;
  final int round;
  final Set<String> attempted;
  final Set<String> evaluated;
  final List<StockCandidate> candidates;

  /// Actual source metadata for this round, saved with its pinned symbols.
  /// Optional for legacy schema-1 journals; it never contains market prices.
  final List<StockItem> members;
  final List<String> universeWarnings;
  final DateTime updatedAt;
  final DateTime universeAsOf;
  final bool universeIsComplete;
  final List<String> warnings;
  final DateTime? roundCompletedAt;
  final int pageStart, pageSize, pageEvaluated, pageAdrMatches;
  final DateTime? pageScanCompletedAt;
  final bool pageStale;

  String get fingerprint => fingerprintFor(symbols, market: market);
  int get remaining => symbols.length - attempted.length;

  /// Two small, portable integer hashes identify display/progress versions.
  /// Membership comparisons ALSO check the complete stored list exactly;
  /// hash equality alone is never used to accept different membership.
  static String fingerprintFor(
    List<String> symbols, {
    StockMarket market = StockMarket.tw,
  }) {
    var first = 17, second = 29;
    for (final code in symbols.join('\n').codeUnits) {
      first = (first * 31 + code) % 2147483647;
      second = (second * 131 + code) % 2147483629;
    }
    return '${market.name}-mobile-v1-${symbols.length}-${first.toRadixString(16)}-${second.toRadixString(16)}';
  }

  static bool isCanonicalSymbol(String symbol, StockMarket market) =>
      (market == StockMarket.tw
              ? RegExp(r'^\d{4}\.(TW|TWO)$')
              : RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$'))
          .hasMatch(symbol);

  static bool _usTimeZonesInitialized = false;

  /// Use each exchange's calendar day rather than the device/UTC date.
  /// The optional market preserves the original Taiwan helper signature.
  /// New York uses the existing timezone database for daylight-saving changes.
  static String dayFor(DateTime now, {StockMarket market = StockMarket.tw}) {
    if (market == StockMarket.tw) {
      return now
          .toUtc()
          .add(const Duration(hours: 8))
          .toIso8601String()
          .substring(0, 10);
    }
    if (!_usTimeZonesInitialized) {
      timezone_data.initializeTimeZones();
      _usTimeZonesInitialized = true;
    }
    final local = tz.TZDateTime.from(
      now.toUtc(),
      tz.getLocation('America/New_York'),
    );
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  bool matches(List<String> members, double adrThreshold, DateTime now) {
    if (threshold != adrThreshold ||
        (market == StockMarket.tw && day != dayFor(now, market: market)) ||
        members.length != symbols.length ||
        fingerprintFor(members, market: market) != fingerprint)
      return false;
    for (var index = 0; index < symbols.length; index++) {
      if (members[index] != symbols[index]) return false;
    }
    return true;
  }

  /// A provider returning only one exchange must not reset an active cursor.
  /// Membership changes apply when the current round finishes. Taiwan's
  /// exchange day or ADR configuration invalidates a running Taiwan round.
  /// A large US round continues across New York midnight; otherwise a slow
  /// provider could permanently prevent reaching the end of the member list.
  /// The repository enforces the seven-day saved-progress retention limit.
  bool canResume(double adrThreshold, DateTime now) {
    if (threshold != adrThreshold || remaining <= 0) return false;
    if (market == StockMarket.tw) return day == dayFor(now, market: market);
    final age = now.toUtc().difference(updatedAt);
    return !age.isNegative && age <= const Duration(days: 7);
  }

  CandidateSnapshot toSnapshot({bool fromDisk = false}) => CandidateSnapshot(
    candidates: candidates,
    fetchedAt: updatedAt,
    scanCompletedAt: pageScanCompletedAt,
    attemptedAt: pageStale ? updatedAt : null,
    source:
        'Yahoo Finance 手機${market == StockMarket.tw ? '台股' : '美股'}完整名單分批輪掃（公開行情可能延遲）',
    universeCount: symbols.length,
    evaluatedCount: pageEvaluated,
    scanPoolSize: pageSize,
    adrMatchCount: pageAdrMatches,
    universeIsComplete: universeIsComplete,
    universeAsOf: universeAsOf,
    stale: pageStale || fromDisk,
    candidatesAreCumulative: true,
    coverageTotalCount: symbols.length,
    coverageScannedCount: attempted.length,
    coverageEvaluatedCount: evaluated.length,
    coverageRemainingCount: remaining,
    coverageRound: round,
    scanPageStart: pageStart,
    scanPageSize: pageSize,
    universeFingerprint: fingerprint,
    missingSymbols: attempted.difference(evaluated).toList()..sort(),
    warnings: [...warnings, if (fromDisk) '已還原手機輪掃進度；卡片保留原始行情時間，尚待連網確認。'],
  );

  MobileScanCheckpoint withCandidates(
    List<StockCandidate> values,
    DateTime at,
  ) => MobileScanCheckpoint(
    market: market,
    symbols: symbols,
    threshold: threshold,
    day: day,
    round: round,
    members: members,
    universeWarnings: universeWarnings,
    attempted: attempted,
    evaluated: evaluated,
    candidates: values,
    updatedAt: at,
    universeAsOf: universeAsOf,
    universeIsComplete: universeIsComplete,
    warnings: warnings,
    roundCompletedAt: roundCompletedAt,
    pageStart: pageStart,
    pageSize: pageSize,
    pageEvaluated: pageEvaluated,
    pageAdrMatches: pageAdrMatches,
    pageScanCompletedAt: pageScanCompletedAt,
    pageStale: pageStale,
  );

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'market': market.name,
    'symbols': symbols,
    'fingerprint': fingerprint,
    'threshold': threshold,
    'day': day,
    'round': round,
    'attempted': attempted.toList()..sort(),
    'evaluated': evaluated.toList()..sort(),
    'candidates': candidates.map((row) => row.toJson()).toList(),
    'members': members.map((row) => row.toJson()).toList(),
    'universe_warnings': universeWarnings,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'universe_as_of': universeAsOf.toUtc().toIso8601String(),
    'universe_is_complete': universeIsComplete,
    'warnings': warnings,
    'round_completed_at': roundCompletedAt?.toUtc().toIso8601String(),
    'page_start': pageStart,
    'page_size': pageSize,
    'page_evaluated': pageEvaluated,
    'page_adr_matches': pageAdrMatches,
    'page_scan_completed_at': pageScanCompletedAt?.toUtc().toIso8601String(),
    'page_stale': pageStale,
  };

  factory MobileScanCheckpoint.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1 || !['tw', 'us'].contains(json['market'])) {
      throw const FormatException('未知的手機輪掃檢查點版本。');
    }
    List<String> strings(String name) {
      final value = json[name];
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException('輪掃 $name 必須為字串陣列。');
      }
      return value.cast<String>();
    }

    final checkpoint = MobileScanCheckpoint(
      market: json['market'] == 'us' ? StockMarket.us : StockMarket.tw,
      symbols: strings('symbols'),
      threshold: (json['threshold'] as num).toDouble(),
      day: json['day'] as String,
      round: json['round'] as int,
      attempted: strings('attempted').toSet(),
      evaluated: strings('evaluated').toSet(),
      candidates:
          (json['candidates'] as List)
              .map(
                (row) => StockCandidate.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList(),
      members:
          json['members'] == null
              ? const []
              : (json['members'] as List)
                  .map(
                    (row) => StockItem.fromJson(
                      Map<String, dynamic>.from(row as Map),
                    ),
                  )
                  .toList(),
      universeWarnings:
          json['universe_warnings'] == null
              ? strings('warnings')
              : strings('universe_warnings'),
      updatedAt: parseApiTimestamp(json['updated_at'], 'updated_at'),
      universeAsOf: parseApiTimestamp(json['universe_as_of'], 'universe_as_of'),
      universeIsComplete: json['universe_is_complete'] as bool,
      warnings: strings('warnings'),
      roundCompletedAt:
          json['round_completed_at'] == null
              ? null
              : parseApiTimestamp(
                json['round_completed_at'],
                'round_completed_at',
              ),
      pageStart: json['page_start'] as int,
      pageSize: json['page_size'] as int,
      pageEvaluated: json['page_evaluated'] as int,
      pageAdrMatches: json['page_adr_matches'] as int,
      pageScanCompletedAt:
          json['page_scan_completed_at'] == null
              ? null
              : parseApiTimestamp(
                json['page_scan_completed_at'],
                'page_scan_completed_at',
              ),
      pageStale: json['page_stale'] as bool,
    );
    if (json['fingerprint'] != checkpoint.fingerprint) {
      throw const FormatException('手機輪掃名單指紋驗證失敗。');
    }
    return checkpoint;
  }
}
