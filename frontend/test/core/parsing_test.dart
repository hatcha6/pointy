import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/parsing.dart';

void main() {
  group('parseDecimal', () {
    test('parses plain ASCII decimals', () {
      expect(parseDecimal('12.5'), 12.5);
      expect(parseDecimal('0'), 0);
      expect(parseDecimal('1000'), 1000);
    });

    test('treats a comma as the decimal separator', () {
      expect(parseDecimal('12,5'), 12.5);
      expect(parseDecimal('0,75'), 0.75);
    });

    test('trims surrounding whitespace', () {
      expect(parseDecimal('  3.5  '), 3.5);
    });

    test('converts Arabic-Indic digits and decimal separator', () {
      expect(parseDecimal('١٢'), 12);
      expect(parseDecimal('٣٫٥'), 3.5);
      expect(parseDecimal('٠٫٧٥'), 0.75);
    });

    test('returns null for blank or non-numeric input', () {
      expect(parseDecimal(null), isNull);
      expect(parseDecimal(''), isNull);
      expect(parseDecimal('   '), isNull);
      expect(parseDecimal('abc'), isNull);
    });
  });

  group('parseDecimalOr', () {
    test('falls back to zero by default', () {
      expect(parseDecimalOr(''), 0);
      expect(parseDecimalOr('nope'), 0);
    });

    test('uses the provided fallback', () {
      expect(parseDecimalOr(null, 1), 1);
      expect(parseDecimalOr('5', 1), 5);
    });
  });
}
