import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Deterministic controller fixtures. They test scheduling, validation and
// ownership, and never claim to be actual market or recommendation evidence.
final _now = DateTime.utc(2026, 10, 16, 2);

class _Call {
  _Call(this.market, this.force, this.quotesOnly);
  final StockMarket market;
  final bool force;
  final bool quotesOnly;
}

class _Repository implements CandidateRepository {
  final calls = <_Call>[];
  Future<CandidateSnapshot> Function(_Call call)? reply;

  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold,
    bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) {
    final call = _Call(market, forceRefresh, refreshQuotesOnly);
    calls.add(call);
    return reply?.call(call) ?? Future.value(_page());
  }
}

void _seed({bool autoRefresh = true, String provider = 'direct',
    bool mock = false}) {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(AppSettings(
      useMockData: mock, dataProvider: provider,
      apiBaseUrl: 'https://example.invalid',
      autoRefreshEnabled: autoRefresh,
    ).toJson()),
  });
}

CandidateSnapshot _page({int scanned = 30, int evaluated = 30,
    int? coverageEvaluated, int total = 300, int? universe,
    int pageSize = 30, bool cumulative = true, bool stale = false,
    List<StockCandidate> candidates = const [],
    List<String> warnings = const [], String source = 'Yahoo Finance',
  }) => CandidateSnapshot(
    candidates: candidates, fetchedAt: _now, warnings: warnings,
    source: source, universeCount: universe ?? total, stale: stale,
    evaluatedCount: evaluated, scanPoolSize: pageSize,
    adrMatchCount: evaluated, universeIsComplete: false,
    universeAsOf: _now, scanCompletedAt: _now,
    candidatesAreCumulative: cumulative,
    coverageTotalCount: total, coverageScannedCount: scanned,
    coverageEvaluatedCount: coverageEvaluated ?? scanned,
    coverageRemainingCount: total - scanned, coverageRound: 1,
    scanPageStart: scanned - pageSize, scanPageSize: pageSize,
    universeFingerprint: 'explicit-controller-fixture',
  );

StockCandidate _candidate(String symbol, {StockMarket market = StockMarket.tw,
    bool invalidStop = false}) => StockCandidate(
    id: '${market.name}:$symbol', symbol: symbol, name: symbol,
    sector: 'Fixture', market: market, adrPercent: 5,
    rsScore: 75, rsRank: 1, patterns: const ['PDH'],
    entryPrice: 100, stopPrice: invalidStop ? 97 : null,
    isLargeLiquid: false, status: invalidStop ? 'confirmed' : 'watchlist',
    dataTimestamp: _now, dayLow: invalidStop ? 96 : null,
  );

AppController _controller(_Repository repository) => AppController(
  forceMockPreview: false, repositoryFactory: (_) => repository,
  now: () => _now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_seed);

  testWidgets('fresh Taiwan coverage advances the next page on minute ticks',
      (tester) async {
    final repository = _Repository();
    repository.reply = (_) async => _page(scanned: repository.calls.length * 30);
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      expect(controller.snapshot!.coverageScannedCount, 30);
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(repository.calls.length, 2);
      expect(repository.calls.last.quotesOnly, isFalse,
          reason: 'A fresh page timestamp must not freeze the round at page one.');
      expect(controller.snapshot!.coverageScannedCount, 60);
      await tester.pump(const Duration(seconds: 59));
      expect(repository.calls.length, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(repository.calls.length, 3);
      expect(repository.calls.last.force, isFalse);
      expect(repository.calls.last.quotesOnly, isFalse);
      expect(controller.snapshot!.coverageScannedCount, 90);
    } finally {
      // Flutter checks pending timers before package addTearDown runs.
      controller.dispose();
    }
    expect(controller.autoRefreshActive, isFalse);
    expect(controller.loading, isFalse);
  });

  testWidgets('manual stop between pages stays paused until a forced pull',
      (tester) async {
    final repository = _Repository();
    repository.reply = (_) async => _page(scanned: repository.calls.length * 30);
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      controller.cancelMarketEvaluation();
      expect(controller.mobileScanPaused, isTrue);
      final stoppedAt = repository.calls.length;
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      expect(repository.calls.length, stoppedAt,
          reason: 'The minute timer must not undo an explicit stop.');
      final resumed = controller.refresh(forceRefresh: true);
      await tester.pump();
      await resumed;
      expect(controller.mobileScanPaused, isFalse);
      expect(repository.calls.length, stoppedAt + 1);
      expect(repository.calls.last.force, isTrue);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(repository.calls.length, stoppedAt + 2);
      expect(repository.calls.last.quotesOnly, isFalse);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('background retires the page and ignores its late completion',
      (tester) async {
    final repository = _Repository();
    final delayed = Completer<CandidateSnapshot>();
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      final kept = controller.snapshot;
      repository.reply = (_) => delayed.future;
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      expect(repository.calls.length, 2);
      expect(controller.loading, isTrue);
      controller.setForeground(false);
      await tester.pump();
      expect(controller.autoRefreshActive, isFalse);
      expect(controller.loading, isFalse);
      expect(controller.mobileScanPaused, isFalse,
          reason: 'Lifecycle suspension is distinct from a user stop.');
      delayed.complete(_page(scanned: 60));
      await tester.pump();
      expect(controller.snapshot, same(kept));
      await tester.pump(const Duration(minutes: 2));
      expect(repository.calls.length, 2);
      repository.reply = (_) async => _page(scanned: 60);
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(repository.calls.length, 3);
      expect(controller.snapshot!.coverageScannedCount, 60);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('stopping an active Taiwan page rejects its reply and keeps automatic pages paused',
      (tester) async {
    final delayed = Completer<CandidateSnapshot>();
    final repository = _Repository();
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      repository.reply = (_) => delayed.future;
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      expect(controller.loading, isTrue);
      controller.cancelMarketEvaluation();
      expect(controller.loading, isFalse);
      expect(controller.mobileScanPaused, isTrue);
      final kept = controller.snapshot;
      delayed.complete(_page(scanned: 60));
      await tester.pump();
      expect(controller.snapshot, same(kept));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(repository.calls.length, 2);
      repository.reply = (_) async => _page(scanned: 60);
      final resumed = controller.refresh();
      await tester.pump();
      await resumed;
      expect(repository.calls.length, 3);
      expect(controller.mobileScanPaused, isFalse);
      expect(controller.snapshot!.coverageScannedCount, 60);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('a failed page preserves attempted coverage and the next tick retries work',
      (tester) async {
    final repository = _Repository();
    repository.reply = (_) async {
      if (repository.calls.length == 2) {
        return _page(scanned: 60, evaluated: 0, coverageEvaluated: 30,
          stale: true, warnings: const ['30 symbols failed; no quote invented.']);
      }
      return _page(scanned: repository.calls.length * 30,
        coverageEvaluated: repository.calls.length == 1 ? 30 : 60);
    };
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(controller.snapshot!.coverageScannedCount, 60);
      expect(controller.snapshot!.coverageEvaluatedCount, 30);
      expect(controller.snapshot!.evaluatedCount, 0);
      expect(controller.snapshot!.stale, isTrue);
      expect(controller.loading, isFalse);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(repository.calls.length, 3);
      expect(repository.calls.last.quotesOnly, isFalse);
      expect(controller.snapshot!.coverageScannedCount, 90);
      expect(controller.snapshot!.coverageEvaluatedCount, 60);
      expect(controller.snapshot!.stale, isFalse);
    } finally {
      controller.dispose();
    }
  });

  test('Taiwan cumulative candidates may exceed page evaluations, never round evaluations', () async {
    _seed(autoRefresh: false);
    final repository = _Repository()..reply = (_) async => _page(
      total: 3, scanned: 2, pageSize: 1, evaluated: 1,
      candidates: [_candidate('1001.TW'), _candidate('1002.TW')]);
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      expect(controller.error, isNull);
      expect(controller.snapshot!.candidates.length, 2);
      expect(controller.snapshot!.evaluatedCount, 1);
      expect(controller.snapshot!.coverageEvaluatedCount, 2);
      expect(controller.snapshot!.candidatesAreCumulative, isTrue);
      repository.reply = (_) async => _page(total: 3, scanned: 2,
        pageSize: 1, evaluated: 1, coverageEvaluated: 1,
        candidates: [_candidate('1001.TW'), _candidate('1002.TW')]);
      await controller.refresh();
      expect(controller.error, contains('有效候選數量超過'));
      expect(controller.snapshot!.stale, isTrue);
      expect(controller.snapshot!.candidatesAreCumulative, isTrue,
          reason: 'A stale copy must retain the accumulated-scope marker.');
    } finally {
      controller.dispose();
    }
  });

  for (final provider in ['backend', 'mock']) {
    test('$provider cannot claim the phone-only cumulative candidate exemption', () async {
      _seed(autoRefresh: false, provider: provider == 'mock' ? 'direct' : provider,
        mock: provider == 'mock');
      final repository = _Repository()..reply = (_) async => _page();
      final controller = _controller(repository);
      try {
        await controller.initialize(initializeReminders: false);
        expect(controller.error, contains('累積候選僅允許'));
        expect(controller.snapshot!.isFallback, isTrue);
      } finally {
        controller.dispose();
      }
    });
  }

  test('US and incomplete Taiwan coverage cannot enable cumulative validation', () async {
    _seed(autoRefresh: false);
    final repository = _Repository()..reply = (_) async => _page();
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      await controller.setMarket(StockMarket.us);
      expect(controller.error, contains('累積候選僅允許'));
      repository.reply = (_) async => _page(total: 299, universe: 300);
      await controller.setMarket(StockMarket.tw);
      expect(controller.error, contains('累積候選僅允許'));
    } finally {
      controller.dispose();
    }
  });

  test('without the cumulative marker the original per-page count guard remains', () async {
    _seed(autoRefresh: false);
    final repository = _Repository()..reply = (_) async => _page(
      total: 3, scanned: 2, pageSize: 1, evaluated: 1, cumulative: false,
      candidates: [_candidate('1001.TW'), _candidate('1002.TW')]);
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      expect(controller.error, contains('有效候選數量超過'));
      expect(controller.snapshot!.isFallback, isTrue);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('US keeps hot quote polling after a recent thirty-stock evaluation',
      (tester) async {
    final repository = _Repository();
    repository.reply = (call) async => _page(
      cumulative: call.market == StockMarket.tw);
    final controller = _controller(repository);
    try {
      await tester.runAsync(() => controller.initialize(initializeReminders: false));
      await tester.runAsync(() => controller.setMarket(StockMarket.us));
      controller.setForeground(true);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(repository.calls.last.market, StockMarket.us);
      expect(repository.calls.last.quotesOnly, isTrue,
          reason: 'Taiwan rolling progress must not enlarge the US polling pool.');
    } finally {
      controller.dispose();
    }
  });

  test('cumulative Taiwan results still reject bad sources and confirmed stops', () async {
    _seed(autoRefresh: false);
    final repository = _Repository()..reply = (_) async => _page(
      source: 'mock quotes', candidates: [_candidate('1001.TW')]);
    final controller = _controller(repository);
    try {
      await controller.initialize(initializeReminders: false);
      expect(controller.error, contains('來源或股票池統計無效'));
      repository.reply = (_) async => _page(
        candidates: [_candidate('1001.TW', invalidStop: true)]);
      await controller.refresh();
      expect(controller.error, contains('候選資料全部無效'));
      expect(controller.snapshot!.isFallback, isTrue);
    } finally {
      controller.dispose();
    }
  });
}
