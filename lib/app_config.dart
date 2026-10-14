import 'package:flutter/foundation.dart';

/// USE_MOCK_DATA 可透過 --dart-define 設定，設定頁也能於執行時切換。
abstract final class AppConfig {
  static const bool useMockData =
      bool.fromEnvironment('USE_MOCK_DATA', defaultValue: false);
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  /// Explicit browser preview links start in mock mode even if this browser
  /// previously saved an API-mode preference. Native apps ignore the query.
  /// This controls initialization only; Settings can still switch to the API.
  static bool get forceMockPreview =>
      isMockPreviewUri(Uri.base, isWeb: kIsWeb);

  static bool isMockPreviewUri(Uri uri, {required bool isWeb}) =>
      isWeb && uri.queryParameters['preview'] == 'mock';
}
