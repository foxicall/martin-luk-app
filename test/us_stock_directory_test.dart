import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:martin_luk_app/models/stock_candidate.dart';
import 'package:martin_luk_app/models/stock_item.dart';
import 'package:martin_luk_app/services/us_stock_directory.dart';

const _nasdaqHeader = 'Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares';
const _otherHeader = 'ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol';

String _nasdaq(List<String> rows, {String footer = 'File Creation Time: 1015202608:00|||||||'}) =>
    '$_nasdaqHeader\n${rows.join('\n')}\n$footer\n';
String _other(List<String> rows) =>
    '$_otherHeader\n${rows.join('\n')}\nFile Creation Time: 1015202608:00||||||\n';
const _nvda = 'NVDA|NVIDIA Corporation - Common Stock|Q|N|N|100|N|N';
const _aapl = 'AAPL|Apple Inc. - Common Stock|Q|N|N|100|N|N';

UsDirectoryResult _parse(String text, {bool nasdaq = true}) =>
    UsStockDirectory.parseBytes(utf8.encode(text), nasdaq: nasdaq);

void main() {
  test('canonical real-directory structure and seven-column footer retain names and date', () {
    final result = _parse(_other([
      'BRK.B|Berkshire Hathaway Inc. Class B Common Stock|N|BRK.B|N|100|N|BRK.B',
      'UAMY|United States Antimony Corporation Common Stock|A|UAMY|N|100|N|UAMY',
    ]), nasdaq: false);
    expect(result.stocks.map((stock) => stock.symbol), ['BRK-B', 'UAMY']);
    expect(result.fileDate, DateTime.utc(2026, 10, 15));
    expect(result.fileDate!.hour, 0, reason: 'The source did not declare its time zone.');
    expect(result.isComplete, isTrue);
    expect(result.warnings, isEmpty);
    expect(() => result.stocks.clear(), throwsUnsupportedError);
  });

  test('UTF-8 BOM, leading blanks, header spaces, footer spaces and empty tail columns are harmless', () {
    final text = '\ufeff\n\r\n  Symbol | Security Name | Market Category | Test Issue | Financial Status | Round Lot Size | ETF | NextShares |\n'
        '$_nvda||\n'
        '  File Creation Time: 1015202608:00|||||||  \n\n';
    final result = _parse(text);
    expect(result.stocks.single.symbol, 'NVDA');
    expect(result.isComplete, isTrue);
  });

  test('declared Latin-1 decodes 0xe9 without losing the entire source', () {
    final text = _nasdaq(['CAFE|Caf\u00e9 Corporation Common Stock|Q|N|N|100|N|N']);
    final result = UsStockDirectory.parseBytes(latin1.encode(text), nasdaq: true,
        contentType: 'text/plain; charset="iso-8859-1"');
    expect(result.stocks.single.nameEn, 'Caf\u00e9 Corporation Common Stock');
    expect(result.isComplete, isTrue);
  });

  test('declared Windows-1252 maps smart punctuation rather than C1 controls', () {
    final text = _nasdaq(['CAFE|Cafe Corporation \u2013 Common Stock|Q|N|N|100|N|N']);
    final bytes = text.codeUnits.map((unit) => unit == 0x2013 ? 0x96 : unit).toList();
    final result = UsStockDirectory.parseBytes(bytes, nasdaq: true,
        contentType: 'text/plain; charset=Windows-1252');
    expect(result.stocks.single.nameEn, 'Cafe Corporation \u2013 Common Stock');
    expect(result.isComplete, isTrue);
  });

  test('undeclared legacy 0xe9 recovers conservatively with visible incomplete coverage', () {
    final text = _nasdaq(['CAFE|Caf\u00e9 Corporation Common Stock|Q|N|N|100|N|N', _nvda]);
    final result = UsStockDirectory.parseBytes(latin1.encode(text), nasdaq: true);
    expect(result.stocks.first.nameEn, 'Caf\u00e9 Corporation Common Stock');
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('Windows-1252'));
  });

  test('encoding fallback cannot turn an invalid header or missing footer into a directory', () {
    expect(() => UsStockDirectory.parseBytes(latin1.encode('Caf\u00e9 login required'), nasdaq: true),
        throwsFormatException);
    final missingFooter = '$_nasdaqHeader\nCAFE|Caf\u00e9 Common Stock|Q|N|N|100|N|N\n';
    expect(() => UsStockDirectory.parseBytes(latin1.encode(missingFooter), nasdaq: true),
        throwsFormatException);
  });

  test('UTF-16 LE and BE BOMs are decoded without adding dependencies', () {
    final text = _nasdaq([_nvda]);
    for (final little in [true, false]) {
      final bytes = <int>[
        if (little) ...[0xff, 0xfe] else ...[0xfe, 0xff],
        for (final unit in text.codeUnits)
          if (little) ...[unit & 0xff, unit >> 8] else ...[unit >> 8, unit & 0xff],
      ];
      final result = UsStockDirectory.parseBytes(bytes, nasdaq: true);
      expect(result.stocks.single.symbol, 'NVDA');
      expect(result.isComplete, isTrue);
    }
    expect(() => UsStockDirectory.parseBytes([0xff, 0xfe, 0x53], nasdaq: true),
        throwsFormatException);
  });

  test('200 HTML, JSON and bot-denial texts produce specific diagnostic errors', () {
    expect(() => _parse('<!doctype html><title>Just a moment</title>'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('HTML'))));
    expect(() => _parse('{"error":"denied"}'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('JSON'))));
    expect(() => _parse('Access Denied: please enable JavaScript'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('驗證'))));
  });

  test('one malformed row is isolated and its peer stocks survive', () {
    final result = _parse(_nasdaq([_nvda, 'broken|row', _aapl]));
    expect(result.stocks.map((stock) => stock.symbol), ['AAPL', 'NVDA']);
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('1 行格式錯誤'));
    expect(result.warnings.join(' '), contains('第 3 行'));
  });

  test('a duplicate is isolated instead of discarding thousands of other symbols', () {
    final result = _parse(_nasdaq([_nvda, _nvda, _aapl]));
    expect(result.stocks.map((stock) => stock.symbol), ['AAPL', 'NVDA']);
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('1 行重複'));
  });

  test('mostly corrupt rows, truncated files and empty ordinary-stock lists are rejected', () {
    expect(() => _parse(_nasdaq([_nvda, 'bad', 'also|bad'])), throwsFormatException);
    expect(() => _parse('$_nasdaqHeader\n$_nvda\n'), throwsFormatException);
    expect(() => _parse(_nasdaq([])), throwsFormatException);
    expect(() => _parse(_nasdaq(['ETF|Index ETF|Q|N|N|100|Y|N'])), throwsFormatException);
    expect(() => _parse('Symbol|Name\nNVDA|NVIDIA\nFile Creation Time: 1015202608:00'),
        throwsFormatException);
  });

  test('invalid calendar dates and data appended after the footer are rejected', () {
    expect(() => _parse(_nasdaq([_nvda], footer: 'File Creation Time: 0230202608:00|||||||')),
        throwsFormatException);
    expect(() => _parse('${_nasdaq([_nvda])}$_aapl\n'), throwsFormatException);
  });

  test('ETF, tests, preferred, funds, receipts and other exchanges stay outside ordinary scope', () {
    final result = _parse(_other([
      'BRK.B|Berkshire Hathaway Class B Common Stock|N|BRK.B|N|100|N|BRK.B',
      'AMEX|Example Ordinary Shares|A|AMEX|N|100|N|AMEX',
      'REIT|Example Real Estate Investment Trust Common Stock|N|REIT|N|100|N|REIT',
      'TRST|Corporate Trust Inc. Common Stock|N|TRST|N|100|N|TRST',
      'SPY|Index Common Stock ETF|P|SPY|Y|100|N|SPY',
      'TEST|Example Common Stock|N|TEST|N|100|Y|TEST',
      'ARCA|Example Common Stock|P|ARCA|N|100|N|ARCA',
      'BATS|Example Common Stock|Z|BATS|N|100|N|BATS',
      'PREF|Example Preferred Common Stock|N|PREF|N|100|N|PREF',
      'ADR|Example American Depositary Shares|N|ADR|N|100|N|ADR',
      'UNIT|Example Units including Common Stock|N|UNIT|N|100|N|UNIT',
      'FUND|Income Funds Common Stock|N|FUND|N|100|N|FUND',
      'BEN|Income Common Shares of Beneficial Interest|N|BEN|N|100|N|BEN',
      'INV|Income Investment Trust Common Stock|N|INV|N|100|N|INV',
    ]), nasdaq: false);
    expect(result.stocks.map((stock) => stock.symbol), ['AMEX', 'BRK-B', 'REIT', 'TRST']);
    expect(result.isComplete, isTrue,
        reason: 'Deliberately out-of-scope instruments are different from unknown classifications.');
  });

  test('unknown classifications and invalid Y/N values cannot claim full coverage', () {
    final result = _parse(_nasdaq([
      _nvda,
      'UNK|Unknown Security|Q|N|N|100|N|N',
      'BAD|Example Common Stock|Q|N|N|100||N',
    ]));
    expect(result.stocks.single.symbol, 'NVDA');
    expect(result.isComplete, isFalse);
    expect(result.warnings.join(' '), contains('未能確認普通股'));
    expect(result.warnings.join(' '), contains('ETF／Test Issue'));
  });

  test('known aliases are merged only into genuine returned symbols', () {
    final known = StockItem(market: StockMarket.us, symbol: 'NVDA', code: 'NVDA',
        nameZh: '輝達', nameFullZh: '輝達公司', nameEn: 'Old source name', abbrEn: 'Nvidia');
    final result = UsStockDirectory.parseText(_nasdaq([_nvda]), nasdaq: true,
        master: {'us:NVDA': known});
    expect(result.stocks.single.nameZh, '輝達');
    expect(result.stocks.single.nameEn, 'NVIDIA Corporation - Common Stock');
  });
}
