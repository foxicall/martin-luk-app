import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';

void main() {
  test('backend candidate timeout reports a retryable error and does not poison the client', () async {
    final waiting = Completer<http.Response>();
    var calls = 0;
    final client = MockClient((_) => ++calls == 1 ? waiting.future
        : Future.value(http.Response(jsonEncode({
          'market': 'us', 'source': 'Yahoo Finance', 'universe_count': 500,
          'stale': false, 'warnings': <String>[], 'candidates': <Object>[],
          'generated_at': '2026-10-14T16:00:00Z',
        }), 200)));
    final repository = RealCandidateRepository(baseUrl: 'https://example.test',
        client: client, requestTimeout: const Duration(milliseconds: 10));
    await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5),
        throwsA(isA<RepositoryException>().having((error) => error.message,
          'message', contains('逾時'))));
    final retry = await repository.fetch(StockMarket.us, adrThreshold: 5);
    expect(retry.source, 'Yahoo Finance');
    expect(retry.stale, isFalse);
    expect(calls, 2);
    repository.close();
    client.close();
  });
}
