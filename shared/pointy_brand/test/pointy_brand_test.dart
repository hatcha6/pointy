import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_brand/pointy_brand.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every listed payment mark ships with the package', () async {
    for (final provider in [
      'sadad',
      'edfali',
      'mobicash',
      'yussor-pay',
      'masrafi-pay',
      'sahara-pay',
    ]) {
      final mark = PaymentMethodMarks.of(provider)!;
      final bytes = await rootBundle.load(mark.keyName);
      expect(bytes.lengthInBytes, greaterThan(0), reason: provider);
    }
    expect(PaymentMethodMarks.of('moamalat'), isNull);
  });

  test('the type ramp names the packaged face and drops letter spacing', () {
    final theme = PointyTypography.textTheme(
      const TextTheme(bodyMedium: TextStyle(letterSpacing: 0.25)),
    );
    expect(
      theme.bodyMedium!.fontFamily,
      'packages/pointy_brand/IBMPlexSansArabic',
    );
    expect(theme.bodyMedium!.letterSpacing, 0);
  });
}
