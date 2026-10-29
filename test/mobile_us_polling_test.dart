import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Scheduling fixtures only. No synthetic fixture is live-market gate evidence.
final _now = DateTime.utc(2026, 10, 16, 6);

class _Call {
  _Call(this.market, this.force, this.quotesOnly);
  final StockMarket market;
  final bool force;
  final bool quotesOnly;
}

class _Repository implements CandidateRepository {
  final calls = <_Call>[];
  Future<CandidateSnapshot> Function(_Call)? reply;
  int count(StockMarket market) =>
      calls.where((call) => call.market == market).length;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) {
    final call = _Call(market, forceRefresh, refreshQuotesOnly);
    calls.add(call);
    return reply?.call(call) ?? Future.value(_page(market,
      scanned: count(market) * 30));
  }
}

void _seed({bool autoRefresh = true, bool mock = false,
    String provider = 'direct'}) => SharedPreferences.setMockInitialValues({
  'martin_luk_settings_v1': jsonEncode(AppSettings(
    useMockData: mock, dataProvider: provider,
    apiBaseUrl: 'https://example.invalid', autoRefreshEnabled: autoRefresh,
  ).toJson()),
});

CandidateSnapshot _page(StockMarket market, {
  int scanned = 30, int evaluated = 30, int? coverageEvaluated,
  int total = 5000, int? universe, int pageSize = 30,
  bool stale = false, bool cumulative = true,
  List<StockCandidate> candidates = const [], List<String> warnings = const [],
  String source = 'Yahoo Finance controller fixture',
}) => CandidateSnapshot(
  candidates: candidates, fetchedAt: _now, warnings: warnings, source: source,
  universeCount: universe ?? total, stale: stale,
  evaluatedCount: evaluated, scanPoolSize: pageSize, adrMatchCount: evaluated,
  universeIsComplete: false, universeAsOf: _now, scanCompletedAt: _now,
  candidatesAreCumulative: cumulative,
  coverageTotalCount: total, coverageScannedCount: scanned,
  coverageEvaluatedCount: coverageEvaluated ?? scanned,
  coverageRemainingCount: total - scanned, coverageRound: 1,
  scanPageStart: scanned - pageSize, scanPageSize: pageSize,
  universeFingerprint: 'explicit-${market.name}-controller-fixture',
);

StockCandidate _candidate(String symbol, {bool invalidStop = false}) =>
    StockCandidate(
      id: 'us:$symbol', symbol: symbol, name: symbol, sector: 'Fixture',
      market: StockMarket.us, adrPercent: 6, rsScore: 80, rsRank: 1,
      patterns: const ['PDH'], entryPrice: 100,
      stopPrice: invalidStop ? 97 : null,
      isLargeLiquid: true, status: invalidStop ? 'confirmed' : 'watchlist',
      dataTimestamp: _now, dayLow: invalidStop ? 96 : null,
    );

AppController _controller(_Repository repository) => AppController(
  forceMockPreview: false, repositoryFactory: (_) => repository, now: () => _now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_seed);

  testWidgets('fresh full US coverage advances 30 to 60 to 90 instead of only hot quotes',
      (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      expect(controller.snapshot!.coverageScannedCount, 30);
      controller.setForeground(true);
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 60);
      expect(repository.calls.last.quotesOnly, isFalse);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 90);
      expect(repository.count(StockMarket.us), 3);
      expect(repository.calls.last.quotesOnly, isFalse);
      expect(repository.calls.last.force, isFalse);
      expect(controller.error, isNull);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('manual stops belong to each market and only an explicit pull resumes it',
      (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      controller.setForeground(true);
      await tester.pump();
      controller.cancelMarketEvaluation();
      expect(controller.mobileScanPaused, isTrue);
      final usStoppedAt = repository.count(StockMarket.us);
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      expect(repository.count(StockMarket.us), usStoppedAt);

      final tw = controller.setMarket(StockMarket.tw);
      await tester.pump();
      await tw;
      expect(controller.mobileScanPaused, isFalse);
      controller.cancelMarketEvaluation();
      final twStoppedAt = repository.count(StockMarket.tw);
      final us = controller.setMarket(StockMarket.us);
      await tester.pump();
      await us;
      expect(controller.mobileScanPaused, isTrue);
      expect(repository.count(StockMarket.us), usStoppedAt,
          reason: 'Changing tabs must not undo an explicit stop.');
      final resumed = controller.refresh(forceRefresh: true);
      await tester.pump();
      await resumed;
      expect(controller.mobileScanPaused, isFalse);
      expect(repository.count(StockMarket.us), usStoppedAt + 1);
      expect(repository.calls.last.force, isTrue);
      final backToTw = controller.setMarket(StockMarket.tw);
      await tester.pump();
      await backToTw;
      expect(controller.mobileScanPaused, isTrue);
      expect(repository.count(StockMarket.tw), twStoppedAt,
          reason: 'Resuming US does not resume the independently stopped TW round.');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('without Android service a hidden US page releases its owner and ignores late data',
      (tester) async {
    final repository = _Repository();
    final controller = _controller(repository);
    final pending = Completer<CandidateSnapshot>();
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      final original = controller.snapshot;
      repository.reply = (call) => call.market == StockMarket.us
          ? pending.future : Future.value(_page(call.market));
      controller.setForeground(true);
      await tester.pump();
      expect(controller.loading, isTrue);
      controller.setForeground(false);
      await tester.pump();
      expect(controller.loading, isFalse);
      expect(controller.polling, isFalse);
      expect(controller.autoRefreshActive, isFalse);
      pending.complete(_page(StockMarket.us, scanned: 60));
      await tester.pump();
      expect(controller.snapshot, same(original));
      await tester.pump(const Duration(minutes: 2));
      expect(repository.count(StockMarket.us), 2);
      repository.reply = (call) async => _page(call.market, scanned: 60);
      controller.setForeground(true);
      await tester.pump();
      expect(repository.count(StockMarket.us), 3);
      expect(controller.snapshot!.coverageScannedCount, 60);
      expect(controller.mobileScanPaused, isFalse);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('a failed US page keeps attempted coverage and does not freeze the next page',
      (tester) async {
    final repository = _Repository();
    repository.reply = (call) async {
      final pages = repository.count(call.market);
      if (call.market == StockMarket.us && pages == 2) {
        return _page(call.market, scanned: 60, evaluated: 0,
          coverageEvaluated: 30, stale: true,
          warnings: const ['30 real requests failed; no prices substituted.']);
      }
      return _page(call.market, scanned: pages * 30,
        coverageEvaluated: pages == 3 ? 60 : pages * 30);
    };
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      controller.setForeground(true);
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 60);
      expect(controller.snapshot!.coverageEvaluatedCount, 30);
      expect(controller.snapshot!.evaluatedCount, 0);
      expect(controller.snapshot!.stale, isTrue);
      expect(controller.loading, isFalse);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 90);
      expect(controller.snapshot!.coverageEvaluatedCount, 60);
      expect(controller.snapshot!.stale, isFalse);
      expect(repository.calls.last.quotesOnly, isFalse);
    } finally {
      controller.dispose();
    }
  });

  test('US cumulative cards may exceed one page but never exceed round evaluations', () async {
    _seed(autoRefresh: false);
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      repository.reply = (call) async => _page(call.market,
        total: 3, scanned: 2, pageSize: 1, evaluated: 1,
        candidates: [_candidate('AAPL'), _candidate('NVDA')]);
      await controller.setMarket(StockMarket.us);
      expect(controller.error, isNull);
      expect(controller.snapshot!.candidates.length, 2);
      expect(controller.snapshot!.evaluatedCount, 1);
      repository.reply = (call) async => _page(call.market,
        total: 3, scanned: 2, pageSize: 1, evaluated: 1, coverageEvaluated: 1,
        candidates: [_candidate('AAPL'), _candidate('NVDA')]);
      await controller.refresh();
      expect(controller.error, contains('有效候選數量超過'));
      expect(controller.snapshot!.stale, isTrue);
      expect(controller.snapshot!.coverageEvaluatedCount, 2);
    } finally {
      controller.dispose();
    }
  });

  test('US cumulative flag requires all coverage and exact universe size', () async {
    _seed(autoRefresh: false);
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      repository.reply = (_) async => CandidateSnapshot(
        candidates: const [], fetchedAt: _now, warnings: const [],
        source: 'Yahoo Finance fixture', universeCount: 300, stale: false,
        evaluatedCount: 30, scanPoolSize: 30, adrMatchCount: 0,
        candidatesAreCumulative: true);
      await controller.setMarket(StockMarket.us);
      expect(controller.error, contains('累積候選僅允許'));
      expect(controller.snapshot!.isFallback, isTrue);
      repository.reply = (call) async => _page(call.market,
        total: 4999, universe: 5000);
      await controller.refresh();
      expect(controller.error, contains('累積候選僅允許'));
      expect(controller.snapshot!.isFallback, isTrue);
    } finally {
      controller.dispose();
    }
  });

  for (final provider in ['backend', 'mock']) {
    test('$provider cannot impersonate a cumulative direct US round', () async {
      _seed(autoRefresh: false, provider: provider == 'mock' ? 'direct' : provider,
        mock: provider == 'mock');
      final repository = _Repository();
      final controller = _controller(repository);
      try {
        await controller.initialize(initializeReminders: false);
        await controller.setMarket(StockMarket.us);
        expect(controller.error, contains('累積候選僅允許'));
        expect(controller.snapshot!.isFallback, isTrue);
      } finally {
        controller.dispose();
      }
    });
  }

  test('US cumulative scope retains production-source and observed-stop validation', () async {
    _seed(autoRefresh: false);
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      repository.reply = (call) async => _page(call.market,
        source: 'mock quotes', candidates: [_candidate('NVDA')]);
      await controller.setMarket(StockMarket.us);
      expect(controller.error, contains('來源或股票池統計無效'));
      repository.reply = (call) async => _page(call.market,
        candidates: [_candidate('NVDA', invalidStop: true)]);
      await controller.refresh();
      expect(controller.error, contains('候選資料全部無效'));
      expect(controller.snapshot!.isFallback, isTrue);
    } finally {
      controller.dispose();
    }
  });
}
