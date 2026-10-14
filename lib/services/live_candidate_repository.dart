import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/market_data.dart';
import '../models/stock_candidate.dart';
import '../models/stock_item.dart';
import 'candidate_repository.dart';
import 'live_strategy_engine.dart';
import 'market_data_api.dart';
import 'stock_universe_service.dart';

/// Serverless market scanner. It evaluates every returned universe member,
/// using four workers and a bounded foreground deadline. A deadline produces
/// explicit partial coverage, never a claim that unvisited symbols passed.
class DirectLiveCandidateRepository implements CandidateRepository {
  DirectLiveCandidateRepository({MarketDataApi? api, StockUniverseService? universe,
    SharedPreferences? preferences, DateTime Function()? now,
    this.scanBudget = const Duration(minutes: 3)})
      : _api = api ?? MarketDataApi(preferences: preferences, now: now),
        _universe = universe ?? StockUniverseService(preferences: preferences, now: now),
        _ownsApi = api == null, _ownsUniverse = universe == null,
        _preferences = preferences, _now = now ?? DateTime.now;

  final MarketDataApi _api;
  final StockUniverseService _universe;
  final bool _ownsApi, _ownsUniverse;
  final DateTime Function() _now;
  final Duration scanBudget;
  SharedPreferences? _preferences;
  final _engine = const LiveStrategyEngine();
  final Map<String, CandidateSnapshot> _snapshots = {};
  final Map<String, Future<CandidateSnapshot>> _pending = {};
  final Map<StockMarket, Map<String, StockItem>> _members = {};
  bool _closed = false;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {required double adrThreshold,
    bool forceRefresh = false, bool refreshQuotesOnly = false}) {
    if (_closed) throw StateError('行情掃描服務已關閉。');
    if (!adrThreshold.isFinite || adrThreshold < 0) throw ArgumentError.value(adrThreshold);
    final key = '${market.name}:$adrThreshold';
    // Coalesce overlap from a pull gesture, timer and market tab switch.
    return _pending[key] ??= _fetch(market, adrThreshold, forceRefresh, refreshQuotesOnly)
        .whenComplete(() => _pending.remove(key));
  }

  Future<CandidateSnapshot> _fetch(StockMarket market, double threshold,
      bool force, bool quotesOnly) async {
    final key = '${market.name}:$threshold';
    final previous = _snapshots[key] ?? await _loadCache(market, threshold);
    final scanTime = previous?.scanCompletedAt ?? previous?.fetchedAt;
    final recentlyScanned = scanTime != null &&
        _now().toUtc().difference(scanTime) < const Duration(minutes: 15);
    if (previous != null && !force && recentlyScanned) {
      return _refreshHotQuotes(market, threshold, previous);
    }
    try {
      final universe = await _universe.load(market, forceRefresh: force);
      _members[market] = {for (final stock in universe.stocks) stock.symbol: stock};
      final benchmark = await _api.fetchBenchmark(market, forceRefresh: force);
      if (benchmark.isStale) throw const RepositoryException('大盤行情為過期快取，無法建立新的 RS 排名。');
      final deadline = _now().toUtc().add(scanBudget);
      final stopwatch = Stopwatch()..start();
      final evaluations = <LiveEvaluation>[];
      final missing = <String>{};
      var cursor = 0, consecutiveFailures = 0;
      Future<void> worker() async {
        while (!_closed && cursor < universe.stocks.length &&
            stopwatch.elapsed < scanBudget && _now().toUtc().isBefore(deadline) &&
            consecutiveFailures < 12) {
          final stock = universe.stocks[cursor++];
          try {
            // Daily data is enough to reject low ADR. Intraday requests are
            // reserved for ADR-qualified stocks instead of 3 requests × 800.
            final daily = await _api.fetchDaily(stock.symbol, market, forceRefresh: force);
            if (daily.isStale) throw const FormatException('日 K 為過期快取。');
            final adr = _engine.adrPercent(daily.completedDailyBars);
            var bundle = ChartBundle(daily: daily);
            if (adr >= threshold) {
              try {
                final intraday = await _api.fetchIntraday(stock.symbol, market, forceRefresh: force);
                bundle = ChartBundle(daily: daily, intraday: intraday);
              } catch (error) {
                bundle = ChartBundle(daily: daily, intradayError: '盤中資料取得失敗：$error');
              }
            }
            evaluations.add(_engine.evaluate(stock: stock, data: bundle,
                benchmark: benchmark, now: _now().toUtc()));
            consecutiveFailures = 0;
          } catch (_) {
            missing.add(stock.symbol);
            consecutiveFailures++;
          }
        }
      }
      await Future.wait(List.generate(4, (_) => worker()));
      for (final stock in universe.stocks.skip(cursor)) { missing.add(stock.symbol); }
      if (evaluations.isEmpty) {
        throw const RepositoryException('無股票取得足夠真實日 K，請稍後重試；不載入示範資料。');
      }
      final candidates = _engine.rank(evaluations)
          .where((candidate) => candidate.adrPercent >= threshold).toList();
      final finished = _now().toUtc();
      final snapshot = CandidateSnapshot(candidates: candidates, fetchedAt: finished,
        scanCompletedAt: finished, source: 'Yahoo Finance 直接連網（公開行情可能延遲）',
        universeCount: universe.totalCount, evaluatedCount: evaluations.length,
        universeIsComplete: universe.isComplete, universeAsOf: universe.asOf,
        stale: false, missingSymbols: missing.toList()..sort(), warnings: [
          ...universe.warnings,
          '已評估 ${evaluations.length}/${universe.totalCount} 檔；RS 排名僅涵蓋成功對齊交易日的股票。',
          if (missing.isNotEmpty) '有 ${missing.length} 檔因缺資料、請求失敗或三分鐘掃描期限未完成；下拉更新可重新掃描。',
          '前台每分鐘僅更新前 20 個候選報價；完整股票池掃描間隔至少 15 分鐘，下拉更新可強制掃描。',
          '手機直接請求公開端點可能遇到限流；Web 受跨來源限制時可選擇中繼後端。',
        ]);
      _snapshots[key] = snapshot;
      await _saveCache(market, threshold, snapshot);
      return snapshot;
    } catch (error) {
      if (previous != null) return _stale(previous, '連網掃描失敗：$error');
      if (error is RepositoryException) rethrow;
      throw RepositoryException('真實市場掃描失敗：$error');
    }
  }

  Future<CandidateSnapshot> _refreshHotQuotes(StockMarket market, double threshold,
      CandidateSnapshot previous) async {
    if (previous.candidates.isEmpty) return previous;
    final updated = <String, StockCandidate>{};
    final failed = <String>[];
    final bySymbol = _members[market] ?? {};
    final hot = previous.candidates.take(20).toList();
    var cursor = 0;
    try {
      final benchmark = await _api.fetchBenchmark(market);
      Future<void> worker() async {
        while (!_closed && cursor < hot.length) {
          final candidate = hot[cursor++];
          final stock = bySymbol[candidate.symbol] ?? StockItem(
            market: market, symbol: candidate.symbol,
            code: market == StockMarket.tw ? candidate.symbol.split('.').first : candidate.symbol,
            nameZh: candidate.name, nameFullZh: '', nameEn: candidate.name, abbrEn: '');
          try {
            final bundle = await _api.fetchBundle(stock.symbol, market);
            if (bundle.daily.isStale || bundle.intraday?.isStale == true || benchmark.isStale) {
              throw const FormatException('最新請求僅取得過期快取。');
            }
            final evaluated = _engine.evaluate(stock: stock, data: bundle,
                benchmark: benchmark, now: _now().toUtc());
            // Quote refresh never re-ranks a small hot list as if it were the
            // full evaluated universe. Keep the last complete scan ranking.
            updated[candidate.symbol] = evaluated.toCandidate(
                rsScore: candidate.rsScore, rsRank: candidate.rsRank);
          } catch (_) { failed.add(candidate.symbol); }
        }
      }
      await Future.wait(List.generate(4, (_) => worker()));
      if (updated.isEmpty) return _stale(previous, '候選報價更新失敗，保留上次真實快取。');
      final snapshot = CandidateSnapshot(
        candidates: previous.candidates.map((candidate) => updated[candidate.symbol] ?? candidate).toList(),
        fetchedAt: _now().toUtc(), scanCompletedAt: previous.scanCompletedAt,
        source: previous.source, universeCount: previous.universeCount,
        evaluatedCount: previous.evaluatedCount, universeIsComplete: previous.universeIsComplete,
        universeAsOf: previous.universeAsOf, stale: failed.isNotEmpty,
        missingSymbols: previous.missingSymbols, warnings: [
          ...previous.warnings.where((warning) => !warning.startsWith('本次即時更新')),
          '本次即時更新 ${updated.length}/${hot.length} 個候選；其餘保留卡片原始行情時間。',
          if (failed.isNotEmpty) '部分候選報價失敗：${failed.join(', ')}。',
        ]);
      _snapshots['${market.name}:$threshold'] = snapshot;
      await _saveCache(market, threshold, snapshot);
      return snapshot;
    } catch (error) { return _stale(previous, '候選報價更新失敗：$error'); }
  }

  String _cacheKey(StockMarket market, double threshold) =>
      'martin-live-scan-v1-${market.name}-$threshold';
  Future<SharedPreferences> _prefs() async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<void> _saveCache(StockMarket market, double threshold, CandidateSnapshot snapshot) async {
    try {
      await (await _prefs()).setString(_cacheKey(market, threshold), jsonEncode({
        'schema': 1, 'fetched_at': snapshot.fetchedAt.toUtc().toIso8601String(),
        'scan_completed_at': snapshot.scanCompletedAt?.toUtc().toIso8601String(),
        'source': snapshot.source, 'universe_count': snapshot.universeCount,
        'evaluated_count': snapshot.evaluatedCount, 'universe_is_complete': snapshot.universeIsComplete,
        'universe_as_of': snapshot.universeAsOf?.toUtc().toIso8601String(),
        'warnings': snapshot.warnings, 'missing_symbols': snapshot.missingSymbols,
        'candidates': snapshot.candidates.map((candidate) => candidate.toJson()).toList(),
      }));
    } catch (_) { /* Cache failure must not discard successfully fetched quotes. */ }
  }

  Future<CandidateSnapshot?> _loadCache(StockMarket market, double threshold) async {
    try {
      final value = (await _prefs()).getString(_cacheKey(market, threshold));
      if (value == null) return null;
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data['schema'] != 1) return null;
      final fetched = DateTime.parse(data['fetched_at'] as String).toUtc();
      final age = _now().toUtc().difference(fetched);
      if (age.isNegative || age > const Duration(hours: 24)) return null;
      final candidates = (data['candidates'] as List).map((row) =>
          StockCandidate.fromJson(row as Map<String, dynamic>)).toList();
      if (candidates.any((candidate) => candidate.market != market || candidate.adrPercent < threshold)) return null;
      return CandidateSnapshot(candidates: candidates, fetchedAt: fetched,
        scanCompletedAt: data['scan_completed_at'] == null ? fetched :
            DateTime.parse(data['scan_completed_at'] as String).toUtc(),
        source: data['source'] as String, universeCount: data['universe_count'] as int,
        evaluatedCount: data['evaluated_count'] as int?,
        universeIsComplete: data['universe_is_complete'] as bool,
        universeAsOf: data['universe_as_of'] == null ? null : DateTime.parse(data['universe_as_of'] as String).toUtc(),
        stale: true, warnings: [...(data['warnings'] as List).cast<String>(), '顯示上次真實行情快取，尚待連網更新。'],
        missingSymbols: (data['missing_symbols'] as List).cast<String>());
    } catch (_) { return null; }
  }

  CandidateSnapshot _stale(CandidateSnapshot previous, String warning) => CandidateSnapshot(
    candidates: previous.candidates, fetchedAt: previous.fetchedAt,
    scanCompletedAt: previous.scanCompletedAt, source: '${previous.source}／上次真實快取',
    universeCount: previous.universeCount, evaluatedCount: previous.evaluatedCount,
    universeIsComplete: previous.universeIsComplete, universeAsOf: previous.universeAsOf,
    stale: true, missingSymbols: previous.missingSymbols,
    warnings: [...previous.warnings, warning]);

  void close() {
    _closed = true;
    if (_ownsApi) _api.close();
    if (_ownsUniverse) _universe.close();
  }
}
