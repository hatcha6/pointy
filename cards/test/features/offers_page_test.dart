import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/home/brand_tile.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/links/link_inbox.dart';
import 'package:pointy_cards/src/features/offers/offers_entry.dart';
import 'package:pointy_cards/src/features/offers/offers_page.dart';

import 'links_test.dart' show goBack, phone, tapLink;

Future<void> openWithOffers(
  WidgetTester tester, {
  List<Map<String, dynamic>> offers = fixtureOffers,
  String? address,
}) async {
  await phone(tester);
  final links = LinkInbox(
    initial: address == null ? null : CardsLink.parse(Uri.parse(address)),
  );
  await tester.pumpWidget(
    CardsApp(
      dependencies: fixtureDependencies(links: links, offers: offers),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('/offers is the offers page', () {
    expect(CardsLink.parse(Uri.parse('/offers')), const OffersLink());
    expect(const OffersLink().location, '/offers');
  });

  testWidgets('an offer notification opens the offers, each with its cards', (
    tester,
  ) async {
    await openWithOffers(tester);
    await tapLink(tester, 'https://cards.dftr.ly/offers');
    expect(find.byType(OffersPage), findsOneWidget);
    // The first offer (15% on LNET) shows its card, which opens its page.
    expect(find.text('خصم 15٪ على باقات ليبيا للاتصالات'), findsOneWidget);
    final tile = find.descendant(
      of: find.byType(OffersPage),
      matching: find.byType(BrandTile),
    );
    expect(tile, findsWidgets);
    await tester.tap(tile.first);
    await tester.pumpAndSettle();
    expect(find.byType(BrandPage), findsOneWidget);
    await goBack(tester);
    await goBack(tester);
    expect(find.byType(OffersPage), findsNothing);
  });

  testWidgets('the shelf leads to the offers when there are some', (
    tester,
  ) async {
    await openWithOffers(tester);
    expect(find.byType(OffersEntry), findsOneWidget);
    await tester.ensureVisible(find.byType(OffersEntry));
    await tester.pumpAndSettle();
    await tester.tap(find.text('لديك 6 عروض'));
    await tester.pumpAndSettle();
    expect(find.byType(OffersPage), findsOneWidget);
  });

  testWidgets('no offers: no way in on the shelf, and an empty page', (
    tester,
  ) async {
    await openWithOffers(tester, offers: const [], address: '/offers');
    expect(find.text('لا عروض الآن'), findsOneWidget);
    await goBack(tester);
    expect(find.text('لديك 6 عروض'), findsNothing);
  });
}
