import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/l10n/generated/app_localizations.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/models/offer.dart';
import 'package:pointy_cards/src/features/offers/offer_text.dart';

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
  })!;
  OfferLine line(
    String unit,
    int quantity, {
    String category = '',
    String brand = '',
    String item = '',
  }) => OfferLine(
    unitPrice: Money.parse(unit),
    quantity: quantity,
    category: category,
    brand: brand,
    item: item,
  );

  test('works the discount out as the relay does, for every kind', () {
    final capped = offer({'max_discount': '5', 'min_order': '20'});
    expect(capped.discountOn(line('10', 1)), Money.zero);
    expect(capped.discountOn(line('20', 1)), Money.parse('3'));
    expect(capped.discountOn(line('100', 1)), Money.parse('5'));
    expect(
      offer({'value': '33.335'}).discountOn(line('10', 1)),
      Money.parse('3.333'),
    );
    expect(
      offer({'kind': 'amount', 'value': '7'}).discountOn(line('5', 1)),
      Money.parse('5'),
    );

    final tiered = offer({
      'kind': 'tiered',
      'tier_unit': 'percent',
      'max_discount': '12',
      'tiers': [
        {'min_order': '20', 'value': '5'},
        {'min_order': '50', 'value': '10'},
        {'min_order': '100', 'value': '15'},
      ],
    });
    expect(tiered.discountOn(line('10', 1)), Money.zero);
    expect(tiered.discountOn(line('49', 1)), Money.parse('2.45'));
    expect(tiered.discountOn(line('50', 1)), Money.parse('5'));
    expect(tiered.discountOn(line('100', 1)), Money.parse('12'));

    final bogo = offer({
      'kind': 'bundle',
      'buy_quantity': 2,
      'get_quantity': 1,
      'get_percent': '100',
    });
    expect(bogo.discountOn(line('10', 2)), Money.zero);
    expect(bogo.discountOn(line('10', 3)), Money.parse('10'));
    expect(bogo.discountOn(line('10', 6)), Money.parse('20'));
    final half = offer({
      'kind': 'bundle',
      'buy_quantity': 1,
      'get_quantity': 1,
      'get_percent': '50',
      'max_discount': '6',
    });
    expect(half.discountOn(line('10', 4)), Money.parse('6'));

    expect(CardOffer.fromJson({'id': 'x', 'kind': 'mystery'}), isNull);
  });

  test('keeps to its scope', () {
    final scoped = offer({
      'scope': {
        'categories': ['gaming'],
        'brands': ['libyana'],
        'items': ['apple-us-10'],
      },
    });
    expect(
      scoped.discountOn(line('10', 1, category: 'gaming', brand: 'pubg')),
      Money.parse('1.5'),
    );
    expect(
      scoped.discountOn(line('10', 1, category: 'telecom', brand: 'libyana')),
      Money.parse('1.5'),
    );
    expect(
      scoped.discountOn(
        line(
          '10',
          1,
          category: 'gift_cards',
          brand: 'apple',
          item: 'apple-us-10',
        ),
      ),
      Money.parse('1.5'),
    );
    expect(
      scoped.discountOn(
        line(
          '10',
          1,
          category: 'gift_cards',
          brand: 'apple',
          item: 'apple-us-25',
        ),
      ),
      Money.zero,
    );
  });

  testWidgets('every kind has its badge and its nudge in Arabic', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('ar'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    final offers = {
      for (final raw in fixtureOffers) raw['id']: CardOffer.fromJson(raw)!,
    };
    String badge(String id) => offerBadgeText(l10n, offers[id]!);
    expect(badge('offer-percent'), 'خصم 15٪');
    expect(badge('offer-amount'), contains('خصم'));
    expect(badge('offer-tiered'), 'خصم حتى 15٪');
    expect(badge('offer-bundle'), 'اشترِ 2 واحصل على 1 مجاناً');
    expect(badge('offer-esim'), 'eSIM أرخص');

    // Two Almadar cards: one more makes one free.
    final bundle = offerNudge(
      l10n,
      offers['offer-bundle']!,
      line('10', 2, brand: 'almadar'),
    );
    expect(bundle?.kind, 'bundle');
    expect(bundle?.text, contains('1'));
    // 30 dinars of gift cards: 20 more reaches 10%.
    final tier = offerNudge(
      l10n,
      offers['offer-tiered']!,
      line('30', 1, category: 'gift_cards'),
    );
    expect(tier?.kind, 'tier');
    expect(tier?.text, contains('10٪'));
    // Above the top tier, and out of scope: no nudge.
    expect(
      offerNudge(
        l10n,
        offers['offer-tiered']!,
        line('120', 1, category: 'gift_cards'),
      ),
      isNull,
    );
    expect(
      offerNudge(
        l10n,
        offers['offer-tiered']!,
        line('30', 1, category: 'gaming'),
      ),
      isNull,
    );
    // Below a minimum: the minimum.
    expect(
      offerNudge(
        l10n,
        offers['offer-amount']!,
        line('10', 1, category: 'gaming'),
      )?.kind,
      'minimum',
    );
  });
}
