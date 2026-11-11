import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/l10n/generated/app_localizations.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/esim/esim_device.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/esim.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/repositories/esim_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:pointy_cards/src/design/cards_theme.dart';
import 'package:pointy_cards/src/design/cards_tokens.dart';
import 'package:pointy_cards/src/dependencies.dart';
import 'package:pointy_cards/src/features/esim/esim_checkout.dart';
import 'package:pointy_cards/src/features/esim/esim_destination_page.dart';
import 'package:pointy_cards/src/features/esim/esim_format.dart';
import 'package:pointy_cards/src/features/esim/esim_page.dart';
import 'package:pointy_cards/src/features/esim/esim_page_mode.dart';
import 'package:pointy_cards/src/features/esim/esim_plan_sheet.dart';
import 'package:pointy_cards/src/features/esim/esim_search.dart';
import 'package:pointy_cards/src/features/esim/esim_split.dart';
import 'package:pointy_cards/src/features/esim/esim_store_page.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/shared/cards_scope.dart';
import 'package:pointy_cards/src/shared/esim_card_art.dart';

/// A phone that says what the test wants, and records what it was asked to do.
class _FakeDevice extends EsimDevice {
  _FakeDevice(this.answer, {this.opens = true});

  final EsimDeviceFacts answer;
  final bool opens;
  final installed = <String>[];

  @override
  Future<EsimDeviceFacts> facts() async => answer;

  @override
  Future<bool> install(String url) async {
    installed.add(url);
    return opens;
  }
}

EsimDeviceFacts _phone({
  String platform = 'ios',
  bool supports = true,
  bool direct = true,
  bool simulator = false,
  String? model,
}) => EsimDeviceFacts(
  platform: platform,
  model: model ?? (platform == 'ios' ? 'iPhone13,2' : 'SM-S921B'),
  osVersion: '18.0',
  supportsEsim: supports,
  simulator: simulator,
  directInstall: direct,
);

const _listed = EsimModelCheck(supported: true, listed: true, name: 'iPhone');
const _offList = EsimModelCheck(supported: false, listed: false, name: '');

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required CardsDependencies dependencies,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 1600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CardsScope(
      dependencies: dependencies,
      child: MaterialApp(
        locale: const Locale('ar'),
        theme: CardsTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

CardsDependencies _dependencies(_FakeDevice device) {
  final base = fixtureDependencies(esim: true);
  return base..esimCompatibilityForTest(device);
}

extension on CardsDependencies {
  void esimCompatibilityForTest(EsimDevice device) {
    overrideEsimCompatibility(
      EsimCompatibility(repository: esim, device: device),
    );
  }
}

void main() {
  group('does this phone take eSIMs', () {
    test('the phone saying yes is enough', () {
      expect(esimSupportOf(_phone(), null), EsimSupport.yes);
      expect(
        esimSupportOf(_phone(platform: 'android'), _offList),
        EsimSupport.yes,
      );
    });

    test('an iPhone the list knows counts over its own hint', () {
      expect(esimSupportOf(_phone(supports: false), _listed), EsimSupport.yes);
    });

    test('an Android phone with eSIM switched off is not called capable', () {
      expect(
        esimSupportOf(_phone(platform: 'android', supports: false), _listed),
        EsimSupport.unknown,
      );
    });

    test('an iPhone is judged by its model, never by its own no', () {
      // An iPhone 16 Pro: the system says no to an app with no carrier
      // entitlement, and Airalo's list does not know "iPhone17,1".
      final pro = _phone(supports: false, model: 'iPhone17,1');
      expect(esimSupportOf(pro, _offList), EsimSupport.yes);
      expect(esimSupportOf(pro, null), EsimSupport.yes);
      expect(
        esimSupportOf(_phone(supports: false, model: 'iPhone11,8'), _offList),
        EsimSupport.yes,
      );
      // An iPhone X has none.
      expect(
        esimSupportOf(_phone(supports: false, model: 'iPhone10,3'), _listed),
        EsimSupport.no,
      );
    });

    test('a model off the list is no verdict on an iPad', () {
      final ipad = _phone(supports: false, model: 'iPad13,1');
      expect(esimSupportOf(ipad, _offList), EsimSupport.unknown);
      expect(esimSupportOf(ipad, _listed), EsimSupport.yes);
      expect(esimSupportOf(ipad, null), EsimSupport.unknown);
    });

    test('an Android phone with no eSIM service, off the list, is warned', () {
      final android = _phone(platform: 'android', supports: false);
      expect(esimSupportOf(android, _offList), EsimSupport.no);
      expect(esimSupportOf(android, null), EsimSupport.unknown);
    });

    testWidgets('an iPhone 16 Pro is never told it takes no eSIM', (
      tester,
    ) async {
      // The fixture relay answers "not on the list", as Airalo does.
      final dependencies = _dependencies(
        _FakeDevice(_phone(supports: false, model: 'iPhone17,1')),
      );
      await tester.runAsync(dependencies.esimCompatibility.load);
      expect(dependencies.esimCompatibility.support.value, EsimSupport.yes);
    });

    test('a build with no phone cannot tell', () {
      expect(
        esimSupportOf(EsimDeviceFacts.none, _offList),
        EsimSupport.unknown,
      );
      expect(
        esimSupportOf(_phone(simulator: true), _offList),
        EsimSupport.unknown,
      );
    });
  });

  group('order items and links', () {
    test('an order knows it is an eSIM, and which one a top-up is for', () {
      expect(EsimItems.isEsim('esim:turkey-1gb'), isTrue);
      expect(EsimItems.isEsim('esim-topup:89:turkey-topup'), isTrue);
      expect(EsimItems.isEsim('libyana-10'), isFalse);
      expect(EsimItems.topUpIccid('esim-topup:89:turkey-topup'), '89');
      expect(EsimItems.topUpIccid('esim:turkey-1gb'), isNull);
    });

    test('a low-data alert opens the eSIM, the shelf has its addresses', () {
      expect(
        CardsLink.parse(Uri.parse('https://cards.dftr.ly/esims/8944')),
        const EsimLink('8944'),
      );
      expect(
        CardsLink.parse(Uri.parse('https://cards.dftr.ly/esim')),
        const EsimShelfLink(),
      );
      expect(
        CardsLink.parse(Uri.parse('https://cards.dftr.ly/esim/turkey')),
        const EsimShelfLink(destination: 'turkey'),
      );
      expect(const EsimLink('8944').location, '/esims/8944');
      expect(
        const EsimShelfLink(destination: 'turkey').location,
        '/esim/turkey',
      );
    });
  });

  group('search', () {
    final shelf = EsimShelf.fromJson(fixtureEsimShelf);
    List<String> names(String query) => [
      for (final row in esimSearch(shelf, query)) row.name,
    ];

    test('finds a place by its Arabic name, its slug and its code', () {
      expect(names('تركيا'), ['تركيا']);
      expect(names('turkey'), ['تركيا']);
      expect(names('TR'), contains('تركيا'));
    });

    test('the words for an eSIM bring the popular places', () {
      expect(names('شريحة'), containsAll(['تركيا', 'مصر']));
      expect(names('esim'), isNotEmpty);
    });

    test('nothing for anything else, or while eSIMs are not on sale', () {
      expect(names('ببجي'), isEmpty);
      expect(esimSearch(EsimShelf.closed, 'تركيا'), isEmpty);
      expect(esimSearch(shelf, '  '), isEmpty);
    });
  });

  group('usage', () {
    final now = DateTime.utc(2026, 11, 5);
    EsimUsage usage(String status, int left, {int days = 20}) => EsimUsage(
      status: EsimStatus.parse(status),
      remainingMb: left,
      totalMb: 1000,
      expiresAt: now.add(Duration(days: days)),
    );

    test('running out is a quarter left, three days left, or over', () {
      expect(usage('ACTIVE', 500).runningOut(now), isFalse);
      expect(usage('ACTIVE', 250).runningOut(now), isTrue);
      expect(usage('ACTIVE', 500, days: 3).runningOut(now), isTrue);
      expect(usage('FINISHED', 0).runningOut(now), isTrue);
      // Not installed yet: nothing is running out, whatever the numbers say.
      expect(usage('NOT_ACTIVE', 0).runningOut(now), isFalse);
    });

    test('an unlimited plan has no share to show', () {
      const unlimited = EsimUsage(
        status: EsimStatus.active,
        remainingMb: 0,
        totalMb: 0,
      );
      expect(unlimited.left, isNull);
    });

    test('data reads the way it is sold', () {
      expect(formatEsimData(512), '512 MB');
      expect(formatEsimData(1024), '1 GB');
      expect(formatEsimData(1536), '1.5 GB');
    });
  });

  group('screens', () {
    testWidgets('the shelf lists destinations, and says the phone is fine', (
      tester,
    ) async {
      final dependencies = _dependencies(_FakeDevice(_phone()));
      await _pump(tester, const EsimStorePage(), dependencies: dependencies);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.esimPhoneSupported), findsOneWidget);
      expect(find.text('تركيا'), findsWidgets);
      expect(find.text('أوروبا'), findsNothing);
      await tester.tap(find.text(l10n.esimKindRegional));
      await tester.pumpAndSettle();
      expect(find.text('أوروبا'), findsOneWidget);
    });

    testWidgets('filters narrow the shelf to a trip and show its price', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await _pump(
        tester,
        const EsimStorePage(filter: EsimShelfFilter(minDays: 30, minMb: 5120)),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      // Tunisia has no month of 5 GB; Turkey's is its 10 GB plan.
      expect(find.text('تونس'), findsNothing);
      expect(find.text(l10n.esimResultsCount(3)), findsOneWidget);
      expect(find.textContaining('156.00'), findsOneWidget);
      expect(find.text(l10n.esimPopular), findsNothing);
      await tester.tap(find.text(l10n.esimFilterClear));
      await tester.pumpAndSettle();
      expect(find.text('تونس'), findsWidgets);
      expect(find.text(l10n.esimOffersTitle), findsOneWidget);

      // Only what is on offer.
      await tester.tap(find.text(l10n.esimFilterOffers));
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimResultsCount(1)), findsOneWidget);
      expect(find.text('مصر'), findsNothing);
    });

    testWidgets('a search finds a region by a country in it', (tester) async {
      await _pump(
        tester,
        const EsimStorePage(filter: EsimShelfFilter(query: 'فرنسا')),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      expect(find.text('أوروبا'), findsOneWidget);
      expect(find.text('تركيا'), findsNothing);
    });

    testWidgets('a promotion shows on a plan, and a link opens the plan', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await _pump(
        tester,
        const EsimDestinationPage(
          destination: 'turkey',
          plan: 'merhaba-30days-3gb',
        ),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      expect(find.text(l10n.esimPromoOff(20)), findsWidgets);
      // The linked plan's sheet is open, at the promotion's price.
      expect(find.text(l10n.esimWhoFor), findsOneWidget);
      expect(find.textContaining('66.00'), findsWidgets);
      expect(find.textContaining('82.50'), findsWidgets);
    });

    test('eSIM links name a destination, a plan and a filtered shelf', () {
      CardsLink at(String path) =>
          CardsLink.parse(Uri.parse('https://cards.dftr.ly$path'));
      final plan = at('/esim/turkey/ea.PTR1G7') as EsimShelfLink;
      expect(plan.destination, 'turkey');
      expect(plan.plan, 'ea.PTR1G7');
      expect(plan.location, '/esim/turkey/ea.PTR1G7');
      final shelf = at(
        '/esim?days=30&gb=5&offers=1&kind=regional&sort=cheapest',
      ) as EsimShelfLink;
      expect(shelf.destination, isNull);
      expect(
        (shelf.days, shelf.gb, shelf.offers, shelf.kind, shelf.cheapest),
        (30, 5, true, 'regional', true),
      );
      expect(CardsLink.parse(Uri.parse(shelf.location)), shelf);
      expect(at('/esim').location, '/esim');
      expect(at('/esim/turkey').location, '/esim/turkey');
    });

    testWidgets('search finds eSIMs on the home page and the search page', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await tester.binding.setSurfaceSize(const Size(430, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        CardsApp(dependencies: fixtureDependencies(esim: true)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'تركيا');
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimSearchSection), findsOneWidget);
      expect(find.text(l10n.esimSearchTag), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a phone that cannot take one is warned, not stopped', (
      tester,
    ) async {
      final dependencies = _dependencies(_FakeDevice(_phone(supports: false)));
      final destination = EsimDestination.fromJson(fixtureEsimDestination);
      await _pump(
        tester,
        Scaffold(
          body: EsimPlanSheet(
            destination: destination,
            plan: destination.plans.first,
          ),
        ),
        dependencies: dependencies,
      );
      // The relay's answer for this fixture says the model is fine: force a no.
      dependencies.esimCompatibility.support.value = EsimSupport.no;
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      // It starts on «لشخص آخر», with the name field, and the button stays on.
      expect(find.text(l10n.esimRecipientName), findsOneWidget);
      await tester.tap(find.text(l10n.esimForMe));
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimForMeUnsupportedNote), findsOneWidget);
      final buy = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(buy.onPressed, isNotNull);
    });

    testWidgets('one tap installs on a phone that can', (tester) async {
      final device = _FakeDevice(_phone());
      final dependencies = _dependencies(device);
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000001', justBought: true),
        dependencies: dependencies,
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.esimReadyTitle), findsOneWidget);
      await tester.tap(find.text(l10n.esimInstallAction));
      await tester.pump();
      expect(
        device.installed.single,
        startsWith('https://esimsetup.apple.com/'),
      );
      // Back from the system's sheet, the page asks how it went.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimInstallAskTitle), findsOneWidget);
      await tester.tap(find.text(l10n.esimInstallAskYes));
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimNextStepsTitle), findsOneWidget);
    });

    testWidgets('Android gets its own link; a link nothing opens falls back', (
      tester,
    ) async {
      final device = _FakeDevice(_phone(platform: 'android'), opens: false);
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000001'),
        dependencies: _dependencies(device),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await tester.tap(find.text(l10n.esimInstallAction));
      await tester.pumpAndSettle();
      expect(
        device.installed.single,
        startsWith('https://esimsetup.android.com/'),
      );
      expect(find.text(l10n.esimInstallFailedNote), findsOneWidget);
      expect(find.text(l10n.esimManualTitle), findsOneWidget);
    });

    testWidgets('an old system goes straight to the QR', (tester) async {
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000001'),
        dependencies: _dependencies(_FakeDevice(_phone(direct: false))),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.esimInstallAction), findsNothing);
      expect(find.text(l10n.esimQrTitle), findsOneWidget);
      expect(find.text('ABC123'), findsOneWidget);
    });

    testWidgets('a gift has one button, naming who it goes to', (tester) async {
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000003'),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final send = l10n.esimSendToName('أمي');
      expect(
        find.ancestor(
          of: find.text(send).last,
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.esimGiftTo), findsOneWidget);
      expect(find.text(l10n.esimInstallHere), findsOneWidget);
      expect(find.text(l10n.esimInstallAction), findsNothing);
    });

    testWidgets('running low, the one button tops up', (tester) async {
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000002'),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      expect(find.text(l10n.esimTopUpNow), findsOneWidget);
      await tester.tap(find.text(l10n.esimTopUpNow));
      await tester.pumpAndSettle();
      expect(find.text(l10n.esimTopUpTitle), findsOneWidget);
    });

    testWidgets('in use shows what is left; over offers another', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      await _pump(
        tester,
        const EsimPage(iccid: '8900000000000000004'),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      expect(find.text(l10n.esimTopUpAction), findsOneWidget);
      await _pump(
        tester,
        const EsimPage(key: ValueKey('over'), iccid: '8900000000000000005'),
        dependencies: _dependencies(_FakeDevice(_phone())),
      );
      expect(find.text(l10n.esimBuyAnother), findsOneWidget);
    });
  });

  group('page mode', () {
    final now = DateTime.utc(2026, 11, 6);
    CustomerEsim esim({
      String status = 'NOT_ACTIVE',
      int left = 1000,
      bool gift = false,
    }) => CustomerEsim.fromJson({
      'iccid': '1',
      'gift': gift,
      'usage': {'status': status, 'remaining_mb': left, 'total_mb': 1000},
    });
    EsimPageMode mode(
      CustomerEsim e, {
      bool confirmed = false,
      EsimSupport support = EsimSupport.yes,
    }) => esimPageMode(
      esim: e,
      confirmedInstalled: confirmed,
      support: support,
      now: now,
    );

    test('"active" alone is not installed: the button stays', () {
      expect(mode(esim(status: 'ACTIVE')), EsimPageMode.install);
      expect(mode(esim(status: 'ACTIVE', gift: true)), EsimPageMode.send);
    });

    test('the customer\'s word, or data used, means installed', () {
      expect(
        mode(esim(status: 'ACTIVE'), confirmed: true),
        EsimPageMode.active,
      );
      expect(mode(esim(status: 'ACTIVE', left: 900)), EsimPageMode.active);
      expect(
        mode(esim(status: 'ACTIVE', gift: true, left: 900)),
        EsimPageMode.active,
      );
    });

    test('a phone that looks unable is offered sending first', () {
      expect(mode(esim(), support: EsimSupport.no), EsimPageMode.send);
    });

    test('low and over win', () {
      expect(mode(esim(status: 'ACTIVE', left: 100)), EsimPageMode.low);
      expect(mode(esim(status: 'FINISHED', left: 0)), EsimPageMode.low);
      expect(mode(esim(status: 'EXPIRED')), EsimPageMode.ended);
    });
  });

  test('every popular destination has its flag baked in', () {
    for (final code in ['tr', 'eg', 'tn', 'sa', 'ae', 'it', 'de', 'gb', 'ly']) {
      expect(File('assets/flags/$code.svg').existsSync(), isTrue, reason: code);
    }
  });

  testWidgets('an unknown code and a region fall back to the globe', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            EsimFlag(country: 'TR'),
            EsimFlag(country: 'ZZ'),
            EsimFlag(country: ''),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('an eSIM order wears its flag', () {
    final order = CardOrder.fromJson({
      ...fixtureOrder(id: 'o', status: 'delivered', item: 'esim:t'),
      'brand': 'esim:TR',
      'name': 'تركيا · 1 GB · 7 أيام',
    });
    final brand = esimBrandOfOrder(order);
    expect(brand.flagCountry, 'TR');
    expect(brand.name, 'تركيا');
    expect(brand.category, esimCategory);
  });

  test('a delivered order is read as an eSIM with no codes', () {
    final order = CardOrder.fromJson(
      fixtureOrder(id: 'o', status: 'delivered', item: 'esim:turkey-1gb'),
    );
    expect(order.isEsim, isTrue);
  });

  test(
    'an order\'s eSIM is asked for by a real query, not in the path',
    () async {
      late Uri asked;
      final repository = EsimRepository(
        api: RelayApi(
          baseUrl: Uri.parse('https://relay.test'),
          sessions: MemorySessionStore(fixtureSession),
          client: MockClient((request) async {
            asked = request.url;
            return http.Response(
              jsonEncode({'esims': <Object>[]}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      await repository.esimOfOrder('o 1');
      expect(asked.path, '/v1/customers/esims');
      expect(asked.queryParameters['order'], 'o 1');
    },
  );

  test('the repository reads the relay\'s shelf and device answers', () async {
    final api = RelayApi(
      baseUrl: Uri.parse('https://relay.test'),
      sessions: MemorySessionStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device')) {
          return http.Response(
            jsonEncode({'known': false}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(fixtureEsimShelf)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final repository = EsimRepository(api: api);
    await repository.loadShelf();
    expect(repository.shelf.value.available, isTrue);
    expect(await repository.checkModel('iPhone13,2'), isNull);
  });

  group('the iPhone Duo', () {
    const column = 88.0;
    const closed = Size(466, 678);
    const openOnItsSide = Size(951, 669);

    Future<void> pumpOn(WidgetTester tester, Size size, Widget home) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: const EdgeInsets.only(right: column),
          ),
          child: CardsScope(
            dependencies: _dependencies(_FakeDevice(_phone())),
            child: MaterialApp(
              locale: const Locale('ar'),
              theme: CardsTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: home,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('closed, the main button fills the page beside the column', (
      tester,
    ) async {
      await pumpOn(
        tester,
        closed,
        const EsimPage(iccid: '8900000000000000001'),
      );
      final button = tester.getRect(find.byType(FilledButton));
      expect(button.left, CardsSpace.gutter);
      expect(button.right, closed.width - column - CardsSpace.gutter);
    });

    testWidgets('closed, a destination fills the page beside the column', (
      tester,
    ) async {
      await pumpOn(
        tester,
        closed,
        const EsimDestinationPage(destination: 'turkey', name: 'تركيا'),
      );
      final hero = tester.getRect(find.byType(EsimHero));
      expect(hero.left, CardsSpace.gutter);
      expect(hero.right, closed.width - column - CardsSpace.gutter);
    });

    testWidgets('renaming stands in the column, not in the page', (
      tester,
    ) async {
      await pumpOn(
        tester,
        closed,
        const EsimPage(iccid: '8900000000000000001'),
      );
      final pencil = tester.getCenter(find.byIcon(Icons.edit_outlined).first);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(pencil.dx, greaterThan(closed.width - column));
    });

    testWidgets('open on its side, the card and its action stand beside the '
        'details', (tester) async {
      await pumpOn(
        tester,
        openOnItsSide,
        const EsimPage(iccid: '8900000000000000001'),
      );
      expect(find.byType(EsimSplit), findsOneWidget);
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final button = tester.getRect(find.byType(FilledButton));
      final title = tester.getRect(find.text(l10n.esimOneStepTitle));
      // Arabic: the card leads on the right, the details read on its left.
      expect(button.left, greaterThan(title.right));
      expect(button.right, lessThan(openOnItsSide.width - column));
    });
  });
}
