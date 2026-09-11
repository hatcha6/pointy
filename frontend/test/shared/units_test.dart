import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/units.dart';

/// Mirrors `conversion_factor` in `backend/apps/catalog/scale_quantity.py`.
/// The two are consulted about the same label — one at the till, one at the
/// price checker — so they have to agree about what cannot be converted.
void main() {
  group('unitConversionFactor', () {
    test('the same unit needs no conversion', () {
      expect(unitConversionFactor('kg', 'kg'), 1);
    });

    test('converts within a dimension', () {
      expect(unitConversionFactor('kg', 'g'), closeTo(1000, 0.000001));
      expect(unitConversionFactor('g', 'kg'), closeTo(0.001, 0.000001));
      expect(unitConversionFactor('l', 'ml'), closeTo(1000, 0.000001));
    });

    test('refuses to cross dimensions', () {
      expect(unitConversionFactor('kg', 'l'), isNull);
      expect(unitConversionFactor('kg', 'piece'), isNull);
    });

    test('refuses a packaging unit, whose factor is per product', () {
      expect(unitConversionFactor('kg', 'box'), isNull);
      expect(unitConversionFactor('kg', 'carton'), isNull);
    });

    test('an unnamed unit is not silently the same unit', () {
      expect(unitConversionFactor('', 'kg'), isNull);
      expect(unitConversionFactor('kg', ''), isNull);
    });

    test('an unknown custom unit is refused rather than guessed', () {
      expect(unitConversionFactor('kg', 'sack'), isNull);
    });
  });
}
