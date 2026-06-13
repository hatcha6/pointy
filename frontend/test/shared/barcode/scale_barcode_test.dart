import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/scale_barcode.dart';

void main() {
  group('parseScaleBarcode', () {
    test('parses a 2-prefixed EAN-13 with embedded weight', () {
      // 20 12345 01500 C → item 12345, 1.500 kg.
      const code = '2012345015005';
      expect(isValidEan13(code), isTrue);

      final parsed = parseScaleBarcode(code);

      expect(parsed, isNotNull);
      expect(parsed!.itemCode, '12345');
      expect(parsed.weightKg, closeTo(1.5, 0.0001));
      expect(
        parsed.candidateBarcodes,
        containsAll(<String>['2012345', '12345']),
      );
    });

    test('strips leading zeros from candidate item codes', () {
      const code = '2000042003500';
      expect(isValidEan13(code), isTrue);

      final parsed = parseScaleBarcode(code);

      expect(parsed, isNotNull);
      expect(parsed!.itemCode, '00042');
      expect(parsed.weightKg, closeTo(0.35, 0.0001));
      expect(parsed.candidateBarcodes, contains('42'));
    });

    test('rejects wrong checksum, prefix, length, and zero weight', () {
      expect(parseScaleBarcode('2012345015004'), isNull); // bad check digit
      expect(parseScaleBarcode('6012345015002'), isNull); // not a 2-prefix
      expect(parseScaleBarcode('20123450150'), isNull); // too short
      expect(parseScaleBarcode('20123ا5015005'), isNull); // non-digit
      // valid EAN but zero weight → not a usable scale label
      expect(isValidEan13('2012345000001'), isTrue);
      expect(parseScaleBarcode('2012345000001'), isNull);
    });

    test('ordinary product barcodes are untouched', () {
      expect(parseScaleBarcode('6291041500213'), isNull);
      expect(parseScaleBarcode('SKU-123'), isNull);
    });
  });
}
