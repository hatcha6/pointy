import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/code_text.dart';
import 'package:pointy_cards/src/core/redeem.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';

void main() {
  test('a code delivered with its PIN on the same line is the code alone', () {
    const cases = {
      // As fazercards delivered an Apple card.
      'XPRCMDHC6W6G6PCJ / PIN: XPRCMDHC6W6G6PCJ': ('XPRCMDHC6W6G6PCJ', ''),
      'AAAA-BBBB-CCCC / PIN: 1234': ('AAAA-BBBB-CCCC', '1234'),
      'AAAA-BBBB-CCCC | Pin Code: 1234': ('AAAA-BBBB-CCCC', '1234'),
      'Code: AAAA-BBBB PIN: 99': ('AAAA-BBBB', '99'),
      '4827 1930 5561 2208': ('4827 1930 5561 2208', ''),
      'AAAA/BBBB': ('AAAA/BBBB', ''),
    };
    for (final MapEntry(key: line, value: (code, pin)) in cases.entries) {
      final split = splitLabelledCode(line);
      expect(split.code, code, reason: line);
      expect(split.pin, pin, reason: line);
    }
  });

  test('a saved card with the PIN line reads as its code, and can be '
      'redeemed in one tap again', () {
    final saved = CardCode.fromJson({
      'code': 'XPRCMDHC6W6G6PCJ / PIN: XPRCMDHC6W6G6PCJ',
      'serial': '',
    });
    expect(saved.code, 'XPRCMDHC6W6G6PCJ');
    expect(saved.serial, '');
    final apple = CardRedeem.fromJson({
      'kind': 'link',
      'template': 'https://apps.apple.com/redeem?code={code}',
      'pattern': 'X[A-Z0-9]{15}',
    });
    expect(
      redeemStep(apple, code: saved.code)?.value,
      'https://apps.apple.com/redeem?code=XPRCMDHC6W6G6PCJ',
    );
    // The line as it came: no button.
    expect(
      redeemStep(apple, code: 'XPRCMDHC6W6G6PCJ / PIN: XPRCMDHC6W6G6PCJ'),
      isNull,
    );

    final withPin = CardCode.fromJson({'code': 'AAAA-BBBB / PIN: 1234'});
    expect((withPin.code, withPin.serial), ('AAAA-BBBB', '1234'));
  });
}
