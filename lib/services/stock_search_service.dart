import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';

/// Immutable, pre-normalized search index. Loading reads one bundled JSON
/// asset; subsequent keystrokes perform no HTTP or disk request.
class StockSearchService {
  StockSearchService(Iterable<StockItem> stocks) {
    final seen = <String>{};
    _index = List.unmodifiable(stocks.map((stock) {
      if (!seen.add(stock.key)) {
        throw FormatException('股票字典含重複代碼：${stock.key}');
      }
      return _IndexedStock(stock);
    }));
  }

  late final List<_IndexedStock> _index;
  final Map<String, List<StockItem>> _cache = {};
  static Future<StockSearchService>? _shared;

  /// A single shared Future prevents simultaneous fields from loading twice.
  /// An asset failure is reported to the UI and may be retried next time.
  static Future<StockSearchService> load() =>
      _shared ??= Future<StockSearchService>.microtask(_loadAsset);

  static Future<StockSearchService> _loadAsset() async {
    try {
      final decoded = jsonDecode(await rootBundle.loadString('stocks_master.json'));
      if (decoded is! List) throw const FormatException('股票字典必須為 JSON 陣列。');
      return StockSearchService(decoded.map((row) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException('股票字典紀錄必須為 JSON 物件。');
        }
        return StockItem.fromJson(row);
      }));
    } catch (_) {
      _shared = null;
      rethrow;
    }
  }

  int get length => _index.length;

  /// Same normalization contract as stock_search.js: full-width ASCII is
  /// folded, then punctuation/space removed. CJK names stay searchable.
  static String normalize(String value) {
    final folded = String.fromCharCodes(value.runes.map((rune) =>
        rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune));
    return folded.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]'), '');
  }

  /// Scores: symbol/code exact 10000, other exact 9000, symbol prefix
  /// 8000, text prefix 7000, symbol substring 6000, text substring 5000,
  /// reverse substring 3000, bounded edit-distance 1000 minus 100 per edit.
  List<StockItem> searchStock(String query, {StockMarket? market, int limit = 8}) {
    if (limit < 0 || limit > 50) throw RangeError.range(limit, 0, 50, 'limit');
    final term = normalize(query);
    if (term.isEmpty || term.length > 128 || limit == 0) return const [];
    final key = '${market?.name ?? 'all'}:$limit:$term';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final ranked = <({StockItem stock, int score})>[];
    for (final entry in _index) {
      if (market != null && entry.stock.market != market) continue;
      final score = entry.score(term);
      if (score > 0) ranked.add((stock: entry.stock, score: score));
    }
    ranked.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final symbol = a.stock.symbol.compareTo(b.stock.symbol);
      return symbol != 0 ? symbol : a.stock.marketTag.compareTo(b.stock.marketTag);
    });
    final result = List<StockItem>.unmodifiable(
        ranked.take(limit).map((entry) => entry.stock));
    if (_cache.length >= 128) _cache.remove(_cache.keys.first);
    _cache[key] = result;
    return result;
  }
}

class _IndexedStock {
  _IndexedStock(this.stock) {
    symbols = {stock.symbol, stock.code}.map(StockSearchService.normalize)
        .where((field) => field.isNotEmpty).toList();
    final originals = [stock.nameZh, stock.nameFullZh, stock.nameEn,
      stock.abbrEn, ...stock.aliases, ...stock.shortCodes];
    texts = originals.map(StockSearchService.normalize)
        .where((field) => field.isNotEmpty).toSet().toList();
    // Full fields support phrases; separate words also support a misspelled
    // English name without comparing it to a long complete company name.
    fuzzyFields = {...symbols, ...texts,
      for (final field in originals)
        ...field.split(RegExp(r'[^a-zA-Z0-9\uff01-\uff5e]+'))
            .map(StockSearchService.normalize),
    }.where((field) => field.length >= 3 && field.length <= 32).toList();
  }

  final StockItem stock;
  late final List<String> symbols;
  late final List<String> texts;
  late final List<String> fuzzyFields;

  int score(String term) {
    if (symbols.contains(term)) return 10000;
    if (texts.contains(term)) return 9000;
    if (symbols.any((field) => field.startsWith(term))) return 8000;
    if (texts.any((field) => field.startsWith(term))) return 7000;
    if (symbols.any((field) => field.contains(term))) return 6000;
    if (texts.any((field) => field.contains(term))) return 5000;
    if (term.length >= 3 && [...symbols, ...texts].any(
        (field) => field.length >= 3 && term.contains(field))) return 3000;
    if (term.length < 3 || term.length > 32) return 0;
    final bound = term.length >= 6 ? 2 : 1;
    var best = bound + 1;
    for (final field in fuzzyFields) {
      best = math.min(best, _distance(term, field, bound));
    }
    return best <= bound ? 1000 - best * 100 : 0;
  }

  /// Bounded ordinary Levenshtein; long unrelated names are rejected before
  /// allocating rows. Row minima end clearly unrelated comparisons early.
  static int _distance(String left, String right, int bound) {
    if ((left.length - right.length).abs() > bound) return bound + 1;
    var previous = List<int>.generate(right.length + 1, (i) => i);
    for (var i = 1; i <= left.length; i++) {
      final current = List<int>.filled(right.length + 1, 0)..[0] = i;
      var minimum = i;
      for (var j = 1; j <= right.length; j++) {
        current[j] = math.min(math.min(current[j - 1] + 1, previous[j] + 1),
            previous[j - 1] + (left.codeUnitAt(i - 1) == right.codeUnitAt(j - 1) ? 0 : 1));
        minimum = math.min(minimum, current[j]);
      }
      if (minimum > bound) return bound + 1;
      previous = current;
    }
    return previous.last;
  }
}
