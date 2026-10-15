import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

// Explicit HTTP fixtures verify the asynchronous wire protocol, not live
// provider availability and never an actual currently tradable signal.
Map<String, dynamic> _progress({String status = 'running'}) => {
  'job_id': 'us-test-job',
  'status': status,
  'stage': status == 'running' ? 'scanning' : status,
  'started_at': '2026-10-15T01:01:00Z',
  'updated_at': '2026-10-15T01:01:03Z',
  'completed_at': status == 'completed' || status == 'failed'
      ? '2026-10-15T01:01:03Z' : null,
  'completed_count': status == 'completed' ? 30 : 5,
  'total_count': 30,
  'evaluated_count': 4,
  'adr_match_count': 1,
  'failed_count': 1,
  'universe_count': 503,
  'error': status == 'failed' ? '行情供應商限流，請稍後重試。' : null,
};

Map<String, dynamic> _snapshot({bool stale = true}) => {
  'market': 'us',
  'generated_at': '2026-10-14T20:01:00Z',
  'source': 'Yahoo Finance',
  'universe_count': 503,
  'stale': stale,
  'warnings': <String>[],
  'candidates': <Object>[],
  'evaluated_count': 28,
  'scan_pool_size': 30,
  'adr_match_count': 0,
  'universe_is_complete': true,
  'universe_as_of': '2026-10-14T00:00:00Z',
  'missing_symbols': <String>[],
};

Map<String, dynamic> _envelope({
  Map<String, dynamic>? scan,
  Map<String, dynamic>? snapshot,
}) => {
  'market': 'us',
  'scan': scan ?? _progress(),
  'snapshot': snapshot,
  'retry_after_seconds': 3,
};

Future<CandidateSnapshot> _fetch(
  Map<String, dynamic> body, {
  int status = 200,
  bool force = false,
  void Function(http.Request request)? inspect,
}) async {
  var requests = 0;
  final client = MockClient((request) async {
    requests++;
    inspect?.call(request);
    return http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json; charset=utf-8',
    });
  });
  final repository = RealCandidateRepository(
    baseUrl: 'https://example.test/api', client: client,
  );
  try {
    return await repository.fetch(
      StockMarket.us, adrThreshold: 5, forceRefresh: force,
    );
  } finally {
    // A pending response must not start an internal polling/retry loop.
    expect(requests, 1);
    repository.close();
    client.close();
  }
}

void main() {
  test('202 settles with progress, not a fictional empty completed scan', () async {
    final result = await _fetch(_envelope(), status: 202, inspect: (request) {
      expect(request.url.path, '/api/v1/candidates');
      expect(request.url.queryParameters['background'], 'true');
      expect(request.url.queryParameters['force_refresh'], 'false');
      expect(request.url.queryParameters['market'], 'us');
      expect(request.url.queryParameters['adr_threshold'], '5.0');
    });
    expect(result.isPending, isTrue);
    expect(result.isFallback, isFalse);
    expect(result.stale, isTrue);
    expect(result.candidates, isEmpty);
    expect(result.scanCompletedAt, isNull);
    expect(result.fetchedAt, DateTime.utc(2026, 10, 15, 1, 1, 3));
    final progress = result.backendScan;
    expect(progress, isNotNull);
    if (progress == null) fail('202 must include scan progress');
    expect(progress.isRunning, isTrue);
    expect(progress.isFailed, isFalse);
    expect(progress.completedCount, 5);
    expect(progress.evaluatedCount, 4);
    expect(progress.failedCount, 1);
    expect(progress.retryAfterSeconds, 3);
    expect(result.universeCount, 503);
    expect(result.scanPoolSize, 30);
  });

  test('force query starts one request, with no repeated refresh work', () async {
    await _fetch(_envelope(), status: 202, force: true, inspect: (request) {
      expect(request.url.queryParameters['force_refresh'], 'true');
    });
  });

  test('a newly queued job may have no universe yet and defaults retry to 3s', () async {
    final scan = _progress(status: 'queued')
      ..['started_at'] = null
      ..['completed_count'] = 0
      ..['total_count'] = 0
      ..['evaluated_count'] = 0
      ..['adr_match_count'] = 0
      ..['failed_count'] = 0
      ..['universe_count'] = 0;
    final payload = _envelope(scan: scan)..remove('retry_after_seconds');
    final result = await _fetch(payload, status: 202);
    expect(result.isPending, isTrue);
    expect(result.backendScan?.status, 'queued');
    expect(result.backendScan?.startedAt, isNull);
    expect(result.backendScan?.retryAfterSeconds, 3);
    expect(result.scanPoolSize, 0);
    expect(result.universeCount, 0);
  });

  test('warm 200 keeps original generated time while new background work runs', () async {
    final result = await _fetch(_envelope(snapshot: _snapshot()));
    expect(result.isPending, isFalse);
    expect(result.backendScan?.isRunning, isTrue);
    expect(result.generatedAt, DateTime.utc(2026, 10, 14, 20, 1));
    expect(result.scanCompletedAt, result.generatedAt);
    expect(result.backendScan?.updatedAt, isNot(result.generatedAt));
    expect(result.stale, isTrue);
    expect(result.candidates, isEmpty);
    expect(result.evaluatedCount, 28,
        reason: 'The old snapshot count must not become the new job count.');
  });

  test('completed warm 200 can contain an honest zero recommendation result', () async {
    final result = await _fetch(_envelope(
      scan: _progress(status: 'completed'), snapshot: _snapshot(stale: false),
    ));
    expect(result.isPending, isFalse);
    expect(result.backendScan?.isRunning, isFalse);
    expect(result.backendScan?.isFailed, isFalse);
    expect(result.stale, isFalse);
    expect(result.candidates, isEmpty);
  });

  test('scan completion time is preserved independently of snapshot generation', () async {
    final payload = _snapshot()
      ..['scan_completed_at'] = '2026-10-14T20:00:59.999999Z';
    final result = await _fetch(_envelope(snapshot: payload));
    expect(result.generatedAt, DateTime.utc(2026, 10, 14, 20, 1));
    expect(result.scanCompletedAt,
        DateTime.utc(2026, 10, 14, 20, 0, 59, 999, 999));

    // Backend construction may record completion microseconds after generation.
    payload['scan_completed_at'] = '2026-10-14T20:01:00.000001Z';
    final later = await _fetch(_envelope(snapshot: payload));
    expect(later.scanCompletedAt,
        DateTime.utc(2026, 10, 14, 20, 1, 0, 0, 1));
  });

  test('failed 503 decodes bounded server error and never yields success', () async {
    await expectLater(
      _fetch(_envelope(scan: _progress(status: 'failed')), status: 503),
      throwsA(isA<RepositoryException>().having((error) => error.message,
          'message', contains('行情供應商限流'))),
    );
    final progress = _progress(status: 'failed')
      ..['error'] = List.filled(10000, 'x').join();
    await expectLater(
      _fetch(_envelope(scan: progress), status: 503),
      throwsA(isA<RepositoryException>().having((error) => error.message.length,
          'bounded message length', lessThan(500))),
    );
  });

  test('legacy direct 200 snapshot still works without a scan envelope', () async {
    final result = await _fetch(_snapshot(stale: false));
    expect(result.isPending, isFalse);
    expect(result.backendScan, isNull);
    expect(result.stale, isFalse);
    expect(result.generatedAt, DateTime.utc(2026, 10, 14, 20, 1));
  });

  test('client failure preserves server timestamps and explains stopped polls', () async {
    final result = await _fetch(_envelope(), status: 202);
    final progress = result.backendScan;
    if (progress == null) fail('202 must include progress');
    final failure = progress.withClientFailure('掃描進度連線逾時。');
    expect(failure.status, 'failed');
    expect(failure.stage, 'client_error');
    expect(failure.isRunning, isFalse);
    expect(failure.isFailed, isTrue);
    expect(failure.updatedAt, progress.updatedAt);
    expect(failure.completedAt, progress.completedAt);
    expect(failure.error, contains('連線逾時'));
    expect(progress.isRunning, isTrue, reason: 'Progress is immutable.');
  });

  test('mismatched envelope, nested progress and warm snapshot markets fail', () async {
    final payloads = [
      _envelope()..['market'] = 'tw',
      _envelope(scan: _progress()..['market'] = 'tw'),
      _envelope(snapshot: _snapshot()..['market'] = 'tw'),
    ];
    for (var index = 0; index < payloads.length; index++) {
      await expectLater(_fetch(payloads[index], status: index == 2 ? 200 : 202),
          throwsA(isA<RepositoryException>()));
    }
  });

  test('invalid progress counts, status and types are rejected', () async {
    final mutations = <void Function(Map<String, dynamic>)>[
      (scan) => scan['completed_count'] = -1,
      (scan) => scan['total_count'] = 504,
      (scan) => scan['completed_count'] = 31,
      (scan) => scan['evaluated_count'] = 6,
      (scan) => scan['failed_count'] = 6,
      (scan) => scan['failed_count'] = 2,
      (scan) => scan['adr_match_count'] = 5,
      (scan) => scan['universe_count'] = '503',
      (scan) => scan['status'] = 'unknown',
      (scan) => scan['error'] = 403,
    ];
    for (final mutate in mutations) {
      final scan = _progress();
      mutate(scan);
      await expectLater(_fetch(_envelope(scan: scan), status: 202),
          throwsA(isA<RepositoryException>()));
    }
  });

  test('all scan dates need offsets and chronological consistency', () async {
    final mutations = <void Function(Map<String, dynamic>)>[
      (scan) => scan['updated_at'] = '2026-10-15T01:01:03',
      (scan) => scan['started_at'] = '2026-10-15T01:01:00',
      (scan) => scan['completed_at'] = '2026-10-15T01:01:02',
      (scan) => scan['updated_at'] = '2026-02-30T01:01:03Z',
      (scan) => scan['updated_at'] = '2026-10-15T01:00:59Z',
      (scan) => scan['completed_at'] = '2026-10-15T01:01:04Z',
    ];
    for (final mutate in mutations) {
      final scan = _progress();
      mutate(scan);
      await expectLater(_fetch(_envelope(scan: scan), status: 202),
          throwsA(isA<RepositoryException>()));
    }
  });

  test('terminal status requires completion time and completed consumes whole pool', () async {
    final invalid = [
      _progress(status: 'completed')..['completed_at'] = null,
      _progress(status: 'failed')..['completed_at'] = null,
      _progress(status: 'completed')..['completed_count'] = 29,
      _progress()..['completed_at'] = '2026-10-15T01:01:02Z',
      _progress(status: 'queued')..['completed_at'] = '2026-10-15T01:01:02Z',
    ];
    for (final scan in invalid) {
      await expectLater(_fetch(_envelope(scan: scan), status: 202),
          throwsA(isA<RepositoryException>()));
    }
  });

  test('retry timing is bounded and an incomplete terminal scan fails', () async {
    for (final retry in <Object?>[0, -1, 61, '3']) {
      final payload = _envelope()..['retry_after_seconds'] = retry;
      await expectLater(_fetch(payload, status: 202),
          throwsA(isA<RepositoryException>()));
    }
    await expectLater(_fetch(_envelope(scan: _progress(status: 'completed')),
        status: 202), throwsA(isA<RepositoryException>()));
    await expectLater(_fetch(_envelope(), status: 200),
        throwsA(isA<RepositoryException>()));
  });

  test('warm snapshots still reject fake sources and timezone-less generation', () async {
    for (final snapshot in [
      _snapshot()..['source'] = 'offline mock demo',
      _snapshot()..['generated_at'] = '2026-10-14T20:01:00',
      _snapshot()..['scan_completed_at'] = '2026-10-14T20:01:00',
      _snapshot()..['stale'] = 'false',
    ]) {
      await expectLater(_fetch(_envelope(snapshot: snapshot)),
          throwsA(isA<RepositoryException>()));
    }
  });
}
