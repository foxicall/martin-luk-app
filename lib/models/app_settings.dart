import '../app_config.dart';
import 'hybrid_protocol.dart';

/// 本金依市場計價，台幣和美元分開保存，不進行隱含匯率換算。
class AppSettings {
  const AppSettings({
    this.useMockData = AppConfig.useMockData,
    this.darkMode = true,
    this.apiBaseUrl = AppConfig.apiBaseUrl,
    this.dataProvider = 'direct',
    this.autoRefreshEnabled = true,
    this.twAdrThreshold = 3.5,
    this.usAdrThreshold = 5.0,
    this.twEquity = 1000000,
    this.usEquity = 50000,
    this.remindersEnabled = false,
    this.twRiskMode = RiskMode.unknown,
    this.usRiskMode = RiskMode.unknown,
  });

  final bool useMockData;
  final bool darkMode;
  final String apiBaseUrl;

  /// Direct Yahoo HTTPS requires no backend URL. Backend is an explicit opt-in.
  final String dataProvider;
  final bool autoRefreshEnabled;
  final double twAdrThreshold;
  final double usAdrThreshold;
  final double twEquity;
  final double usEquity;
  final bool remindersEnabled;
  final RiskMode twRiskMode, usRiskMode;

  AppSettings copyWith({
    bool? useMockData,
    bool? darkMode,
    String? apiBaseUrl,
    String? dataProvider,
    bool? autoRefreshEnabled,
    double? twAdrThreshold,
    double? usAdrThreshold,
    double? twEquity,
    double? usEquity,
    bool? remindersEnabled,
    RiskMode? twRiskMode,
    RiskMode? usRiskMode,
  }) => AppSettings(
    useMockData: useMockData ?? this.useMockData,
    darkMode: darkMode ?? this.darkMode,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    dataProvider: dataProvider ?? this.dataProvider,
    autoRefreshEnabled: autoRefreshEnabled ?? this.autoRefreshEnabled,
    twAdrThreshold: twAdrThreshold ?? this.twAdrThreshold,
    usAdrThreshold: usAdrThreshold ?? this.usAdrThreshold,
    twEquity: twEquity ?? this.twEquity,
    usEquity: usEquity ?? this.usEquity,
    remindersEnabled: remindersEnabled ?? this.remindersEnabled,
    twRiskMode: twRiskMode ?? this.twRiskMode,
    usRiskMode: usRiskMode ?? this.usRiskMode,
  );

  Map<String, dynamic> toJson() => {
    'schema_version': 3,
    'use_mock_data': useMockData,
    'dark_mode': darkMode,
    'api_base_url': apiBaseUrl,
    'data_provider': dataProvider,
    'auto_refresh_enabled': autoRefreshEnabled,
    'tw_adr_threshold': twAdrThreshold,
    'us_adr_threshold': usAdrThreshold,
    'tw_equity': twEquity,
    'us_equity': usEquity,
    'reminders_enabled': remindersEnabled,
    'tw_risk_mode': twRiskMode.name,
    'us_risk_mode': usRiskMode.name,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    double positive(String key, double fallback) {
      final value = json[key];
      if (value is! num || !value.isFinite || value <= 0) return fallback;
      return value.toDouble();
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    const defaults = AppSettings();
    // Installed demonstration builds saved use_mock_data=true without a
    // version marker. Migrate once to production while retaining account data.
    // Version 2 preserves an explicit subsequent choice of demonstration mode.
    final migrated =
        json['schema_version'] is int && (json['schema_version'] as int) >= 2;
    final provider = json['data_provider'];
    return AppSettings(
      useMockData:
          migrated
              ? flag('use_mock_data', defaults.useMockData)
              : defaults.useMockData,
      darkMode: flag('dark_mode', defaults.darkMode),
      apiBaseUrl:
          json['api_base_url'] is String
              ? json['api_base_url'] as String
              : defaults.apiBaseUrl,
      dataProvider:
          migrated && ['direct', 'backend'].contains(provider)
              ? provider as String
              : defaults.dataProvider,
      autoRefreshEnabled: flag('auto_refresh_enabled', true),
      twAdrThreshold: positive('tw_adr_threshold', defaults.twAdrThreshold),
      usAdrThreshold: positive('us_adr_threshold', defaults.usAdrThreshold),
      twEquity: positive('tw_equity', defaults.twEquity),
      usEquity: positive('us_equity', defaults.usEquity),
      remindersEnabled: flag('reminders_enabled', false),
      twRiskMode: _riskMode(json['tw_risk_mode']),
      usRiskMode: _riskMode(json['us_risk_mode']),
    );
  }
}

RiskMode _riskMode(dynamic value) => switch (value) {
  'normal' => RiskMode.normal,
  'drawdown' => RiskMode.drawdown,
  'paused' => RiskMode.paused,
  _ => RiskMode.unknown,
};
