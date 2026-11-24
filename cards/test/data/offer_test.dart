import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/models/offer.dart';

void main() {
  CardOffer offer(Map<String, dynamic> fields) => CardOffer.fromJson({
    'id': 'o',
    'title': 't',
    'kind': 'percent',
    'value': '15',
    'max_discount': '0',
    'min_order': '0',
    'uses_left': 1,
    ...fields,
  });

  test('works the discount out as the relay does', () {
    final capped = offer({'max_discount': '5', 'min_order': '20'});
    expect(capped.discountOn(Money.parse('10')), Money.zero);
    expect(capped.discountOn(Money.parse('20')), Money.parse('3'));
    expect(capped.discountOn(Money.parse('30')), Money.parse('4.5'));
    expect(capped.discountOn(Money.parse('100')), Money.parse('5'));
    // Down to the dirham, as the relay rounds.
    expect(
      offer({'value': '33.335'}).discountOn(Money.parse('10')),
      Money.parse('3.333'),
    );
    final amount = offer({'kind': 'amount', 'value': '7'});
    expect(amount.discountOn(Money.parse('5')), Money.parse('5'));
    expect(amount.discountOn(Money.parse('50')), Money.parse('7'));
  });

  test('the best offer is the one that takes the most off', () {
    final small = offer({'id': 'small', 'kind': 'amount', 'value': '2'});
    final big = offer({'id': 'big', 'value': '10'});
    expect(CardOffer.bestFor([small, big], Money.parse('10'))?.id, 'small');
    expect(CardOffer.bestFor([small, big], Money.parse('50'))?.id, 'big');
    expect(CardOffer.bestFor(const [], Money.parse('50')), isNull);
  });
}
