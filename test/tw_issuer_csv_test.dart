import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/services/tw_issuer_csv.dart';

const _header = '出表日期,公司代號,公司名稱,公司簡稱,產業別';
final _now = DateTime.utc(2026, 10, 16, 1);

TwIssuerCsvDocument _parse(
  String csv, {
  DateTime? now,
  int maximumAgeDays = 7,
}) => TwIssuerCsv.parseBytes(
  utf8.encode(csv),
  now: now ?? _now,
  maximumAgeDays: maximumAgeDays,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preserves RFC4180 quoted commas, escaped quotes and embedded CRLF', () {
    final document = _parse(
      '\uFEFF$_header\r\n'
      '1151016,2330,"Taiwan, Semiconductor ""Company""",台積電,24\r\n'
      '1151016,6488,"公司第一行\r\n公司第二行",環球晶,24\r\n',
    );
    expect(document.rows, hasLength(2));
    expect(document.rows.first['公司代號'], '2330');
    expect(document.rows.first['公司名稱'], 'Taiwan, Semiconductor "Company"');
    expect(document.rows.last['公司名稱'], '公司第一行\r\n公司第二行');
    expect(document.rows.last['產業別'], '24');
    expect(document.asOf, DateTime.utc(2026, 10, 15, 16));
    expect(document.asOf.isUtc, isTrue);
  });

  test('accepts LF, standalone CR, final row without newline and empty cells', () {
    final document = _parse(
      '出表日期,公司代號,公司簡稱,備註\r'
      '20261016,2330,台積電,\n'
      '20261016,6488,環球晶,""',
    );
    expect(document.rows, hasLength(2));
    expect(document.rows.every((row) => row['備註'] == ''), isTrue);
  });

  for (final date in ['1151016', '20261016', '115/10/16', '2026-10-16']) {
    test('interprets official publication date $date at Taiwan midnight', () {
      final document = _parse('$_header\n$date,2330,台積電股份有限公司,台積電,24');
      expect(document.asOf, DateTime.utc(2026, 10, 15, 16));
    });
  }

  test('mixed valid publication dates conservatively report the oldest', () {
    final document = _parse(
      '$_header\n'
      '1151016,2330,台積電股份有限公司,台積電,24\n'
      '1151015,6488,環球晶圓股份有限公司,環球晶,24',
    );
    expect(document.asOf, DateTime.utc(2026, 10, 14, 16));
  });

  test('freshness uses Taipei calendar days, including weekends and boundary', () {
    expect(
      _parse('$_header\n1151009,2330,台積電股份有限公司,台積電,24').asOf,
      DateTime.utc(2026, 10, 8, 16),
    );
    expect(
      () => _parse('$_header\n1151008,2330,台積電股份有限公司,台積電,24'),
      throwsFormatException,
    );
    expect(
      () => _parse(
        '$_header\n1151016,2330,台積電股份有限公司,台積電,24',
        now: DateTime.utc(2026, 10, 15, 15, 59, 59),
      ),
      throwsFormatException,
      reason: 'Taipei is still October 15 just before UTC 16:00.',
    );
    expect(
      _parse(
        '$_header\n1151016,2330,台積電股份有限公司,台積電,24',
        now: DateTime.utc(2026, 10, 15, 16),
      ).rows,
      hasLength(1),
    );
  });

  test('a future or stale row rejects the entire file, even after valid rows', () {
    for (final date in ['1151017', '1151008']) {
      expect(
        () => _parse(
          '$_header\n'
          '1151016,2330,台積電股份有限公司,台積電,24\n'
          '$date,6488,環球晶圓股份有限公司,環球晶,24',
        ),
        throwsFormatException,
      );
    }
  });

  test('publication date is mandatory and cannot come from listing date', () {
    expect(
      () => _parse('上市日期,公司代號,公司名稱\n1151016,2330,台積電'),
      throwsFormatException,
    );
    expect(
      () => _parse('出表日期,上市日期,公司代號,公司名稱\n,1151016,2330,台積電'),
      throwsFormatException,
    );
  });

  test('rejects normalized calendar dates instead of accepting invalid days', () {
    final leapDay = _parse(
      '$_header\n1130229,2330,台積電股份有限公司,台積電,24',
      now: DateTime.utc(2024, 3, 1),
    );
    expect(leapDay.asOf, DateTime.utc(2024, 2, 28, 16));
    for (final date in [
      '1150230', '20260229', '1150001', '1151301', '1151000',
      '0001016', '00001016', '2026/10-16', 'today', '',
    ]) {
      expect(
        () => _parse('$_header\n$date,2330,台積電股份有限公司,台積電,24'),
        throwsFormatException,
        reason: 'Invalid publication date: $date',
      );
    }
  });

  test('rejects invalid UTF8, empty, NUL, HTML and unrecognized schemas', () {
    expect(
      () => TwIssuerCsv.parseBytes([0xc3, 0x28], now: _now),
      throwsFormatException,
    );
    for (final source in [
      '', '\uFEFF \r\n', '<html><body>Access denied</body></html>',
      '<!DOCTYPE html>\n<html>Unavailable</html>',
      'code,name,date\n2330,台積電,1151016',
      '公司代號,公司簡稱\n2330,台積電',
      '出表日期,公司代號\n1151016,2330',
      '$_header\n1151016,2330,台積\u0000電,台積電,24',
    ]) {
      expect(() => _parse(source), throwsFormatException);
    }
  });

  test('rejects duplicate/empty headers, missing records and ragged rows', () {
    for (final source in [
      '出表日期,公司代號,公司簡稱,公司代號\n1151016,2330,台積電,2330',
      '出表日期,公司代號,公司簡稱, 公司代號 \n1151016,2330,台積電,2330',
      '出表日期,公司代號,公司簡稱,\n1151016,2330,台積電,',
      _header, '$_header\r\n',
      '$_header\n1151016,2330,台積電,台積電',
      '$_header\n1151016,2330,台積電,台積電,24,extra',
      '$_header\n1151016,2330,台積電,台積電,24\n\n',
    ]) {
      expect(() => _parse(source), throwsFormatException);
    }
  });

  test('rejects unfinished quotes, quotes in bare fields and text after quotes', () {
    for (final row in [
      '1151016,2330,"unclosed,台積電,24',
      '1151016,2330,bare"quote,台積電,24',
      '1151016,2330,"closed"suffix,台積電,24',
      '1151016,2330,"closed" ,台積電,24',
    ]) {
      expect(() => _parse('$_header\n$row'), throwsFormatException);
    }
  });

  test('enforces input byte, row and column bounds', () {
    expect(
      () => TwIssuerCsv.parseBytes(
        List.filled(TwIssuerCsv.maximumBytes + 1, 32), now: _now,
      ),
      throwsFormatException,
    );
    const row = '1151016,2330,台積電股份有限公司,台積電,24';
    final maximumRows = '$_header\n${List.filled(5000, row).join('\n')}';
    expect(_parse(maximumRows).rows, hasLength(5000));
    expect(() => _parse('$maximumRows\n$row'), throwsFormatException);
    final tooManyColumns = List.generate(129, (index) => '欄位$index').join(',');
    expect(() => _parse('$tooManyColumns\n$row'), throwsFormatException);
  });

  test('an explicitly tighter age limit is enforced', () {
    expect(
      () => _parse('$_header\n1151015,2330,台積電股份有限公司,台積電,24',
          maximumAgeDays: 0),
      throwsFormatException,
    );
    expect(
      () => _parse('$_header\n1151016,2330,台積電股份有限公司,台積電,24',
          maximumAgeDays: -1),
      throwsArgumentError,
    );
  });

  test('returned rows cannot be changed after validation', () {
    final document = _parse('$_header\n1151016,2330,台積電股份有限公司,台積電,24');
    expect(() => document.rows.clear(), throwsUnsupportedError);
    expect(() => document.rows.first['公司代號'] = '9999', throwsUnsupportedError);
  });
}
