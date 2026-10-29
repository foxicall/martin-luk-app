import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/stock_candidate.dart';

/// Bundled metadata only: never changes ranking, prices or entry evidence.
class StockIndustryService {
  StockIndustryService();
  static final instance = StockIndustryService();
  static const assetPath = 'assets/data/stock_industries.json';
  Map<String, Map<String, dynamic>> _rows = {};
  Future<void>? _loading;

  int get length => _rows.length;

  /// Share one in-memory index. A failed asset read can be retried.
  Future<void> load({AssetBundle? bundle}) =>
      _loading ??= _load(bundle ?? rootBundle);

  Future<void> _load(AssetBundle bundle) async {
    try {
      // This service caches the parsed index; avoid caching a failed read in
      // CachingAssetBundle so the startup retry can actually reload the asset.
      final decoded = jsonDecode(
        await bundle.loadString(assetPath, cache: false),
      );
      if (decoded is! Map<String, dynamic> || decoded.isEmpty) {
        throw const FormatException('產業分類資料必須為非空物件。');
      }
      final rows = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        final row = entry.value;
        if (row is! Map<String, dynamic> ||
            !['TW', 'US'].contains(row['market']) ||
            row['symbol'] is! String ||
            row['sector'] is! String ||
            (row['sector'] as String).trim().isEmpty) {
          throw FormatException('產業分類紀錄無效：${entry.key}');
        }
        rows['${row['market']}:${row['symbol']}'] = Map.unmodifiable(row);
      }
      _rows = Map.unmodifiable(rows);
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Map<String, dynamic>? lookup(StockMarket market, String symbol) =>
      _rows['${market.name.toUpperCase()}:${symbol.trim().toUpperCase()}'];

  String sector(StockMarket market, String symbol) =>
      lookup(market, symbol)?['sector'] as String? ?? 'Unknown';

  String label(StockMarket market, String symbol) {
    final row = lookup(market, symbol);
    if (row == null) return 'Unknown · 尚無分類資料';
    final sector = row['sector'] as String;
    final industry = row['industry'] as String? ?? '';
    final themes = (row['themes'] as List? ?? []).join('、');
    return [
      sector,
      if (industry.isNotEmpty && industry != sector) industry,
      if (themes.isNotEmpty) themes,
    ].join(' · ');
  }
}
