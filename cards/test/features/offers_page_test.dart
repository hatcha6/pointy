import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/links/link_inbox.dart';
import 'package:pointy_cards/src/features/offers/offer_coupon.dart';
import 'package:pointy_cards/src/features/offers/offers_entry.dart';
import 'package:pointy_cards/src/features/offers/offers_page.dart';
import 'package:pointy_cards/src/shared/pressable.dart';

import 'links_test.dart' show goBack, phone, tapLink;

Future<void> openWithOffers(
  WidgetTester tester, {
  List<Map<String, dynamic>> offers = fixtureOffers,
  String? address,
  bool signedIn = true,
}) async {
  await phone(tester);
  final links = LinkInbox(
    initial: address == null ? null : CardsLink.parse(Uri.parse(address)),
  );
  await tester.pumpWidget(
    CardsApp(
      dependencies: fixtureDependencies(
        links: links,
        offers: offers,
        signedIn: signedIn,
      ),
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
      of: find.byType(OfferCoupon),
      matching: find.byType(Pressable),
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

  testWidgets('signed out: the offers for everyone, and a way to sign in', (
    tester,
  ) async {
    await openWithOffers(tester, signedIn: false, address: '/offers');
    expect(find.byType(OffersPage), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('اشترِ كرتين واحصل على الثالث مجاناً'), findsOneWidget);
  });

  // The smallest phone at the largest text, and the iPhone Duo closed and
  // open on its side: nothing overflows, in the app's own font (the test
  // font's square letters overflow where Arabic does not).
  setUpAll(() async {
    final font = FontLoader('packages/pointy_brand/IBMPlexSansArabic');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(
        rootBundle.load(
          'packages/pointy_brand/assets/fonts/IBMPlexSansArabic-$weight.ttf',
        ),
      );
    }
    await font.load();
  });
  for (final (size, text) in const [
    (Size(320, 568), 2.0),
    (Size(466, 678), 1.0),
    (Size(951, 669), 1.0),
  ]) {
    testWidgets('fits ${size.width.toInt()}x${size.height.toInt()} '
        'at text x$text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = text;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(
            links: LinkInbox(initial: const OffersLink()),
            offers: fixtureOffers,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OffersPage), findsOneWidget);
      // Down the whole page.
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
