import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'network_request.dart';

/// A successful probe proves only that this version of the API is reachable.
/// It does not fetch a quote or prove that Yahoo or another data source works.
class BackendCapabilities {
  const BackendCapabilities({
    required this.baseUri,
    required this.poolLimit,
    required this.pageSize,
    required this.pageIntervalSeconds,
  });

  final Uri baseUri;
  final int poolLimit;
  final int pageSize;
  final double pageIntervalSeconds;

  // These values are guaranteed by fromJson's strict protocol validation.
  String get continuation => 'client_driven';
  String get recommendationScope => 'latest_page_only';
  bool get requiresMarketDataVerification => true;

  bool get supportsFullUniverse => poolLimit == 0;
  String get scopeLabel => supportsFullUniverse
      ? '全股票池分頁輪掃'
      : '受限股票池（每市場最多 $poolLimit 檔）';

  static BackendCapabilities fromJson(Uri baseUri, Object? json) {
    if (json is! Map<String, dynamic> ||
        json['service'] != 'martin-luk-market-api' ||
        json['api_version'] != 1 ||
        json['data_mode'] != 'live') {
      throw const FormatException('不是相容的 Martin Luk 正式行情 API。');
    }
    final markets = json['markets'];
    final scan = json['scan'];
    if (markets is! List ||
        !markets.contains('tw') ||
        !markets.contains('us') ||
        scan is! Map<String, dynamic>) {
      throw const FormatException('API 缺少台美股市場或掃描能力資料。');
    }
    final limit = scan['pool_limit'];
    final size = scan['page_size'];
    final interval = scan['page_interval_seconds'];
    if (limit is! int || limit < 0 ||
        size is! int || size < 1 || size > 100 ||
        interval is! num || !interval.isFinite || interval <= 0 ||
        scan['scope'] != (limit == 0 ? 'full_universe' : 'limited') ||
        scan['background_jobs'] != true ||
        scan['continuation'] != 'client_driven' ||
        scan['recommendations'] != 'latest_page_only' ||
        json['requires_market_data_verification'] != true) {
      throw const FormatException('API 掃描設定不相容，請更新伺服器專案。');
    }
    return BackendCapabilities(
      baseUri: baseUri,
      poolLimit: limit,
      pageSize: size,
      pageIntervalSeconds: interval.toDouble(),
    );
  }
}

class BackendConnectionException implements Exception {
  const BackendConnectionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Explicit, bounded configuration check. Never switches data providers,
/// creates mock prices, starts a market job, or saves a setting automatically.
class BackendConnectionService {
  BackendConnectionService({
    http.Client? client,
    Duration requestTimeout = NetworkRequest.defaultTimeout,
  }) : _network = NetworkRequest(client: client, timeout: requestTimeout);

  final NetworkRequest _network;

  static Uri parseBaseUri(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.any((part) => part == '..' || part == '.') ||
        value.contains(RegExp(r'[\s<>]'))) {
      throw const BackendConnectionException(
        '請輸入完整的 http:// 或 https:// API 基底網址。',
      );
    }
    final host = uri.host.toLowerCase();
    if (host == 'example.com' || host.endsWith('.example.com') ||
        host.endsWith('.invalid') || host == 'example.org' ||
        host.contains('your-service') || value.contains('你的服務')) {
      throw const BackendConnectionException('這是範例網址，請改填實際部署的 API 網址。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (RegExp(r'/(health|docs|redoc|openapi\.json)$').hasMatch(path) ||
        RegExp(r'/v1(?:/|$)').hasMatch(path)) {
      throw const BackendConnectionException(
        '請填 API 基底網址，移除 /health、/docs 或 /v1/... 端點。',
      );
    }
    // A reverse-proxy prefix such as https://host/api is supported, just as in
    // the existing candidate repository. LAN HTTP remains available for dev.
    return uri.replace(path: path);
  }

  Future<BackendCapabilities> testConnection(String baseUrl) async {
    final base = parseBaseUri(baseUrl);
    final endpoint = base.replace(path: '${base.path}/v1/capabilities');
    try {
      final response = await _network.get(endpoint);
      if (response.statusCode != 200) {
        throw BackendConnectionException(
          'API 回應 HTTP ${response.statusCode}。請確認部署完成與基底網址；'
          '免費雲端服務可能需要先喚醒後重試。',
        );
      }
      if (response.bodyBytes.length > 65536) {
        throw const BackendConnectionException('API 能力回應過大，請確認網址。');
      }
      final text = utf8.decode(response.bodyBytes).trim();
      if (!text.startsWith('{')) {
        throw const BackendConnectionException(
          '收到 HTML／非 JSON 頁面，請填 API 服務網址，而不是 GitHub 或登入頁。',
        );
      }
      return BackendCapabilities.fromJson(base, jsonDecode(text));
    } on TimeoutException {
      throw const BackendConnectionException(
        'API 連線逾時，已停止等待。請先用瀏覽器開啟 API 網址加 /health，'
        '等雲端喚醒後重試；5G 無法存取電腦的 127.0.0.1 或區網 IP。',
      );
    } on http.ClientException catch (error) {
      throw BackendConnectionException(
        '無法連線到 API：${_bounded(error.message)}。'
        '請檢查 HTTPS、網路與服務狀態。',
      );
    } on FormatException catch (error) {
      throw BackendConnectionException('API 資料格式不符：${_bounded(error.message)}');
    } on BackendConnectionException {
      rethrow;
    } catch (error) {
      throw BackendConnectionException('API 檢查失敗：${_bounded('$error')}');
    }
  }

  static String _bounded(String message) =>
      message.length > 180 ? '${message.substring(0, 180)}…' : message;

  /// Aborts this wrapper's pending requests; a supplied client remains owned
  /// by its caller, following [NetworkRequest]'s ownership contract.
  void close() => _network.close();
}
