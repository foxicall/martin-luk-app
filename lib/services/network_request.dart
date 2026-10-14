import 'dart:async';
import 'package:http/http.dart' as http;

class NetworkRequest {
  static const Duration defaultTimeout = Duration(seconds: 8);
  static const Duration maximumTimeout = Duration(seconds: 10);
  static const Duration storageTimeout = Duration(seconds: 5);

  final Map<String, String> defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
  };

  Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final mergedHeaders = {...defaultHeaders, ...(headers ?? {})};
    return await http
        .get(url, headers: mergedHeaders)
        .timeout(timeout ?? defaultTimeout);
  }
}
