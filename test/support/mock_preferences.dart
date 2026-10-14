import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic UI fixtures explicitly opt in to demonstration mode.
/// Production defaults and their migration are tested separately; these
/// fixtures must never make live network requests or start polling timers.
void seedMockPreferences() {
  SharedPreferences.setMockInitialValues({
    'martin_luk_settings_v1': jsonEncode({
      'schema_version': 2,
      'use_mock_data': true,
      'data_provider': 'direct',
      'auto_refresh_enabled': false,
    }),
  });
}
