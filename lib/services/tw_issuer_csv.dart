import 'dart:convert';

/// An official issuer CSV and its oldest reported publication date.
///
/// [asOf] is midnight in Taiwan (UTC+8), represented as UTC. It comes only
/// from `出表日期`; a download time or company listing date is never substituted.
class TwIssuerCsvDocument {
  final List<Map<String, dynamic>> rows;
  final DateTime asOf;

  TwIssuerCsvDocument._(List<Map<String, dynamic>> rows, this.asOf)
      : rows = List.unmodifiable(
          rows.map((row) => Map<String, dynamic>.unmodifiable(row)),
        );
}

/// Strict, dependency-free parser for TWSE/TPEx official issuer CSV backups.
///
/// The CSV is UTF-8 (an initial BOM is allowed) and follows RFC 4180 quoting.
/// Additional official columns are retained, but the issuer code, company name,
/// and publication date columns must exist. All rows need valid, recent dates;
/// if the file contains several publication dates, the oldest is reported.
class TwIssuerCsv {
  static const int maximumBytes = 2 * 1024 * 1024;
  static const int maximumRows = 5000;
  static const int maximumColumns = 128;
  static const Duration _taiwanOffset = Duration(hours: 8);

  static TwIssuerCsvDocument parseBytes(
    List<int> bytes, {
    required DateTime now,
    int maximumAgeDays = 7,
  }) {
    if (maximumAgeDays < 0) {
      throw ArgumentError.value(maximumAgeDays, 'maximumAgeDays', 'Must be >= 0');
    }
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      throw const FormatException('台股 CSV 為空或超過 2 MiB 上限。');
    }
    // Never replace invalid UTF-8 bytes with replacement characters: doing so
    // could corrupt issuer identities or turn an error response into data.
    var source = utf8.decode(bytes, allowMalformed: false);
    if (source.startsWith('\uFEFF')) source = source.substring(1);
    if (source.trim().isEmpty || source.contains('\u0000')) {
      throw const FormatException('台股 CSV 為空或含有無效控制字元。');
    }
    final records = _records(source);
    if (records.length < 2) {
      throw const FormatException('台股 CSV 沒有股票資料列。');
    }
    final headers = records.first.map((value) => value.trim()).toList();
    if (headers.any((header) => header.isEmpty) ||
        headers.toSet().length != headers.length ||
        !headers.contains('公司代號') ||
        (!headers.contains('公司簡稱') && !headers.contains('公司名稱')) ||
        !headers.contains('出表日期')) {
      throw const FormatException('台股 CSV 欄位格式無效或缺少公司代號／名稱／出表日期。');
    }

    final taiwanNow = now.toUtc().add(_taiwanOffset);
    final today = DateTime.utc(taiwanNow.year, taiwanNow.month, taiwanNow.day);
    final rows = <Map<String, dynamic>>[];
    DateTime? oldestDate;
    final dateIndex = headers.indexOf('出表日期');
    for (var index = 1; index < records.length; index++) {
      final cells = records[index];
      if (cells.length != headers.length) {
        throw FormatException('台股 CSV 第 ${index + 1} 列欄位數與標題不同。');
      }
      final day = _publicationDay(cells[dateIndex]);
      final age = today.difference(day).inDays;
      if (day.isAfter(today) || age > maximumAgeDays) {
        throw FormatException('台股 CSV 第 ${index + 1} 列出表日期在未來或已過期。');
      }
      if (oldestDate == null || day.isBefore(oldestDate)) oldestDate = day;
      rows.add({
        for (var column = 0; column < headers.length; column++)
          headers[column]: cells[column],
      });
    }
    // At least one data row was required above, so oldestDate is assigned.
    return TwIssuerCsvDocument._(rows, oldestDate!.subtract(_taiwanOffset));
  }

  /// Returns a UTC date key, not an instant in Taiwan, for calendar-day checks.
  static DateTime _publicationDay(String value) {
    final text = value.trim();
    int year;
    int month;
    int day;
    if (RegExp(r'^\d{7}$').hasMatch(text)) {
      final rocYear = int.parse(text.substring(0, 3));
      if (rocYear == 0) throw const FormatException('台股 CSV 民國年份無效。');
      year = rocYear + 1911;
      month = int.parse(text.substring(3, 5));
      day = int.parse(text.substring(5, 7));
    } else if (RegExp(r'^\d{8}$').hasMatch(text)) {
      year = int.parse(text.substring(0, 4));
      month = int.parse(text.substring(4, 6));
      day = int.parse(text.substring(6, 8));
    } else {
      final match = RegExp(r'^(\d{3}|\d{4})([/-])(\d{1,2})\2(\d{1,2})$')
          .firstMatch(text);
      if (match == null) {
        throw const FormatException('台股 CSV 出表日期格式無效。');
      }
      year = int.parse(match.group(1)!);
      if (year == 0) throw const FormatException('台股 CSV 年份無效。');
      if (match.group(1)!.length == 3) year += 1911;
      month = int.parse(match.group(3)!);
      day = int.parse(match.group(4)!);
    }
    final result = DateTime.utc(year, month, day);
    // Dart normalizes e.g. February 30; reject rather than silently shifting it.
    if (year < 1 || result.year != year || result.month != month || result.day != day) {
      throw const FormatException('台股 CSV 出表日期不是有效日期。');
    }
    return result;
  }

  static List<List<String>> _records(String source) {
    final records = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var afterQuote = false;
    var fieldStarted = false;
    var rowStarted = false;

    void finishField() {
      row.add(field.toString());
      if (row.length > maximumColumns) {
        throw const FormatException('台股 CSV 超過 128 欄上限。');
      }
      field = StringBuffer();
      fieldStarted = false;
      afterQuote = false;
    }

    void finishRow() {
      finishField();
      records.add(row);
      if (records.length > maximumRows + 1) {
        throw const FormatException('台股 CSV 超過 5000 筆資料上限。');
      }
      row = <String>[];
      rowStarted = false;
    }

    for (var index = 0; index < source.length; index++) {
      final code = source.codeUnitAt(index);
      if (quoted) {
        if (code == 34) {
          if (index + 1 < source.length && source.codeUnitAt(index + 1) == 34) {
            field.write('"');
            index++;
          } else {
            quoted = false;
            afterQuote = true;
          }
        } else {
          field.writeCharCode(code);
        }
        continue;
      }
      if (code == 44) {
        finishField();
        rowStarted = true;
      } else if (code == 10 || code == 13) {
        if (code == 13 &&
            index + 1 < source.length &&
            source.codeUnitAt(index + 1) == 10) {
          index++;
        }
        finishRow();
      } else if (code == 34 && !fieldStarted && !afterQuote) {
        quoted = true;
        fieldStarted = true;
        rowStarted = true;
      } else {
        if (code == 34 || afterQuote) {
          throw const FormatException('台股 CSV 引號格式無效。');
        }
        field.writeCharCode(code);
        fieldStarted = true;
        rowStarted = true;
      }
    }
    if (quoted) throw const FormatException('台股 CSV 引號未結束。');
    if (rowStarted || row.isNotEmpty || fieldStarted || afterQuote) finishRow();
    return records;
  }
}
