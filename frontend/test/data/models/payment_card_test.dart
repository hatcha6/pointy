import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/payment_card.dart';

void main() {
  test('payment card page parses redacted card fields', () {
    final page = PaymentCardPage.fromJson({
      'next': null,
      'results': [
        {
          'id': 5,
          'customer': 12,
          'customer_name': 'Card •••• 8809',
          'masked_pan': '639974*********8809',
          'card_scheme': 'NUMO BANK1',
          'aid': 'A0000009021010',
          'label': '',
          'display_name': '639974*********8809',
          'is_active': true,
          'first_seen_at': '2026-06-21T10:00:00Z',
          'last_seen_at': '2026-06-21T12:30:00Z',
        },
      ],
    });

    expect(page.hasMore, isFalse);
    expect(page.cards, hasLength(1));
    final card = page.cards.single;
    expect(card.customer, 12);
    expect(card.maskedPan, '639974*********8809');
    expect(card.cardScheme, 'NUMO BANK1');
    expect(card.displayName, '639974*********8809');
    expect(card.lastSeenAt, isNotNull);
  });

  test('customer parses placeholder flag and card count', () {
    final placeholder = Customer.fromJson({
      'id': 12,
      'full_name': 'Card •••• 8809',
      'is_auto_created': true,
      'card_count': 1,
    });
    final real = Customer.fromJson({'id': 13, 'full_name': 'Layla Ahmed'});

    expect(placeholder.isAutoCreated, isTrue);
    expect(placeholder.cardCount, 1);
    // Round-trips the placeholder flag through local persistence.
    expect(Customer.fromJson(placeholder.toJson()).isAutoCreated, isTrue);
    expect(real.isAutoCreated, isFalse);
    expect(real.cardCount, 0);
  });
}
