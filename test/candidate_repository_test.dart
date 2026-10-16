import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

// Explicit HTTP fixtures exercise production parsing. They are not evidence
// of a successful network request or of an actual current market setup.
Map<String, dynamic> _candidate(String symbol) => {
  'market': 'us', 'symbol': symbol, 'name': symbol, 'sector': 'Technology',
  'adr_percent': 6.5, 'rs_score': 95, 'rs_rank': 1,
  'patterns': ['PDH 突破'], 'entry_price': 100, 'stop_price': 98,
  'is_large_liquid': true, 'status': 'confirmed',
  'data_timestamp': '2026-10-14T15:00:00Z',
  'signal_timestamp': '2026-10-14T14:55:00Z',
  'notes': ['Explicit HTTP test fixture'], 'daily_closes': [96, 98, 100],
  'trigger_price': 100, 'trigger_type': 'PDH',
  'stop_source': 'day_low', 'day_low': 98,
};

Map<String, dynamic> _response(List<Object?> rows) => {
  'market': 'us', 'generated_at': '2026-10-14T15:00:00Z',
  'source': 'Yahoo Finance HTTP fixture', 'universe_count': 500,
  'stale': false, 'warnings': ['Explicit HTTP test fixture'],
  'candidates': rows, 'evaluated_count': 490,
  'universe_is_complete': true, 'universe_as_of': '2026-10-14T00:00:00Z',
  'missing_symbols': <String>[],
};

Future<CandidateSnapshot> _fetch(Map<String, dynamic> payload) async {
  final client = MockClient((request) async {
    expect(request.url.queryParameters['market'], 'us');
    return http.Response(jsonEncode(payload), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final repository = RealCandidateRepository(
      baseUrl: 'https://example.test', client: client);
  try {
    return await repository.fetch(StockMarket.us, adrThreshold: 5);
  } finally {
    repository.close();
    client.close();
  }
}

void main() {
  test('a bad row and a non-object row cannot erase an independently valid stock', () async {
    final snapshot = await _fetch(_response([
      _candidate('NVDA'),
      _candidate('TSLA')..['entry_price'] = 'not a number',
      null,
    ]));
    expect(snapshot.candidates.map((row) => row.symbol), ['NVDA']);
    expect(snapshot.missingSymbols, ['TSLA']);
    expect(snapshot.warnings.join(), contains('TSLA'));
    expect(snapshot.warnings.join(), contains('第 3 筆'));
    expect(snapshot.stale, isFalse,
        reason: 'The valid stock must not become a cached quote because another stock failed.');
    expect(snapshot.generatedAt, DateTime.utc(2026, 10, 14, 15));
    expect(snapshot.evaluatedCount, 490);
    expect(() => snapshot.candidates.clear(), throwsUnsupportedError);
  });

  test('duplicate symbols remove their ambiguous copies, retaining other symbols', () async {
    final snapshot = await _fetch(_response([
      _candidate('NVDA'), _candidate('TSLA'), _candidate('TSLA'),
    ]));
    expect(snapshot.candidates.map((row) => row.symbol), ['NVDA']);
    expect(snapshot.missingSymbols, ['TSLA']);
    expect(snapshot.warnings.join(), contains('重複'));
    expect(snapshot.warnings.join(), contains('2 筆無效候選'));
  });

  test('a mixed-market or illegal-symbol row is isolated', () async {
    final snapshot = await _fetch(_response([
      _candidate('NVDA'),
      _candidate('2330.TW')..['market'] = 'tw',
      _candidate('invalid/symbol'),
    ]));
    expect(snapshot.candidates.single.symbol, 'NVDA');
    expect(snapshot.missingSymbols, containsAll(['2330.TW', 'invalid/symbol']));
    expect(snapshot.warnings.join(), contains('市場'));
  });

  test('a nonempty all-invalid response fails rather than replacing the scan with empty success', () async {
    await expectLater(_fetch(_response([
      _candidate('TSLA')..['stop_price'] = 101,
    ])), throwsA(isA<RepositoryException>().having((error) => error.message,
        'message', allOf(contains('非空候選清單全部無法驗證'), contains('TSLA')))));
    await expectLater(_fetch(_response([_candidate('NVDA'), _candidate('NVDA')])),
        throwsA(isA<RepositoryException>()));
  });

  test('a genuine successful empty scan remains a valid empty state', () async {
    final snapshot = await _fetch(_response([]));
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.missingSymbols, isEmpty);
    expect(snapshot.stale, isFalse);
    expect(snapshot.source, 'Yahoo Finance HTTP fixture');
  });

  test('core pool coverage and zero ADR matches survive a real empty response', () async {
    final payload = _response([])
      ..['evaluated_count'] = 27
      ..['scan_pool_size'] = 30
      ..['adr_match_count'] = 0;
    final snapshot = await _fetch(payload);
    expect(snapshot.universeCount, 500);
    expect(snapshot.scanPoolSize, 30);
    expect(snapshot.evaluatedCount, 27);
    expect(snapshot.adrMatchCount, 0);
    expect(snapshot.candidates, isEmpty);
    expect(snapshot.stale, isFalse);
  });

  test('impossible or incorrectly typed core pool counts reject the response', () async {
    final payloads = [
      _response([])..['scan_pool_size'] = 30,
      _response([])..['scan_pool_size'] = 501,
      _response([])..['scan_pool_size'] = '500',
      _response([])..['adr_match_count'] = -1,
      _response([])..['adr_match_count'] = 491,
      _response([])..['adr_match_count'] = '0',
    ];
    for (final payload in payloads) {
      await expectLater(_fetch(payload), throwsA(isA<RepositoryException>()));
    }
  });

  test('critical envelope source, dates and coverage metadata still fail the whole response', () async {
    final payloads = [
      _response([_candidate('NVDA')])..['source'] = 'offline demo',
      _response([_candidate('NVDA')])..['market'] = 'tw',
      _response([_candidate('NVDA')])..['generated_at'] = '2026-10-14T15:00:00',
      _response([_candidate('NVDA')])..['universe_as_of'] = 'invalid date',
      _response([_candidate('NVDA')])..['evaluated_count'] = 501,
      _response([_candidate('NVDA')])..['evaluated_count'] = '490',
      _response([_candidate('NVDA')])..['universe_is_complete'] = 'true',
      _response([_candidate('NVDA')])..['universe_count'] = 0,
      _response([_candidate('NVDA')])..['warnings'] = 'invalid container',
    ];
    for (final payload in payloads) {
      await expectLater(_fetch(payload), throwsA(isA<RepositoryException>()));
    }
  });

  test('future row timestamps cannot replace another valid row', () async {
    final snapshot = await _fetch(_response([
      _candidate('NVDA'),
      _candidate('TSLA')..['data_timestamp'] = '2030-10-14T15:00:00Z',
    ]));
    expect(snapshot.candidates.single.symbol, 'NVDA');
    expect(snapshot.missingSymbols, ['TSLA']);
    expect(snapshot.warnings.join(), contains('時間'));
  });

  test('large malformed lists have bounded diagnostic text and missing-symbol storage', () async {
    final snapshot = await _fetch(_response([
      _candidate('NVDA'),
      ...List.generate(1100, (index) => _candidate('BROKEN$index')
          ..['entry_price'] = 'invalid'),
    ]));
    expect(snapshot.candidates.single.symbol, 'NVDA');
    expect(snapshot.warnings.length, lessThanOrEqualTo(122));
    expect(snapshot.warnings.join(), contains('詳細警告最多顯示 20 筆'));
    expect(snapshot.missingSymbols.length, 1000);
  });
}
