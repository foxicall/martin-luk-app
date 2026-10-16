import 'dart:convert';

import '../models/stock_candidate.dart';
import '../models/stock_item.dart';

/// Exchange metadata only: no quote, membership inference or trade signal.
class UsDirectoryResult {
  UsDirectoryResult({
    required List<StockItem> stocks,
    required List<String> warnings,
    required this.fileDate,
    required this.isComplete,
  })  : stocks = List.unmodifiable(stocks),
        warnings = List.unmodifiable(warnings);

  final List<StockItem> stocks;
  final List<String> warnings;

  /// Nasdaq supplies a wall-clock label without an offset. Keep its calendar
  /// date in UTC, without inventing an exact provider timestamp or time zone.
  final DateTime? fileDate;
  final bool isComplete;
}

/// Parses the two Nasdaq Trader pipe-delimited directories without packages.
/// Structural failures reject the source; isolated rows are skipped and make
/// coverage incomplete. A valid footer is mandatory even after row recovery.
class UsStockDirectory {
  static const maximumBytes = 8 * 1024 * 1024;

  static UsDirectoryResult parseBytes(
    List<int> bytes, {
    required bool nasdaq,
    String? contentType,
    Map<String, StockItem> master = const {},
  }) {
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      throw const FormatException('美股目錄回應為空或超過 8 MiB 安全上限。');
    }
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('美股目錄含無效位元組。');
    }
    final decoded = _decode(bytes, contentType);
    return _parse(decoded.text, nasdaq: nasdaq, master: master,
        decodeWarnings: decoded.warnings, decodingFallback: decoded.fallback);
  }

  static UsDirectoryResult parseText(
    String text, {
    required bool nasdaq,
    Map<String, StockItem> master = const {},
  }) => _parse(text, nasdaq: nasdaq, master: master);

  static UsDirectoryResult _parse(
    String text, {
    required bool nasdaq,
    required Map<String, StockItem> master,
    List<String> decodeWarnings = const [],
    bool decodingFallback = false,
  }) {
    final lines = const LineSplitter().convert(text);
    final first = lines.indexWhere((line) => _clean(line).isNotEmpty);
    if (first < 0) throw const FormatException('美股交易所目錄為空。');
    final initial = _clean(lines[first]);
    if (initial.startsWith('<')) {
      throw const FormatException('美股目錄收到 HTML／機器人驗證頁，而非證券清單。');
    }
    if (initial.startsWith('{') || initial.startsWith('[')) {
      throw const FormatException('美股目錄收到 JSON 回應，而非交易所管線分隔清單。');
    }
    if (!initial.contains('|') && RegExp(
      r'access\s+denied|forbidden|captcha|robot|cloudflare|just\s+a\s+moment|enable\s+javascript|request\s+rejected',
      caseSensitive: false,
    ).hasMatch(initial)) {
      throw const FormatException('美股目錄回應為存取拒絕／機器人驗證文字，請重試其他來源。');
    }
    final headers = initial.split('|').map(_header).toList();
    while (headers.isNotEmpty && headers.last.isEmpty) { headers.removeLast(); }
    final required = nasdaq
        ? ['symbol', 'security name', 'test issue', 'etf']
        : ['act symbol', 'security name', 'exchange', 'test issue', 'etf'];
    if (required.any((name) => !headers.contains(name)) ||
        headers.any((name) => name.isEmpty) || headers.toSet().length != headers.length) {
      throw const FormatException('美股目錄缺少代碼、證券名稱或 ETF／Test Issue 分類欄位，或欄名重複。');
    }
    final columns = {for (var i = 0; i < headers.length; i++) headers[i]: i};
    final stocks = <StockItem>[];
    final seen = <String>{};
    final warnings = [...decodeWarnings];
    final examples = <String>[];
    var dataRows = 0;
    var malformed = 0;
    var duplicates = 0;
    var unknown = 0;
    DateTime? fileDate;
    var footerSeen = false;

    void badRow(int number, String reason) {
      malformed++;
      if (examples.length < 3) examples.add('第 $number 行：$reason');
    }

    for (var index = first + 1; index < lines.length; index++) {
      final line = _clean(lines[index]);
      if (line.isEmpty) continue;
      if (RegExp(r'^File\s+Creation\s+Time\s*:', caseSensitive: false).hasMatch(line)) {
        final date = _footerDate(line);
        if (footerSeen) {
          throw const FormatException('美股目錄含多個檔案完成標記。');
        }
        footerSeen = true;
        fileDate = date;
        continue;
      }
      if (footerSeen) {
        throw const FormatException('美股目錄完成標記之後仍有非空內容，回應可能已損毀。');
      }
      dataRows++;
      final cells = line.split('|');
      // Some text mirrors append empty delimiters. Never shift a nonempty
      // extra column or guess the meaning of a missing interior field.
      while (cells.length > headers.length && cells.last.trim().isEmpty) {
        cells.removeLast();
      }
      if (cells.length != headers.length) {
        badRow(index + 1, '欄位數 ${cells.length} 與標頭 ${headers.length} 不符');
        continue;
      }
      String field(String key) => cells[columns[key]!].trim();
      final testIssue = field('test issue').toUpperCase();
      final etf = field('etf').toUpperCase();
      if (!{'Y', 'N'}.contains(testIssue) || !{'Y', 'N'}.contains(etf)) {
        badRow(index + 1, 'ETF／Test Issue 欄位不是 Y 或 N');
        continue;
      }
      if (testIssue == 'Y' || etf == 'Y') continue;
      if (!nasdaq && !{'N', 'A'}.contains(field('exchange').toUpperCase())) continue;
      final name = field('security name');
      if (name.isEmpty) {
        badRow(index + 1, '證券名稱為空');
        continue;
      }
      if (_excluded.hasMatch(name)) continue;
      final withoutReit = name.replaceAll(_corporateReit, '');
      if (_investmentTrust.hasMatch(withoutReit)) continue;
      if (!_common.hasMatch(name)) {
        unknown++;
        continue;
      }
      final symbol = field(nasdaq ? 'symbol' : 'act symbol')
          .toUpperCase().replaceAll('.', '-');
      if (!_symbol.hasMatch(symbol)) {
        unknown++;
        continue;
      }
      if (!seen.add(symbol)) {
        duplicates++;
        if (examples.length < 3) examples.add('第 ${index + 1} 行：重複代碼 $symbol');
        continue;
      }
      final known = master['us:$symbol'];
      stocks.add(StockItem(
        market: StockMarket.us, symbol: symbol, code: symbol,
        nameZh: known?.nameZh ?? '', nameFullZh: known?.nameFullZh ?? '',
        nameEn: name, abbrEn: known?.abbrEn ?? '',
        aliases: known?.aliases ?? const [], shortCodes: known?.shortCodes ?? const [],
      ));
    }
    if (!footerSeen) {
      throw const FormatException('美股目錄缺少 File Creation Time 完成標記，可能下載不完整。');
    }
    if (dataRows == 0 || stocks.isEmpty) {
      throw const FormatException('美股目錄沒有可識別的普通股紀錄。');
    }
    if ((malformed + duplicates) * 2 > dataRows) {
      throw FormatException('美股目錄多數資料行異常：$dataRows 行中有 '
          '$malformed 行格式錯誤、$duplicates 行重複，拒絕將此回應當成有效股票池。');
    }
    if (malformed > 0 || duplicates > 0) {
      warnings.add('美股目錄已隔離 $malformed 行格式錯誤、$duplicates 行重複；'
          '${examples.join('；')}。股票池覆蓋不足。');
    }
    if (unknown > 0) {
      warnings.add('美股目錄 $unknown 筆未能確認普通股類別或標準代碼，已排除；股票池覆蓋不足。');
    }
    stocks.sort((a, b) => a.symbol.compareTo(b.symbol));
    return UsDirectoryResult(stocks: stocks, warnings: warnings, fileDate: fileDate,
        isComplete: !decodingFallback && malformed == 0 && duplicates == 0 && unknown == 0);
  }

  static String _clean(String text) => text.replaceFirst(RegExp(r'^\s*\ufeff'), '').trim();
  static String _header(String text) => text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static final _symbol = RegExp(r'^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$');
  static final _excluded = RegExp(
    r'\b(?:preferred|preference|pfd|depositary|depository|ADR|ADS|warrants?|units?|rights?|ET[FN]|funds?|notes?|bonds?)\b|exchange[- ]traded|\bshares?\s+of\s+beneficial\s+interest\b',
    caseSensitive: false,
  );
  static final _corporateReit = RegExp(r'\breal\s+estate\s+investment\s+trust\b', caseSensitive: false);
  static final _investmentTrust = RegExp(r'\binvestment\s+trust\b', caseSensitive: false);
  static final _common = RegExp(
    r'\bcommon\s+(?:stock|shares?)\b|\bordinary\s+(?:stock|shares?)\b|\bcapital\s+stock\b',
    caseSensitive: false,
  );

  static DateTime _footerDate(String line) {
    final match = RegExp(
      r'^File\s+Creation\s+Time\s*:\s*(\d{2})(\d{2})(\d{4})\s*(?:\d{1,2}:\d{2}(?::\d{2})?)?\s*(?:\|[\s|]*)?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) {
      throw const FormatException('美股目錄 File Creation Time 日期／完成標記格式無效。');
    }
    final month = int.parse(match.group(1)!);
    final day = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const FormatException('美股目錄完成標記含不存在的日曆日期。');
    }
    return date;
  }

  static _DecodedDirectory _decode(List<int> bytes, String? contentType) {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _DecodedDirectory(_utf16(bytes.sublist(2), littleEndian: true));
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _DecodedDirectory(_utf16(bytes.sublist(2), littleEndian: false));
    }
    if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
      return _DecodedDirectory(utf8.decode(bytes.sublist(3)));
    }
    final charset = RegExp(r'''charset\s*=\s*["']?([^\s;"']+)''', caseSensitive: false)
        .firstMatch(contentType ?? '')?.group(1)?.toLowerCase();
    if (charset == 'utf-16le' || charset == 'utf-16be') {
      return _DecodedDirectory(_utf16(bytes, littleEndian: charset == 'utf-16le'));
    }
    if (charset == 'utf-16') {
      throw const FormatException('美股目錄聲明 UTF-16 但缺少位元組序標記，無法安全解碼。');
    }
    if (_hasBinaryControls(bytes)) {
      throw const FormatException('美股目錄回應含二進位控制碼，可能為未解壓縮或非文字資料。');
    }
    if ({'iso-8859-1', 'iso8859-1', 'latin1', 'latin-1'}.contains(charset)) {
      return _DecodedDirectory(latin1.decode(bytes));
    }
    if ({'windows-1252', 'cp1252', 'windows1252'}.contains(charset)) {
      return _DecodedDirectory(_windows1252(bytes));
    }
    try {
      final text = utf8.decode(bytes);
      final unsupported = charset != null &&
          !{'utf-8', 'utf8', 'us-ascii', 'ascii'}.contains(charset);
      return _DecodedDirectory(text, fallback: unsupported, warnings: [
        if (unsupported) '來源聲明未支援的 charset=$charset；以嚴格 UTF-8 解碼，股票池完整性尚未確認。',
      ]);
    } on FormatException {
      // A few legacy single-byte name characters must not erase thousands of
      // valid ASCII tickers. Bound recovery to predominantly ASCII text; the
      // strict header/footer and row validation still run after decoding.
      final highBytes = bytes.where((byte) => byte >= 128).length;
      if (highBytes == 0 || highBytes * 20 > bytes.length) {
        throw const FormatException('美股目錄不是有效 UTF-8，且不符合受限 Windows-1252 復原條件。');
      }
      return _DecodedDirectory(_windows1252(bytes), fallback: true, warnings: [
        '來源未提供可用編碼且 UTF-8 解碼失敗；已以 Windows-1252 保守復原，股票池覆蓋不足。',
      ]);
    }
  }

  static bool _hasBinaryControls(List<int> bytes) =>
      bytes.any((byte) => byte < 32 && byte != 9 && byte != 10 && byte != 13);

  static String _windows1252(List<int> bytes) {
    const upperControls = <int>[
      0x20ac, -1, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
      0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, -1, 0x017d, -1,
      -1, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
      0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, -1, 0x017e, 0x0178,
    ];
    final points = <int>[];
    for (final byte in bytes) {
      final point = byte >= 0x80 && byte <= 0x9f ? upperControls[byte - 0x80] : byte;
      if (point < 0) throw const FormatException('美股目錄含未定義的 Windows-1252 位元組。');
      points.add(point);
    }
    return String.fromCharCodes(points);
  }

  static String _utf16(List<int> bytes, {required bool littleEndian}) {
    if (bytes.length.isOdd) throw const FormatException('美股目錄 UTF-16 位元組長度無效。');
    final units = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          throw const FormatException('美股目錄 UTF-16 含未配對代理字元。');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('美股目錄 UTF-16 含未配對代理字元。');
      }
    }
    return String.fromCharCodes(units);
  }
}

class _DecodedDirectory {
  const _DecodedDirectory(this.text, {this.warnings = const [], this.fallback = false});
  final String text;
  final List<String> warnings;
  final bool fallback;
}
