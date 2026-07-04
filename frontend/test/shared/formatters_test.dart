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
}
