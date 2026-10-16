import 'dart:async';

import 'package:http/http.dart' as http;

/// Test transport keeps caller ownership observable and exposes abort tokens.
class ControllableHttpClient extends http.BaseClient {
  ControllableHttpClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final List<http.BaseRequest> requests = [];
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() { closeCalls++; }
}

http.StreamedResponse streamedText(String body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(body.codeUnits), status);
