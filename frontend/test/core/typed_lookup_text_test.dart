import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/typed_lookup_text.dart';

void main() {
  group('a typed name is not a barcode', () {
    test('Arabic words are names', () {
      expect(looksLikeTypedName('حليب'), isTrue);
      expect(looksLikeTypedName('حليب 1 لتر'), isTrue);
    });

    test('codes stay codes, including one scanned on the Arabic layout', () {
      expect(looksLikeTypedName('6241000045811'), isFalse);
      expect(looksLikeTypedName('1/4'), isFalse);
      expect(looksLikeTypedName('AB-123'), isFalse);
      // A scanner on the Arabic layout types «AB123» as «شلا123»: no space,
      // digits kept.
      expect(looksLikeTypedName('شلا123'), isFalse);
    });
  });

  group('phone numbers', () {
    test('every way a Libyan mobile number is written', () {
      for (final written in [
        '0912345678',
        '091 234 5678',
        '+218 91-234-5678',
        '00218912345678',
        '912345678',
        '٠٩١٢٣٤٥٦٧٨',
      ]) {
        expect(looksLikePhoneNumber(written), isTrue, reason: written);
      }
    });

    test('barcodes and codes are not phone numbers', () {
      for (final code in ['6241000045811', '24002', '1004', 'حليب']) {
        expect(looksLikePhoneNumber(code), isFalse, reason: code);
      }
    });
  });

  group('one article\'s identifier', () {
    test('an IMEI, a VIN and a serial read as identifiers', () {
      for (final typed in [
        '351234567890116',
        ' 351234-567890116 ',
        '٣٥١٢٣٤٥٦٧٨٩٠١١٦',
        '1HGCM82633A004352',
        'sn-20391a',
      ]) {
        expect(looksLikeUnitIdentifier(typed), isTrue, reason: typed);
      }
    });

    test('names, words and short codes stay a product search', () {
      for (final typed in [
        '',
        'حليب',
        'iPhone 13',
        'charger',
        'SAMSUNG',
        '12345',
        'شلا123',
        '351234 567890116',
      ]) {
        expect(looksLikeUnitIdentifier(typed), isFalse, reason: typed);
      }
    });

    test('normalises the way the server matches', () {
      expect(normalizeUnitIdentifier(' 351234-567890116 '), '351234567890116');
      expect(normalizeUnitIdentifier('٣٥١٢٣٤٥٦٧٨٩٠١١٦'), '351234567890116');
      expect(normalizeUnitIdentifier('sn/20.39_1a'), 'SN20391A');
    });
  });
}
