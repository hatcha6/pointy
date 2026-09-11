import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/card_payment_receipt.dart';

import '../../support/moamalat_receipt_links.dart';

const madfoatechUrl =
    'https://rms.lpco.ly/RCP/Dwl/'
    '3TpaRjLQrIEpQDwXn_xq5gvRIzWBkNILTcgbQwg6730K4WxIF-JZLQ==';

void main() {
  const matcher = CardReceiptMatcher();

  group('recognising a Madfoatech link', () {
    test('the till knows one on sight, without a network', () {
      expect(matcher.isReceiptLink(madfoatechUrl), isTrue);
    });

    test('a product barcode is still not a receipt', () {
      expect(matcher.isReceiptLink('6224000123456'), isFalse);
      expect(
        matcher.isReceiptLink('https://example.com/RCP/Dwl/abc'),
        isFalse,
      );
    });

    test('plain http is refused even on the right host', () {
      expect(matcher.isReceiptLink('http://rms.lpco.ly/RCP/Dwl/abc'), isFalse);
    });

    test('both providers are recognised by the one matcher', () {
      expect(matcher.isReceiptLink(moamalatReceiptUrl(amount: 8.5)), isTrue);
      expect(matcher.isReceiptLink(madfoatechUrl), isTrue);
    });
  });

  group('what a till may claim about one', () {
    test('it is attached but proves nothing yet', () {
      final receipt = matcher.verify(madfoatechUrl, trustedTerminalIds: const []);

      expect(receipt.provider, CardReceiptProvider.madfoatech);
      expect(receipt.isPending, isTrue);
      expect(receipt.canProveAmount, isFalse);
      expect(receipt.sourceUrl, madfoatechUrl);
    });

    test('an unknown amount never counts as a match', () {
      final receipt = matcher.verify(madfoatechUrl, trustedTerminalIds: const []);

      // "Unknown" must not quietly behave like "fine": that is how an
      // unchecked slip comes to stand for a payment it never covered.
      expect(receipt.amountMatches(8.5), isFalse);
      expect(receipt.amountMatches(0), isFalse);
    });

    test('it attaches to a card line without an amount check', () {
      // The backend runs the real check once the issuer answers. Refusing here
      // would reject every genuine Madfoatech slip.
      final receipt = matcher.match(
        madfoatechUrl,
        expectedAmount: 8.5,
        trustedTerminalIds: const ['0ZWTOF8E'],
      );

      expect(receipt.isPending, isTrue);
    });

    test('a link carrying no token is refused', () {
      expect(
        () => matcher.verify(
          'https://rms.lpco.ly/RCP/Dwl/',
          trustedTerminalIds: const [],
        ),
        throwsA(isA<CardPaymentReceiptException>()),
      );
    });
  });

  group('Moamalat is unaffected', () {
    test('its amount check still refuses the wrong amount', () {
      expect(
        () => matcher.match(
          moamalatReceiptUrl(amount: 8.5),
          expectedAmount: 3,
          trustedTerminalIds: const [],
        ),
        throwsA(
          isA<CardPaymentReceiptException>().having(
            (CardPaymentReceiptException exception) => exception.code,
            'code',
            CardPaymentReceiptErrorCode.amountMismatch,
          ),
        ),
      );
    });

    test('its terminal check still refuses a foreign terminal', () {
      expect(
        () => matcher.match(
          moamalatReceiptUrl(amount: 8.5, terminalId: 'FOREIGN1'),
          expectedAmount: 8.5,
          trustedTerminalIds: const ['0JA8Y13W'],
        ),
        throwsA(
          isA<CardPaymentReceiptException>().having(
            (CardPaymentReceiptException exception) => exception.code,
            'code',
            CardPaymentReceiptErrorCode.terminalNotTrusted,
          ),
        ),
      );
    });

    test('a decoded receipt still proves its own amount', () {
      final receipt = matcher.match(
        moamalatReceiptUrl(amount: 8.5),
        expectedAmount: 8.5,
        trustedTerminalIds: const [],
      );

      expect(receipt.isPending, isFalse);
      expect(receipt.canProveAmount, isTrue);
      expect(receipt.amount, 8.5);
    });
  });
}
