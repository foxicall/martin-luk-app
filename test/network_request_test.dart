import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:martin_luk_app/services/network_request.dart';

import 'support/controllable_http_client.dart';

void main() {
  final uri = Uri.https('example.test', '/quotes');

  test('standard browser headers are enforced for all common GET services', () async {
    final client = ControllableHttpClient((request) async {
      expect(request.headers['user-agent'], NetworkRequest.requestHeaders['User-Agent']);
      expect(request.headers['accept'], 'application/json');
      expect(request.headers['accept-language'], 'en-US,en;q=0.9');
      expect(request.headers['x-trace'], 'holdings');
      return streamedText('ok');
    });
    final network = NetworkRequest(client: client);
    addTearDown(network.close);
    final response = await network.get(uri, headers: {
      'User-Agent': 'Dart client', 'Accept': 'text/plain',
      'Accept-Language': 'fr', 'X-Trace': 'holdings',
    });
    expect(response.body, 'ok');
  });

  test('default is eight seconds and explicit timeouts cannot exceed ten seconds', () {
    final client = ControllableHttpClient((_) async => streamedText('ok'));
    for (final timeout in [Duration.zero, const Duration(milliseconds: -1),
      const Duration(seconds: 11)]) {
      expect(() => NetworkRequest(client: client, timeout: timeout),
          throwsArgumentError);
    }
    final standard = NetworkRequest(client: client);
    final extended = NetworkRequest(client: client,
        timeout: const Duration(seconds: 10));
    addTearDown(standard.close);
    addTearDown(extended.close);
    expect(standard.timeout, const Duration(seconds: 8));
    expect(extended.timeout, const Duration(seconds: 10));
    expect(NetworkRequest.defaultTimeout, const Duration(seconds: 8));
    expect(NetworkRequest.maximumTimeout, const Duration(seconds: 10));
    expect(NetworkRequest.storageTimeout, const Duration(seconds: 5));
    expect(NetworkRequest.maximumConcurrentRequests, 5);
  });

  test('null headers use browser defaults and per-call invalid timeouts never send', () async {
    final client = ControllableHttpClient((request) async {
      expect(request.headers['user-agent'], NetworkRequest.requestHeaders['User-Agent']);
      expect(request.headers['accept'], 'application/json');
      return streamedText('ok');
    });
    final network = NetworkRequest(client: client);
    addTearDown(network.close);
    expect((await network.get(uri, headers: null)).body, 'ok');
    await expectLater(network.get(uri, timeout: Duration.zero), throwsArgumentError);
    await expectLater(network.get(uri, timeout: const Duration(seconds: 11)),
        throwsArgumentError);
    expect(client.requests, hasLength(1));
    expect(network.defaultHeaders['Accept-Language'], 'en-US,en;q=0.9');
  });

  test('different transports share five permits until each response body finishes', () async {
    final bodies = <Completer<List<int>>>[];
    final waves = {for (final count in [5, 10, 12]) count: Completer<void>()};
    var sent = 0, active = 0, maximumActive = 0;
    Future<http.StreamedResponse> handle(http.BaseRequest request) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      final body = Completer<List<int>>();
      bodies.add(body);
      sent++;
      waves[sent]?.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future.then((bytes) {
        active--;
        return bytes;
      })), 200);
    }

    final firstClient = ControllableHttpClient(handle);
    final secondClient = ControllableHttpClient(handle);
    final first = NetworkRequest(client: firstClient);
    final second = NetworkRequest(client: secondClient);
    addTearDown(first.close);
    addTearDown(second.close);
    final requests = List.generate(12, (index) => (index.isEven ? first : second)
        .get(uri.replace(path: '/quotes/$index')));
    for (final count in [5, 10, 12]) {
      await waves[count]!.future.timeout(const Duration(seconds: 2));
      expect(sent, count);
      expect(active, count == 12 ? 2 : 5,
          reason: 'Received headers do not release a permit for a stalled body.');
      for (final body in List<Completer<List<int>>>.of(bodies)) {
        if (!body.isCompleted) body.complete('fresh'.codeUnits);
      }
    }
    final responses = await Future.wait(requests).timeout(const Duration(seconds: 2));
    expect(responses.every((response) => response.body == 'fresh'), isTrue);
    expect(maximumActive, 5);
    expect(active, 0);
    expect(firstClient.closeCalls, 0);
    expect(secondClient.closeCalls, 0);
  });

  test('a queued request times out without sending HTTP and a later retry succeeds', () async {
    final bodies = <Completer<List<int>>>[];
    final full = Completer<void>();
    final holderClient = ControllableHttpClient((request) async {
      final body = Completer<List<int>>();
      bodies.add(body);
      if (bodies.length == NetworkRequest.maximumConcurrentRequests) full.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future), 200);
    });
    final retryClient = ControllableHttpClient((_) async => streamedText('retry'));
    final holder = NetworkRequest(client: holderClient);
    final retry = NetworkRequest(client: retryClient,
        timeout: const Duration(milliseconds: 20));
    addTearDown(holder.close);
    addTearDown(retry.close);
    final held = List.generate(NetworkRequest.maximumConcurrentRequests,
        (index) => holder.get(uri.replace(path: '/held/$index')));
    await full.future.timeout(const Duration(seconds: 2));
    await expectLater(retry.get(uri), throwsA(isA<TimeoutException>()));
    expect(retryClient.requests, isEmpty,
        reason: 'The eight-second budget includes FIFO permit queueing.');
    for (final body in bodies) { body.complete('held'.codeUnits); }
    await Future.wait(held).timeout(const Duration(seconds: 2));
    expect(retryClient.requests, isEmpty,
        reason: 'A timed-out queue entry must never be sent after a slot opens.');
    expect((await retry.get(uri)).body, 'retry');
    expect(retryClient.requests.length, 1);
  });

  test('closing a queued transport cancels its queue entry without taking another slot', () async {
    final bodies = <Completer<List<int>>>[];
    final full = Completer<void>();
    final holderClient = ControllableHttpClient((request) async {
      final body = Completer<List<int>>();
      bodies.add(body);
      if (bodies.length == NetworkRequest.maximumConcurrentRequests) full.complete();
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        if (!body.isCompleted) body.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(body.future), 200);
    });
    final queuedClient = ControllableHttpClient((_) async => streamedText('unexpected'));
    final holder = NetworkRequest(client: holderClient);
    final queued = NetworkRequest(client: queuedClient);
    addTearDown(holder.close);
    addTearDown(queued.close);
    final held = List.generate(NetworkRequest.maximumConcurrentRequests,
        (index) => holder.get(uri.replace(path: '/held/$index')));
    await full.future.timeout(const Duration(seconds: 2));
    final cancelled = queued.get(uri);
    final checked = expectLater(cancelled, throwsA(isA<http.RequestAbortedException>()));
    queued.close();
    await checked.timeout(const Duration(seconds: 1));
    expect(queuedClient.requests, isEmpty);
    for (final body in bodies) { body.complete('held'.codeUnits); }
    await Future.wait(held).timeout(const Duration(seconds: 2));
    expect(queuedClient.requests, isEmpty);
    expect(queuedClient.closeCalls, 0);
  });

  test('a hanging connection is aborted and the next request can succeed', () async {
    var aborts = 0;
    final never = Completer<http.StreamedResponse>();
    final client = ControllableHttpClient((request) async {
      if (aborts > 0) return streamedText('fresh');
      expect(request, isA<http.AbortableRequest>());
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborts++;
        if (!never.isCompleted) {
          never.completeError(http.RequestAbortedException(request.url));
        }
      });
      return never.future;
    });
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(aborts, 1);
    expect((await transport.get(uri)).body, 'fresh');
    transport.close();
    expect(client.closeCalls, 0, reason: 'Caller-owned client remains reusable.');
  });

  test('headers arriving successfully cannot leave a hanging response body', () async {
    final never = Completer<List<int>>();
    var aborted = false;
    final client = ControllableHttpClient((request) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
        if (!never.isCompleted) never.complete(<int>[]);
      });
      return http.StreamedResponse(Stream.fromFuture(never.future), 200);
    });
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    transport.close();
  });

  test('disposing aborts active work without closing an injected client', () async {
    final waiting = Completer<http.StreamedResponse>();
    final started = Completer<void>();
    var aborted = false;
    final client = ControllableHttpClient((request) {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
        if (!waiting.isCompleted) {
          waiting.completeError(http.RequestAbortedException(request.url));
        }
      });
      started.complete();
      return waiting.future;
    });
    final transport = NetworkRequest(client: client);
    final result = transport.get(uri);
    final expectation = expectLater(result,
        throwsA(isA<http.RequestAbortedException>()));
    await started.future;
    transport.close();
    await expectation;
    expect(aborted, isTrue);
    expect(client.closeCalls, 0);
    await expectLater(transport.get(uri), throwsStateError);
  });

  test('a late response from a timed-out client cannot change the returned result', () async {
    final late = Completer<http.StreamedResponse>();
    var calls = 0;
    final client = ControllableHttpClient((_) => ++calls == 1
        ? late.future : Future.value(streamedText('current')));
    final transport = NetworkRequest(client: client,
        timeout: const Duration(milliseconds: 10));
    await expectLater(transport.get(uri), throwsA(isA<TimeoutException>()));
    expect((await transport.get(uri)).body, 'current');
    late.complete(streamedText('obsolete'));
    await Future<void>.delayed(Duration.zero);
    expect((await transport.get(uri)).body, 'current');
    transport.close();
  });
}
