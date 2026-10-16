import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:martin_luk_app/services/backend_connection_service.dart';

Map<String, Object?> _contract({int limit = 0}) => {
  'service': 'martin-luk-market-api',
  'api_version': 1,
  'data_mode': 'live',
  'markets': ['tw', 'us'],
  'scan': {
    'pool_limit': limit,
    'scope': limit == 0 ? 'full_universe' : 'limited',
    'page_size': 60,
    'page_interval_seconds': 60,
    'background_jobs': true,
    'continuation': 'client_driven',
    'recommendations': 'latest_page_only',
  },
  'requires_market_data_verification': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full-universe capability probe uses one real transport request only',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(_contract()), 200);
    });
    final service = BackendConnectionService(client: client);
    addTearDown(service.close);
    addTearDown(client.close);
    final result = await service.testConnection('https://market.provider.test/api/');
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/v1/capabilities');
    expect(requests.single.headers['Accept'], 'application/json');
    expect(result.supportsFullUniverse, isTrue);
    expect(result.pageSize, 60);
    expect(result.pageIntervalSeconds, 60);
    expect(result.scopeLabel, contains('全股票池'));
  });

  test('limited server is reachable but never described as full-universe', () async {
    final client = MockClient((_) async =>
        http.Response(jsonEncode(_contract(limit: 30)), 200));
    final service = BackendConnectionService(client: client);
    addTearDown(service.close);
    addTearDown(client.close);
    final result = await service.testConnection('https://market.provider.test');
    expect(result.supportsFullUniverse, isFalse);
    expect(result.poolLimit, 30);
    expect(result.scopeLabel, contains('最多 30 檔'));
  });

  test('HTTP 200 HTML is a visible configuration failure', () async {
    final client = MockClient((_) async =>
        http.Response('<html>Login</html>', 200));
    final service = BackendConnectionService(client: client);
    addTearDown(service.close);
    addTearDown(client.close);
    await expectLater(service.testConnection('https://market.provider.test'),
        throwsA(isA<BackendConnectionException>().having(
            (error) => error.message, 'message', contains('HTML'))));
  });

  for (final invalid in [
    {..._contract(), 'service': 'unrelated-app'},
    {..._contract(), 'data_mode': 'mock'},
    {..._contract(), 'api_version': 2},
    {..._contract(), 'scan': <String, Object?>{}},
    {..._contract(), 'requires_market_data_verification': false},
    {..._contract(), 'markets': ['us']},
  ]) {
    test('incomplete or incompatible contract is not accepted: $invalid', () async {
      final client = MockClient((_) async => http.Response(jsonEncode(invalid), 200));
      final service = BackendConnectionService(client: client);
      addTearDown(service.close);
      addTearDown(client.close);
      await expectLater(service.testConnection('https://market.provider.test'),
          throwsA(isA<BackendConnectionException>()));
    });
  }

  test('HTTP failure retains status and is not treated as healthy', () async {
    final client = MockClient((_) async => http.Response('not found', 404));
    final service = BackendConnectionService(client: client);
    addTearDown(service.close);
    addTearDown(client.close);
    await expectLater(service.testConnection('https://market.provider.test'),
        throwsA(isA<BackendConnectionException>().having(
            (error) => error.message, 'message', contains('404'))));
  });

  test('deadline releases a hung capability check with an actionable error', () async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);
    final service = BackendConnectionService(
      client: client, requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(service.close);
    addTearDown(client.close);
    await expectLater(service.testConnection('https://market.provider.test'),
        throwsA(isA<BackendConnectionException>().having(
            (error) => error.message, 'message', contains('逾時'))));
    // Completing the old transport after timeout must not create a second result.
    pending.complete(http.Response(jsonEncode(_contract()), 200));
  });

  test('HTTP client failure is surfaced rather than replaced with mock data', () async {
    final client = MockClient((_) => throw http.ClientException('connection refused'));
    final service = BackendConnectionService(client: client);
    addTearDown(service.close);
    addTearDown(client.close);
    await expectLater(service.testConnection('https://market.provider.test'),
        throwsA(isA<BackendConnectionException>().having(
            (error) => error.message, 'message', contains('connection refused'))));
  });

  test('base URL permits reverse-proxy and local development addresses', () {
    expect(BackendConnectionService.parseBaseUri('https://provider.test/api/').path, '/api');
    expect(BackendConnectionService.parseBaseUri('http://192.168.1.23:8000').port, 8000);
  });

  test('endpoint, credential, placeholder and query URLs are rejected before HTTP', () {
    for (final value in [
      '', '127.0.0.1:8000', 'ftp://provider.test',
      'https://name:secret@provider.test', 'https://provider.test?key=x',
      'https://provider.test#x', 'https://example.com',
      'https://your-service.onrender.com', 'https://provider.test/health',
      'https://provider.test/docs', 'https://provider.test/v1/candidates',
    ]) {
      expect(() => BackendConnectionService.parseBaseUri(value),
          throwsA(isA<BackendConnectionException>()), reason: value);
    }
  });
}
