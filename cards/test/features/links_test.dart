import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/account/account_page.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/legal/legal_page.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/links/link_inbox.dart';

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<LinkInbox> openApp(WidgetTester tester, [String? address]) async {
  await phone(tester);
  final links = LinkInbox(
    initial: address == null ? null : CardsLink.parse(Uri.parse(address)),
  );
  await tester.pumpWidget(
    CardsApp(dependencies: fixtureDependencies(links: links)),
  );
  await tester.pumpAndSettle();
  return links;
}

/// What the platform sends when a cards.dftr.ly link is tapped while the
/// app runs.
Future<void> tapLink(WidgetTester tester, String address) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    SystemChannels.navigation.codec.encodeMethodCall(
      MethodCall('pushRouteInformation', {'location': address}),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> goBack(WidgetTester tester) async {
  await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  await tester.pumpAndSettle();
}

void main() {
  group('addresses', () {
    test('each place reads from and writes back to its address', () {
      const places = <String, CardsLink>{
        '/': ShelfLink(),
        '/category/gaming': ShelfLink(category: 'gaming'),
        '/brand/pubg': BrandLink('pubg'),
        '/brand/pubg?item=pubg-325': BrandLink('pubg', item: 'pubg-325'),
        '/my-cards': TabLink(CardsTab.myCards),
        '/account': TabLink(CardsTab.account),
        '/privacy': PageLink(LinkedPage.privacy),
        '/terms': PageLink(LinkedPage.terms),
        '/about': PageLink(LinkedPage.about),
      };
      for (final MapEntry(key: address, value: link) in places.entries) {
        expect(CardsLink.parse(Uri.parse(address)), link, reason: address);
        expect(link.location, address);
      }
      final search = CardsLink.parse(Uri.parse('/search?q=ببجي'));
      expect(search, const ShelfLink(query: 'ببجي'));
      expect(CardsLink.parse(Uri.parse(search.location)), search);
    });

    test(
      'the full link, an ad\'s extras and a trailing slash read the same',
      () {
        expect(
          CardsLink.parse(
            Uri.parse('https://cards.dftr.ly/brand/pubg/?utm_source=fb&x=1'),
          ),
          const BrandLink('pubg'),
        );
        expect(
          const BrandLink('pubg').uri.toString(),
          'https://cards.dftr.ly/brand/pubg',
        );
      },
    );

    test('an unknown or incomplete address opens the shelf', () {
      for (final address in ['/nope', '/brand', '/category/', '/search?q=']) {
        expect(
          CardsLink.parse(Uri.parse(address)),
          const ShelfLink(),
          reason: address,
        );
      }
    });

    test('the same link reported twice as the app comes up opens once', () {
      var now = DateTime(2026, 10, 26, 12);
      final inbox = LinkInbox(clock: () => now);
      var opened = 0;
      inbox.addListener(() => opened++);
      inbox.open(Uri.parse('/brand/pubg'));
      inbox.take();
      inbox.open(Uri.parse('https://cards.dftr.ly/brand/pubg'));
      expect(opened, 1);
      now = now.add(const Duration(seconds: 5));
      inbox.open(Uri.parse('/brand/pubg'));
      expect(opened, 2);
    });

    test('nor does the link the app started on, reported again', () {
      final inbox = LinkInbox(initial: const BrandLink('pubg'));
      inbox.take();
      var opened = 0;
      inbox.addListener(() => opened++);
      inbox.open(Uri.parse('https://cards.dftr.ly/brand/pubg'));
      expect(opened, 0);
      inbox.open(Uri.parse('/category/gaming'));
      expect(opened, 1);
    });
  });

  testWidgets('started on a brand link: its page, on the card it names', (
    tester,
  ) async {
    await openApp(tester, 'https://cards.dftr.ly/brand/pubg?item=pubg-325');
    final page = tester.widget<BrandPage>(find.byType(BrandPage));
    expect(page.brand.key, 'pubg');
    expect(page.initialItem?.key, 'pubg-325');
    // Back is the shelf.
    await goBack(tester);
    expect(find.byType(BrandPage), findsNothing);
    expect(find.text('ليبيانا'), findsWidgets);
  });

  testWidgets('a category link filters; an unknown category does not', (
    tester,
  ) async {
    await openApp(tester, '/category/gaming');
    expect(find.text('ببجي موبايل'), findsWidgets);
    expect(find.text('المدار'), findsNothing);

    // Tapped while the shelf is showing: it moves there.
    await tapLink(tester, '/category/telecom');
    expect(find.text('المدار'), findsWidgets);
    expect(find.text('ببجي موبايل'), findsNothing);

    await tapLink(tester, '/category/no-such-thing');
    expect(find.text('المدار'), findsWidgets);
  });

  testWidgets('a search link fills the search', (tester) async {
    await openApp(tester, '/search?q=netflix');
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, 'netflix');
    expect(find.text('المدار'), findsNothing);
  });

  testWidgets('a search link tapped while the app runs fills the search', (
    tester,
  ) async {
    await openApp(tester);
    await tapLink(tester, 'https://cards.dftr.ly/search?q=netflix');
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, 'netflix');
  });

  testWidgets('a link tapped while the app runs closes what is open first', (
    tester,
  ) async {
    await openApp(tester);
    await tapLink(tester, 'https://cards.dftr.ly/brand/libyana');
    expect(
      tester.widget<BrandPage>(find.byType(BrandPage)).brand.key,
      'libyana',
    );

    await tapLink(tester, 'https://cards.dftr.ly/privacy');
    expect(find.byType(BrandPage), findsNothing);
    expect(find.byType(LegalPage), findsOneWidget);

    // Back from it is the account tab, where the legal pages live.
    await goBack(tester);
    expect(find.byType(AccountPage), findsOneWidget);
  });

  testWidgets('a brand no longer sold opens the shelf', (tester) async {
    await openApp(tester, '/brand/gone');
    expect(find.byType(BrandPage), findsNothing);
    expect(find.text('ليبيانا'), findsWidgets);
  });
}
