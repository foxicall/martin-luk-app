import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/services/candidate_repository.dart';
import 'package:martin_luk_app/services/strategy_engine.dart';

Map<String, dynamic> validJson() => {
      'market': 'us',
      'symbol': 'DEMO',
      'name': '示範',
      'sector': '資訊科技',
      'adr_percent': 6.5,
      'rs_score': 95,
      'rs_rank': 2,
      'patterns': ['PDH 突破'],
      'entry_price': 100,
      'stop_price': 98,
      'is_large_liquid': true,
      'status': 'confirmed',
      'data_timestamp': '2026-10-13T06:00:00Z',
      'signal_timestamp': '2026-10-13T14:00:00+08:00',
      'notes': ['假資料'],
      'daily_closes': [96, 98, 100],
    };

Map<String, dynamic> snapshotJson() => {
      'market': 'us',
      'generated_at': '2026-10-13T06:00:00Z',
      'source': '測試來源',
      'universe_count': 500,
      'stale': false,
      'warnings': ['測試資料'],
      'candidates': [validJson()],
    };

void main() {
  group('null-safe candidate API model', () {
    test('parses and round-trips the snake_case API contract', () {
      final candidate = StockCandidate.fromJson(validJson());
      expect(candidate.id, 'us:DEMO');
      expect(candidate.market, StockMarket.us);
      expect(candidate.entryPrice, 100);
      expect(candidate.stopPercent, 2);
      expect(candidate.priceSignalConfirmed, isTrue);
      expect(candidate.isConfirmed, isFalse); // Old payload lacks Hybrid evidence.
      expect(candidate.signalTimestamp, DateTime.utc(2026, 10, 13, 6));
      final roundTrip = StockCandidate.fromJson(candidate.toJson());
      expect(roundTrip.toJson(), candidate.toJson());
    });

    test('supports null stop and signal time on a watchlist', () {
      final json = validJson()
        ..['status'] = 'watchlist'
        ..['stop_price'] = null
        ..remove('signal_timestamp')
        ..remove('daily_closes');
      final candidate = StockCandidate.fromJson(json);
      expect(candidate.stopPrice, isNull);
      expect(candidate.stopPercent, isNull);
      expect(candidate.signalTimestamp, isNull);
      expect(candidate.dailyCloses, isEmpty);
    });

    test('required keys reject missing data instead of inventing defaults', () {
      for (final field in [
        'market', 'symbol', 'name', 'sector', 'adr_percent', 'rs_score',
        'rs_rank', 'patterns', 'entry_price', 'is_large_liquid', 'status',
        'data_timestamp', 'notes',
      ]) {
        expect(() => StockCandidate.fromJson(validJson()..remove(field)), throwsFormatException, reason: field);
      }
    });

    test('rejects unknown markets, invalid states and missing confirmed stops', () {
      expect(() => StockCandidate.fromJson(validJson()..['market'] = 'hk'), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['status'] = 'ready'), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['stop_price'] = null), throwsFormatException);
    });

    test('rejects numeric strings, booleans and non-finite prices', () {
      for (final value in ['100', true, double.infinity, double.nan]) {
        expect(() => StockCandidate.fromJson(validJson()..['entry_price'] = value), throwsFormatException);
      }
      expect(() => StockCandidate.fromJson(validJson()..['is_large_liquid'] = 1), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['rs_rank'] = 1.0), throwsFormatException);
    });

    test('rejects invalid price, ADR, RS and stop values', () {
      for (final value in [0, -1]) {
        expect(() => StockCandidate.fromJson(validJson()..['entry_price'] = value), throwsFormatException);
      }
      for (final value in [0, -1, 100, 101, double.nan]) {
        expect(() => StockCandidate.fromJson(validJson()..['stop_price'] = value), throwsFormatException);
      }
      for (final value in [-1, 101, double.infinity]) {
        expect(() => StockCandidate.fromJson(validJson()..['rs_score'] = value), throwsFormatException);
      }
      expect(() => StockCandidate.fromJson(validJson()..['adr_percent'] = -1), throwsFormatException);
    });

    test('rejects invalid array content and timestamp ambiguity', () {
      expect(() => StockCandidate.fromJson(validJson()..['patterns'] = ['']), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['notes'] = [42]), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['daily_closes'] = [0]), throwsFormatException);
      expect(() => StockCandidate.fromJson(validJson()..['daily_closes'] = ['100']), throwsFormatException);
      for (final time in [
        '2026-10-13T06:00:00', 'yesterday', null,
        '2026-02-31T06:00:00Z', '2026-10-13T25:00:00Z',
        '2026-10-13T06:00:00+00:99',
      ]) {
        expect(() => StockCandidate.fromJson(validJson()..['data_timestamp'] = time), throwsFormatException);
      }
    });

    test('collections are immutable after construction', () {
      final json = validJson();
      final candidate = StockCandidate.fromJson(json);
      (json['patterns'] as List).add('後續修改');
      expect(candidate.patterns.length, 1);
      expect(() => candidate.patterns.add('修改'), throwsUnsupportedError);
      expect(() => candidate.notes.add('修改'), throwsUnsupportedError);
      expect(() => candidate.dailyCloses.add(200), throwsUnsupportedError);
    });

    test('market defaults keep equity currencies separate', () {
      expect(StockMarket.tw.currency, 'TWD');
      expect(StockMarket.us.currency, 'USD');
      expect(StockMarket.tw.defaultEquity, 1000000);
      expect(StockMarket.us.defaultEquity, 50000);
      expect(StockMarket.tw.defaultAdr, 3.5);
      expect(StockMarket.us.defaultAdr, 5);
    });
  });

  group('repositories', () {
    test('offline data is fixed, clearly labeled and risk-calculable', () async {
      for (final market in StockMarket.values) {
        final repository = MockCandidateRepository();
        final snapshot = await repository.fetch(market, adrThreshold: market.defaultAdr);
        expect(snapshot.source, '離線示範');
        expect(snapshot.candidates.length, 8);
        expect(snapshot.universeCount, 8);
        expect(snapshot.warnings.join(), contains('假資料'));
        expect(snapshot.candidates.any((row) => !row.isConfirmed && row.stopPrice == null), isTrue);
        for (final row in snapshot.candidates.where((row) => row.isConfirmed)) {
          final plan = StrategyEngine.calculate(row, market.defaultEquity);
          expect(plan.stopPercent, inInclusiveRange(1.5, 3));
          expect(plan.riskAmount, lessThanOrEqualTo(plan.riskBudget));
        }
      }
    });

    test('ADR filtering is inclusive with a usable empty state', () async {
      final repository = MockCandidateRepository();
      final boundary = await repository.fetch(StockMarket.tw, adrThreshold: 7.2);
      expect(boundary.candidates.map((row) => row.symbol), ['1519.TW']);
      final empty = await repository.fetch(StockMarket.tw, adrThreshold: 99);
      expect(empty.candidates, isEmpty);
      expect(empty.warnings, isNotEmpty);
    });

    test('real API sends market/ADR and parses snapshot metadata', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/candidates');
        expect(request.url.queryParameters, {'market': 'us', 'adr_threshold': '5.0', 'background': 'true', 'force_refresh': 'false'});
        return http.Response(jsonEncode(snapshotJson()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      final repository = RealCandidateRepository(baseUrl: 'https://example.test/api/', client: client);
      final snapshot = await repository.fetch(StockMarket.us, adrThreshold: 5);
      expect(snapshot.source, '測試來源');
      expect(snapshot.candidates.single.symbol, 'DEMO');
      expect(snapshot.universeCount, 500);
      expect(snapshot.stale, isFalse);
      expect(snapshot.generatedAt, DateTime.utc(2026, 10, 13, 6));
      client.close();
    });

    test('HTTP failure is explicit and does not return mock data', () async {
      final client = MockClient((request) async => http.Response('unavailable', 503));
      final repository = RealCandidateRepository(baseUrl: 'https://example.test', client: client);
      await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5), throwsA(isA<RepositoryException>().having((error) => error.message, 'message', contains('503'))));
      client.close();
    });

    test('rejects malformed, duplicate or mismatched-market API payloads', () async {
      final payloads = [
        <String, dynamic>{},
        snapshotJson()..['market'] = 'tw',
        snapshotJson()..['stale'] = 'false',
        snapshotJson()..['candidates'] = [validJson(), validJson()],
        snapshotJson()..['candidates'] = [validJson()..['market'] = 'tw'],
        snapshotJson()..['universe_count'] = 0,
        snapshotJson()..['missing_symbols'] = [42],
      ];
      for (final payload in payloads) {
        final client = MockClient((request) async => http.Response(jsonEncode(payload), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
        final repository = RealCandidateRepository(baseUrl: 'https://example.test', client: client);
        await expectLater(repository.fetch(StockMarket.us, adrThreshold: 5), throwsA(isA<RepositoryException>()));
        client.close();
      }
    });

    test('rejects invalid endpoint URLs and non-finite thresholds', () async {
      for (final url in ['example.test', 'ftp://example.test', 'https://example.test?x=1']) {
        expect(() => RealCandidateRepository(baseUrl: url), throwsA(isA<RepositoryException>()));
      }
      await expectLater(MockCandidateRepository().fetch(StockMarket.us, adrThreshold: double.nan), throwsArgumentError);
    });
  });
}
