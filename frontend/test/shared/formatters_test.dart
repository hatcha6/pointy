import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

void main() {
  group('formatMoney currency', () {
    // formatMoney reads a module-global symbol; reset it after each test so the
    // configured value never leaks into other tests.
    tearDown(() => configureCurrencySymbol('د.ل'));

    test('defaults to the Libyan dinar', () {
      expect(formatMoney(12.5), '12.50 د.ل');
    });

    test('uses the configured symbol after configureCurrencySymbol', () {
      configureCurrencySymbol(r'$');
      expect(formatMoney(12.5), r'12.50 $');
      expect(currencySymbol, r'$');
    });

    test('ignores a blank symbol and keeps the previous one', () {
      configureCurrencySymbol('€');
      configureCurrencySymbol('   ');
      expect(formatMoney(1), '1.00 €');
    });
  });

  group('formatSpokenMoney', () {
    test('drops trailing zeros for a clean spoken number', () {
      expect(formatSpokenMoney('8.00'), '8');
      expect(formatSpokenMoney('2.50'), '2.5');
      expect(formatSpokenMoney('1.25'), '1.25');
    });

    test('carries no currency symbol (the phrase supplies the word)', () {
      expect(formatSpokenMoney('12.00'), isNot(contains('د')));
    });

    test('falls back to the raw text when it is not a number', () {
      expect(formatSpokenMoney('السعر'), 'السعر');
    });
  });

  group('ltrIsolated', () {
    test('wraps the run in an LTR isolate, unchanged otherwise', () {
      expect(
        ltrIsolated('192.168.1.50:20304'),
        '\u{2066}192.168.1.50:20304\u{2069}',
      );
    });

    test('an empty value still closes the isolate it opened', () {
      expect(ltrIsolated(''), '\u{2066}\u{2069}');
    });

    test('the isolate is LTR, not first-strong', () {
      // These runs open with digits, which are not strong: a first-strong
      // isolate would resolve them to the surrounding Arabic and reorder the
      // very thing the isolate is protecting.
      expect(ltrIsolated('1').codeUnitAt(0), 0x2066);
      expect(ltrIsolated('1').codeUnitAt(2), 0x2069);
    });
  });
}
