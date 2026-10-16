import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/app_controller.dart';
import 'package:martin_luk_app/models/app_settings.dart';
import 'package:martin_luk_app/models/backend_scan_status.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/portfolio_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These HTTP fixtures exercise schema and controller state, not live-market
// evidence. Cumulative coverage counts are deliberately different from a page.
final _fingerprint = List<String>.filled(64, 'a').join();

Map<String, dynamic> _coverage() => {
  'coverage_total_count': 100,
  'coverage_scanned_count': 40,
  'coverage_evaluated_count': 35,
  'coverage_remaining_count': 60,
  'coverage_round': 2,
  'scan_page_start': 20,
  'scan_page_size': 20,
  'universe_fingerprint': _fingerprint,
};

Map<String, dynamic> _snapshot({bool coverage = true}) => {
  'market': 'tw', 'generated_at': '2026-10-15T05:31:00Z',
  'source': 'Yahoo Finance HTTPS chart via Python API',
  'universe_count': 100, 'stale': false,
  'warnings': <String>[], 'candidates': <Object>[],
  'evaluated_count': 18, 'scan_pool_size': 20, 'adr_match_count': 0,
  if (coverage) ..._coverage(),
};

Map<String, dynamic> _scan({bool coverage = true}) => {
  'market': 'tw', 'job_id': 'rolling-page-2', 'status': 'running',
  'stage': 'evaluating', 'started_at': '2026-10-15T05:30:00Z',
  'updated_at': '2026-10-15T05:30:05Z', 'completed_at': null,
  'completed_count': 5, 'total_count': 20, 'evaluated_count': 4,
  'adr_match_count': 0, 'failed_count': 1, 'universe_count': 100,
  if (coverage) ..._coverage(),
};

Future<CandidateSnapshot> _fetch(Map<String, dynamic> payload,
    {int status = 200}) async {
  final client = MockClient((_) async => http.Response(
    jsonEncode(payload), status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  ));
  final repository = RealCandidateRepository(
    baseUrl: 'https://example.test', client: client,
  );
  try {
    return await repository.fetch(StockMarket.tw, adrThreshold: 3.5);
  } finally {
    repository.close();
    client.close();
  }
}

void _expectCoverage(CandidateSnapshot snapshot) {
  expect(snapshot.coverageTotalCount, 100);
  expect(snapshot.coverageScannedCount, 40);
  expect(snapshot.coverageEvaluatedCount, 35);
  expect(snapshot.coverageRemainingCount, 60);
  expect(snapshot.coverageRound, 2);
  expect(snapshot.scanPageStart, 20);
  expect(snapshot.scanPageSize, 20);
  expect(snapshot.universeFingerprint, _fingerprint);
}

class _Scans implements CandidateRepository {
  _Scans(this.snapshot);
  final CandidateSnapshot snapshot;
  bool fail = false;
  @override
  Future<CandidateSnapshot> fetch(StockMarket market, {
    required double adrThreshold, bool forceRefresh = false,
    bool refreshQuotesOnly = false,
  }) async {
    if (fail) throw const RepositoryException('HTTP 503 injected test failure');
    return snapshot;
  }
}

class _Quotes implements PortfolioRepository {
  @override
  Future<PortfolioQuoteSnapshot> fetch(StockMarket market, List<String> symbols,
      {bool forceRefresh = false}) async => PortfolioQuoteSnapshot(
    quotes: const {}, errors: const {}, source: 'injected test source',
  );
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode(
      const AppSettings(autoRefreshEnabled: false).toJson(),
    ),
  }));

  test('rolling snapshot parses cumulative coverage separately from page counts', () async {
    final snapshot = await _fetch(_snapshot());
    _expectCoverage(snapshot);
    expect(snapshot.scanPoolSize, 20);
    expect(snapshot.evaluatedCount, 18);
    expect(snapshot.candidates, isEmpty);
  });

  test('202 progress carries cumulative coverage without a fake completed result', () async {
    final snapshot = await _fetch({
      'market': 'tw', 'scan': _scan(), 'snapshot': null,
      'retry_after_seconds': 3,
    }, status: 202);
    _expectCoverage(snapshot);
    expect(snapshot.isPending, isTrue);
    expect(snapshot.backendScan?.completedCount, 5);
    expect(snapshot.backendScan?.coverageScannedCount, 40);
    expect(snapshot.backendScan?.coverageEvaluatedCount, 35);
    expect(snapshot.backendScan?.coverageRemainingCount, 60);
    expect(snapshot.backendScan?.coverageRound, 2);
    expect(snapshot.backendScan?.scanPageStart, 20);
    expect(snapshot.backendScan?.scanPageSize, 20);
    expect(snapshot.backendScan?.universeFingerprint, _fingerprint);
  });

  test('legacy snapshot and progress leave optional rolling fields null', () async {
    final snapshot = await _fetch(_snapshot(coverage: false));
    expect(snapshot.coverageTotalCount, isNull);
    expect(snapshot.coverageScannedCount, isNull);
    expect(snapshot.coverageEvaluatedCount, isNull);
    expect(snapshot.coverageRemainingCount, isNull);
    expect(snapshot.coverageRound, isNull);
    expect(snapshot.scanPageStart, isNull);
    expect(snapshot.scanPageSize, isNull);
    expect(snapshot.universeFingerprint, isNull);
    final scan = BackendScanStatus.fromJson(
      _scan(coverage: false), market: StockMarket.tw,
    );
    expect(scan.coverageScannedCount, isNull);
    expect(scan.universeFingerprint, isNull);
  });

  test('impossible counters, partial extensions and invalid pages are rejected', () async {
    final changes = <Map<String, dynamic>>[
      {'coverage_scanned_count': 101},
      {'coverage_evaluated_count': 41},
      {'coverage_remaining_count': 59},
      {'coverage_round': 0},
      {'scan_page_start': 101},
      {'scan_page_start': 90, 'scan_page_size': 20},
      {'scan_page_size': -1},
      {'coverage_scanned_count': 40.0},
      {'coverage_scanned_count': true},
      {'universe_fingerprint': ''},
      {'universe_fingerprint': 1},
      {'coverage_round': null},
    ];
    for (final change in changes) {
      await expectLater(_fetch(_snapshot()..addAll(change)),
        throwsA(isA<RepositoryException>()), reason: '$change');
      expect(() => BackendScanStatus.fromJson(
        _scan()..addAll(change), market: StockMarket.tw,
      ), throwsFormatException, reason: '$change');
    }
  });

  test('explicit administrator pool cap may be smaller than full membership', () async {
    final snapshot = await _fetch(_snapshot()..['universe_count'] = 500);
    expect(snapshot.universeCount, 500);
    expect(snapshot.coverageTotalCount, 100);
    await expectLater(_fetch(_snapshot()..['universe_count'] = 99),
      throwsA(isA<RepositoryException>()));
  });

  test('stopped polling preserves original coverage and server timestamp', () {
    final progress = BackendScanStatus.fromJson(_scan(), market: StockMarket.tw);
    final failed = progress.withClientFailure('injected connection failure');
    expect(failed.coverageTotalCount, progress.coverageTotalCount);
    expect(failed.coverageScannedCount, progress.coverageScannedCount);
    expect(failed.coverageEvaluatedCount, progress.coverageEvaluatedCount);
    expect(failed.coverageRemainingCount, progress.coverageRemainingCount);
    expect(failed.coverageRound, progress.coverageRound);
    expect(failed.scanPageStart, progress.scanPageStart);
    expect(failed.scanPageSize, progress.scanPageSize);
    expect(failed.universeFingerprint, progress.universeFingerprint);
    expect(failed.updatedAt, progress.updatedAt);
    expect(failed.isFailed, isTrue);
  });

  test('controller verification and stale-cache clones preserve all coverage', () async {
    final source = await _fetch(_snapshot());
    final scans = _Scans(source);
    final controller = AppController(
      repositoryFactory: (_) => scans,
      portfolioRepositoryFactory: (_) => _Quotes(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(initializeReminders: false);
    final verified = controller.snapshot;
    if (verified == null) fail('successful scan must publish its snapshot');
    _expectCoverage(verified);
    expect(verified.stale, isFalse);
    scans.fail = true;
    await controller.refresh(forceRefresh: true);
    final cached = controller.snapshot;
    if (cached == null) fail('failed refresh must retain the verified snapshot');
    _expectCoverage(cached);
    expect(cached.stale, isTrue);
    expect(cached.fetchedAt, source.fetchedAt);
    expect(controller.loading, isFalse);
  });
}
