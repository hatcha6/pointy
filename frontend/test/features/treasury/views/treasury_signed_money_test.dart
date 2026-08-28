import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/treasury/views/treasury_ui.dart';

/// The breakdown puts an Arabic label and a signed amount on one line. Bidi
/// decides where a neutral character between them lands, so a minus sign left
/// loose can render against the label rather than the number it negates — the
/// difference between "المصروفات ‎−180.00" and a line that reads as a positive.
void main() {
  const isolateStart = '\u2066'; // FIRST STRONG ISOLATE
  const isolateEnd = '\u2069'; // POP DIRECTIONAL ISOLATE
  const minus = '\u2212'; // MINUS SIGN, not HYPHEN-MINUS

  test('the sign travels inside the isolate with its number', () {
    final negative = treasurySignedMoney(-180);

    expect(negative.startsWith(isolateStart), isTrue);
    expect(negative.endsWith(isolateEnd), isTrue);
    // The sign must be inside, immediately before the digits.
    expect(negative.indexOf(minus), 1);
    expect(negative, contains('180.00'));
    // A hyphen-minus would be the wrong character and reads thinner beside
    // Arabic digits; the typographic minus is deliberate.
    expect(negative, isNot(contains('-')));
  });

  test('a positive amount is signed too, so the two read as a pair', () {
    final positive = treasurySignedMoney(300);

    expect(positive.indexOf('+'), 1);
    expect(positive, contains('300.00'));
  });

  test('zero carries no sign at all', () {
    final zero = treasurySignedMoney(0);

    expect(zero, isNot(contains('+')));
    expect(zero, isNot(contains(minus)));
    expect(zero, contains('0.00'));
  });

  test(
    'every amount is isolated, so a neighbouring label cannot reorder it',
    () {
      for (final amount in [-1250.75, -0.01, 0.0, 0.01, 9999.99]) {
        final formatted = treasurySignedMoney(amount);
        expect(formatted.startsWith(isolateStart), isTrue, reason: '$amount');
        expect(formatted.endsWith(isolateEnd), isTrue, reason: '$amount');
      }
    },
  );
}
