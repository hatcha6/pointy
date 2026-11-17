import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/vault/code_vault.dart';
import 'package:pointy_cards/src/data/vault/orders_vault.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:pointy_cards/src/features/shell/cards_shell.dart';

/// Bought cards with no network: the list, and each card's code.
void main() {
  final offline = MockClient((_) async => throw http.ClientException('off'));

  /// A launch with a network: the cards are listed once.
  Future<(OrdersVault, CodeVault)> listedOnce() async {
    final orders = MemoryOrdersVault();
    final codes = MemoryCodeVault();
    final online = fixtureDependencies(ordersVault: orders, codeVault: codes);
    expect(await online.orders.orders(), isA<Ok<Object?>>());
    // The codes are read behind the listing.
    for (
      var i = 0;
      i < 50 &&
          (await codes.codes('order-1') == null ||
              await codes.codes('order-4') == null);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return (orders, codes);
  }

  test('a listing keeps the orders, and the codes of delivered cards never '
      'opened here; the list holds no code', () async {
    final (orders, codes) = await listedOnce();
    final kept = jsonDecode((await orders.read())!) as Map<String, dynamic>;
    expect(kept['owner'], fixtureSession.customerId);
    expect(kept['orders'], isNotEmpty);
    final held = await codes.codes('order-1');
    expect(held, isNotEmpty);
    expect(await orders.read(), isNot(contains(held!.first.code)));
    // An order still on its way has no code to keep.
    expect(await codes.codes('order-2'), isNull);
  });

  test('kept orders are their owner\'s alone', () async {
    final (orders, _) = await listedOnce();
    final kept = jsonDecode((await orders.read())!) as Map<String, dynamic>;
    await orders.write(jsonEncode({...kept, 'owner': 'someone-else'}));
    final next = fixtureDependencies(client: offline, ordersVault: orders);
    expect(await next.orders.keptOrders(), isEmpty);
  });

  testWidgets('«كروتي» lists the cards this phone holds with no network, and '
      'a card shows its code', (tester) async {
    final (orders, codes) =
        await tester.runAsync(listedOnce) as (OrdersVault, CodeVault);
    final serial = (await codes.codes('order-4'))!.first.serial;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(
          client: offline,
          ordersVault: orders,
          codeVault: codes,
        ),
        home: const CardsShell(initialTab: 1),
      ),
    );
    // (No catalog either here, so the card art shimmers on: no settling.)
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byKey(const ValueKey('failed')), findsNothing);
    expect(find.text('لا يوجد اتصال بالإنترنت'), findsOneWidget);
    final row = find.textContaining('المدار');
    expect(row, findsWidgets);

    await tester.ensureVisible(row.first);
    await tester.tap(row.first);
    // (No catalog either here, so the card art shimmers on: no settling.)
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(RevealPage), findsOneWidget);
    // The card is up from what this phone holds (its code lies under the
    // card's foil until it is scratched).
    expect(find.textContaining(serial), findsWidgets);
  });
}
