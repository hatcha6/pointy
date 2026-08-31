import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

void main() {
  setUp(() {
    configureCurrencySymbol('د.ل');
    configureForeignCurrencySymbols(const {'USD': r'$', 'TRY': '₺'});
  });

  group('base currency', () {
    test('formats with the shop symbol', () {
      expect(formatMoney(82.2), '82.20 د.ل');
    });

    test('a blank configured symbol is ignored', () {
      configureCurrencySymbol('   ');
      expect(formatMoney(1), '1.00 د.ل');
    });
  });

  group('foreign currency', () {
    test('uses the registered symbol', () {
      expect(formatForeignMoney(12, 'USD'), r'12.00 $');
    });

    test('falls back to the code when unknown', () {
      expect(formatForeignMoney(12, 'AED'), '12.00 AED');
    });

    test('lookup is case and whitespace insensitive', () {
      expect(currencySymbolFor(' usd '), r'$');
    });
  });

  group('dual price', () {
    test('shows both the maintained price and the shelf price', () {
      final label = formatDualPrice(12, 'USD', 82.2);
      expect(label, contains(r'12.00 $'));
      expect(label, contains('82.20 د.ل'));
      expect(label, contains('≈'));
    });

    test('isolates each amount so RTL cannot reorder the halves', () {
      // Without the isolates the bidi algorithm reorders "12.00 $" and
      // "82.20 د.ل" into nonsense inside an Arabic paragraph.
      final label = formatDualPrice(12, 'USD', 82.2);
      expect(label.contains('\u2068'), isTrue);
      expect(label.contains('\u2069'), isTrue);
    });
  });

  group('exchange rate', () {
    test('reads as one unit of the foreign currency', () {
      final label = formatExchangeRate(6.85, 'USD', 'LYD');
      expect(label, contains(r'1 $'));
      expect(label, contains('6.85 د.ل'));
    });

    test('keeps the places a parallel rate actually moves in', () {
      expect(formatExchangeRate(6.8523, 'USD', 'LYD'), contains('6.8523'));
    });

    test('trims trailing zeros rather than showing false precision', () {
      expect(formatExchangeRate(7, 'USD', 'LYD'), contains('7 د.ل'));
    });
  });
}
