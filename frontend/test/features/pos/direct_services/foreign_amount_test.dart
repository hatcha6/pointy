import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/foreign_amount.dart';

/// Amounts in another country's currency: shown grouped, typed any way a
/// cashier types, and sent to the relay as a plain decimal.
void main() {
  group('showing an amount', () {
    test('groups thousands and drops decimals nobody needs', () {
      expect(formatForeignAmount(5000), '5,000');
      expect(formatForeignAmount(1967), '1,967');
      expect(formatForeignAmount(100), '100');
      expect(formatForeignAmount(0), '0');
      expect(formatForeignAmount(1234567), '1,234,567');
      expect(formatForeignAmount(2500.5), '2,500.5');
      expect(formatForeignAmount(2.75), '2.75');
      expect(formatForeignAmount(0.5), '0.5');
      expect(formatForeignAmount(1234567.891), '1,234,567.89');
      expect(formatForeignAmount(5000.00), '5,000');
    });

    test(
      'formats the relay\'s decimal strings, and leaves other text alone',
      () {
        expect(formatForeignAmountText('5000'), '5,000');
        expect(formatForeignAmountText('1967.50'), '1,967.5');
        expect(formatForeignAmountText(' 32800 '), '32,800');
        expect(formatForeignAmountText('abc'), 'abc');
      },
    );
  });

  group('reading what was typed', () {
    test('plain digits', () {
      expect(parseTypedAmount('5000'), 5000);
      expect(parseTypedAmount(' 5000 '), 5000);
      expect(parseTypedAmount('٥٠٠٠'), 5000);
      expect(parseTypedAmount('۵۰۰۰'), 5000);
    });

    test('a comma before exactly three digits groups thousands', () {
      expect(parseTypedAmount('5,000'), 5000);
      expect(parseTypedAmount('1,234,567'), 1234567);
      expect(parseTypedAmount('5 000'), 5000);
    });

    test('a comma or dot otherwise is the decimal point', () {
      expect(parseTypedAmount('5,5'), 5.5);
      expect(parseTypedAmount('12,50'), 12.5);
      expect(parseTypedAmount('1.5'), 1.5);
      expect(parseTypedAmount('1,234.50'), 1234.5);
      expect(parseTypedAmount('1.234,50'), 1234.5);
      expect(parseTypedAmount('0.5'), 0.5);
      expect(parseTypedAmount('.5'), 0.5);
      expect(parseTypedAmount('5.'), 5);
      expect(parseTypedAmount('٥٫٥'), 5.5);
      expect(parseTypedAmount('٥٬٠٠٠'), 5000);
    });

    test('is not an amount when it is not a plain positive number', () {
      for (final raw in const [
        '',
        ' ',
        'abc',
        '0',
        '00',
        '-5',
        '5.000',
        '1..2',
        '5,5,5',
        '1e3',
      ]) {
        expect(parseTypedAmount(raw), isNull, reason: raw);
      }
    });

    test('is sent as a plain decimal, no grouping, no trailing zeros', () {
      expect(canonicalAmountText('5,000'), '5000');
      expect(canonicalAmountText('2500.50'), '2500.5');
      expect(canonicalAmountText('007'), '7');
      expect(canonicalAmountText('٥٠٠٠'), '5000');
      expect(canonicalAmountText('12,50'), '12.5');
      expect(canonicalAmountText('abc'), isNull);
    });
  });
}
