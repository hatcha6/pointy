import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/catalog/views/variant_gtin_field.dart';
import 'package:pointy_frontend/src/shared/tracking/gtin.dart';

/// The client's GTIN check refuses exactly what the server's does, so a typo
/// is caught under the field rather than as a failed save.
void main() {
  test('every printed length is the same GTIN-14', () {
    expect(normalizeGtin('4006381333931'), '04006381333931');
    expect(normalizeGtin('036000291452'), '00036000291452');
    expect(normalizeGtin('96385074'), '00000096385074');
    expect(normalizeGtin('400 6381-333931'), '04006381333931');
    expect(normalizeGtin(''), '');
  });

  test('a wrong check digit, length or letter is named', () {
    expect(gtinProblem('4006381333932'), GtinProblem.checkDigit);
    expect(gtinProblem('12345'), GtinProblem.length);
    expect(gtinProblem('40063813339X1'), GtinProblem.notDigits);
    expect(gtinProblem('4006381333931'), isNull);
    expect(normalizeGtin('4006381333932'), isNull);
  });

  test('a scanned DataMatrix gives its GTIN, a plain number does not', () {
    const symbol = '01034531200000111729113010ABC123\u001d2112345';
    expect(gtinFromGs1Scan(symbol), '03453120000011');
    expect(gtinFromGs1Scan(']d2$symbol'), '03453120000011');
    expect(gtinFromGs1Scan('4006381333931'), isNull);
    expect(gtinFieldValue(symbol), '03453120000011');
    expect(gtinFieldValue(' 4006381333931 '), '4006381333931');
  });
}
