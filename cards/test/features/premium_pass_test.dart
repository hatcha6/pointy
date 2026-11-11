import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/arabic_search.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/repositories/auth_repository.dart';
import 'package:pointy_cards/src/data/repositories/catalog_repository.dart';
import 'package:pointy_cards/src/data/repositories/orders_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:pointy_cards/src/data/vault/code_vault.dart';
import 'package:pointy_cards/src/features/checkout/checkout_model.dart';
import 'package:pointy_cards/src/features/home/shelf_reveal.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';
import 'package:pointy_cards/src/features/shelf/shelf_model.dart';
import 'package:pointy_cards/src/features/shell/cards_shell.dart';
import 'package:pointy_cards/src/shared/skeleton.dart';

/// The bug-fixing and speed pass of 2026-11-10: what stalled, stuttered or
/// dead-ended, each pinned so it stays fixed.
void main() {
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  RelayApi apiOn(http.Client client, {SessionStore? sessions}) => RelayApi(
    baseUrl: Uri.parse('https://relay.test'),
    sessions: sessions ?? MemorySessionStore(fixtureSession),
    client: client,
  );

  group('the session', () {
    test('a refresh that cannot reach the relay is a connection problem, '
        'and the customer stays signed in', () async {
      var signedOut = false;
      final sessions = MemorySessionStore(fixtureSession);
      final api = apiOn(
        MockClient((request) async {
          if (request.url.path == '/v1/customers/auth/refresh') {
            throw http.ClientException('offline');
          }
          return json({'code': 'token_expired'}, 401);
        }),
        sessions: sessions,
      )..onSignedOut = () => signedOut = true;

      await expectLater(
        api.get('/v1/customers/me', signedIn: true),
        throwsA(
          isA<RelayApiException>().having((e) => e.isNetwork, 'network', true),
        ),
      );
      expect(signedOut, isFalse);
      expect(await sessions.read(), isNotNull);
    });

    test('signing out forgets the session at once, and still ends it on the '
        'relay when its token had run out', () async {
      final logout = Completer<http.Response>();
      final seen = <String>[];
      final sessions = MemorySessionStore(fixtureSession);
      final auth = AuthRepository(
        api: apiOn(
          MockClient((request) async {
            final bearer = request.headers['Authorization'] ?? '';
            seen.add('${request.url.path} $bearer'.trim());
            if (request.url.path == '/v1/customers/auth/refresh') {
              return json({'access_token': 'pca1.new'});
            }
            if (bearer == 'Bearer pca1.new') {
              return logout.future;
            }
            return json({'code': 'token_expired'}, 401);
          }),
          sessions: sessions,
        ),
        sessions: sessions,
      )..session.value = fixtureSession;

      await auth.signOut();
      // Gone here before the relay has answered anything.
      expect(auth.isSignedIn, isFalse);
      expect(await sessions.read(), isNull);

      logout.complete(http.Response('', 204));
      await pumpEventQueue();
      expect(seen.last, '/v1/customers/auth/logout Bearer pca1.new');
      expect(seen, contains('/v1/customers/auth/refresh'));
      // Nothing of the renewal is written back: the device stays signed out.
      expect(await sessions.read(), isNull);
    });
  });

  group('answers of the wrong shape', () {
    test('fail the call instead of leaving its page waiting', () async {
      final result = await Result.guard<int>(
        () async => (<String, dynamic>{})['esim'] as int,
      );
      expect(result, isA<Error<int>>());
    });
  });

  group('the shelf', () {
    test('asking twice while the relay answers costs one download', () async {
      var asked = 0;
      final gate = Completer<void>();
      final catalog = CatalogRepository(
        api: apiOn(
          MockClient((request) async {
            asked++;
            await gate.future;
            return json(fixtureCatalog);
          }),
        ),
        channel: 'apk',
      );
      final both = Future.wait([catalog.refresh(), catalog.refresh()]);
      gate.complete();
      final answers = await both;
      expect(asked, 1);
      expect(answers.every((answer) => answer is Ok<CardCatalog>), isTrue);
      // And it asks again afterwards.
      await catalog.refresh();
      expect(asked, 2);
    });

    test('search finds what folding every brand at each letter found, '
        'and answers the same question from memory', () async {
      final dependencies = fixtureDependencies();
      final shelf = ShelfModel(
        catalog: dependencies.catalog,
        orders: dependencies.orders,
        auth: dependencies.auth,
      );
      addTearDown(shelf.dispose);
      await shelf.load();
      final names = {for (final c in shelf.shelf.categories) c.key: c.name};
      List<String> slow(String text, {String? category}) => [
        for (final brand in shelf.shelf.brands)
          if ((category == null || brand.category == category) &&
              matchesSearch(text, [
                brand.name,
                ...brand.aliases,
                names[brand.category] ?? '',
                for (final item in brand.items) item.label,
              ]))
            brand.key,
      ]..sort();

      for (final text in ['', 'ليبيانا', 'LIBYANA', 'ببجي', '١٠', 'zzz']) {
        expect(
          [for (final brand in shelf.find(text)) brand.key]..sort(),
          slow(text),
          reason: 'searching "$text"',
        );
      }
      final category = shelf.shelf.categories.first.key;
      expect(
        [for (final b in shelf.find('', category: category)) b.key]..sort(),
        slow('', category: category),
      );
      expect(identical(shelf.find(' ليبيانا '), shelf.find('ليبيانا')), isTrue);
      // The featured come first, then the catalog's order.
      final all = shelf.find('');
      final firstPlain = all.indexWhere((brand) => !brand.featured);
      expect(
        all
            .skip(firstPlain < 0 ? all.length : firstPlain)
            .any((b) => b.featured),
        isFalse,
      );
    });

    testWidgets('a tile rising in adds no listener of its own for good', (
      tester,
    ) async {
      final reveal = ShelfReveal(tester);
      addTearDown(reveal.dispose);
      // One animation per place in the stagger, however many tiles ask.
      expect(identical(reveal.slice(3), reveal.slice(3)), isTrue);
      expect(identical(reveal.slice(40), reveal.slice(41)), isTrue);
      expect(reveal.slice(0).value, 1);
    });
  });

  group('an order on its way', () {
    CardOrder order(String status) =>
        CardOrder.fromJson(fixtureOrder(status: status, withCodes: false));

    test('is asked about once at a time, however many ask', () async {
      var asked = 0;
      final gate = Completer<void>();
      final watcher = OrderWatcher(
        orders: OrdersRepository(
          api: apiOn(
            MockClient((request) async {
              asked++;
              await gate.future;
              return json({'order': fixtureOrder(status: 'paid')});
            }),
          ),
          channel: 'apk',
        ),
        vault: MemoryCodeVault(),
        order: order('paid'),
      );
      addTearDown(watcher.dispose);
      // The clock's poll, and the app coming back to the front.
      final both = Future.wait([watcher.poll(), watcher.poll()]);
      gate.complete();
      await both;
      expect(asked, 1);
    });

    test('still arrives when the keychain will not take its codes', () async {
      final watcher = OrderWatcher(
        orders: OrdersRepository(
          api: apiOn(
            MockClient((request) async => json({'order': fixtureOrder()})),
          ),
          channel: 'apk',
        ),
        vault: _BrokenVault(),
        order: order('paid'),
      );
      addTearDown(watcher.dispose);
      var told = 0;
      watcher.addListener(() => told++);
      await watcher.poll();
      expect(watcher.order.status, OrderStatus.delivered);
      expect(told, 1);
    });

    testWidgets('a wallet order left before its code offers no card form', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dependencies = fixtureDependencies();
      final watcher = OrderWatcher(
        orders: dependencies.orders,
        vault: dependencies.vault,
        order: CardOrder.fromJson(
          fixtureOrder(status: 'awaiting_payment', nextAction: 'otp'),
        ),
      );
      addTearDown(watcher.dispose);
      await tester.pumpWidget(
        CardsApp(
          dependencies: dependencies,
          home: OrderProgressPage(watcher: watcher),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('أكمل الدفع'), findsNothing);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
      expect(find.textContaining('رمز المحفظة'), findsOneWidget);
    });
  });

  group('checkout', () {
    CardBrand brand() => CardBrand.fromJson(
      (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
    );

    test('ways to pay that failed to load can be read again', () async {
      var online = false;
      final real = fixtureRelay();
      final orders = OrdersRepository(
        api: apiOn(
          MockClient((request) async {
            if (!online) {
              throw http.ClientException('offline');
            }
            return real.get(request.url, headers: request.headers);
          }),
        ),
        channel: 'apk',
      );
      final model = CheckoutModel(
        orders: orders,
        brand: brand(),
        item: brand().items[1],
      );
      addTearDown(model.dispose);
      await model.load();
      expect(model.loadFailed, isTrue);
      expect(model.error, isNotNull);

      online = true;
      await model.load();
      expect(model.loadFailed, isFalse);
      expect(model.error, isNull);
      expect(model.method, isNotNull);
    });

    test('a payment being placed can be waited for, once', () async {
      final dependencies = fixtureDependencies();
      final model = CheckoutModel(
        orders: dependencies.orders,
        brand: brand(),
        item: brand().items[1],
      );
      await model.load();
      final first = model.pay();
      expect(model.placing, isNotNull);
      // A second tap places nothing more: it waits for the same order.
      final second = model.pay();
      final placed = await first;
      expect((await second)?.id, placed?.id);
      expect(model.placing, isNull);
      // Closing the sheet while the relay answered is quiet.
      model.dispose();
    });
  });

  group('«كروتي»', () {
    Future<void> phone(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('opens on the cards it last showed, with no placeholders', (
      tester,
    ) async {
      await phone(tester);
      await tester.pumpWidget(
        CardsApp(dependencies: fixtureDependencies(), home: const CardsShell()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('كروتي').last);
      await tester.pumpAndSettle();
      expect(find.byType(Skeleton), findsNothing);

      await tester.tap(find.text('الرئيسية').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('كروتي').last);
      // The very first frame of the second visit.
      await tester.pump();
      expect(find.byType(Skeleton), findsNothing);
      expect(find.text('ليبيانا · 10 دينار'), findsWidgets);
      await tester.pumpAndSettle();
    });

    testWidgets('signing out forgets them', (tester) async {
      await phone(tester);
      final dependencies = fixtureDependencies();
      await tester.pumpWidget(
        CardsApp(
          dependencies: dependencies,
          home: const CardsShell(initialTab: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(dependencies.myCards.last, isNotNull);
      expect(dependencies.orders.lastOrders, isNotNull);

      await dependencies.auth.signOut();
      await tester.pumpAndSettle();
      expect(dependencies.myCards.last, isNull);
      expect(dependencies.orders.lastOrders, isNull);
      expect(find.text('ليبيانا · 10 دينار'), findsNothing);
    });
  });
}

class _BrokenVault extends MemoryCodeVault {
  @override
  Future<void> keep(String orderId, List<CardCode> codes) =>
      throw StateError('the keychain is locked');
}
