import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/vault/code_vault.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';

void main() {
  test('clearing saved codes leaves the sign-in in the keychain', () async {
    FlutterSecureStorage.setMockInitialValues({
      'cards.session.v1': '{"session_id":"s"}',
      'cards.codes.v1.order-1': '[{"code":"1"}]',
      'cards.used.v1': '["1"]',
    });
    const storage = FlutterSecureStorage();
    await SecureCodeVault(storage).clear();
    expect(await storage.readAll(), {'cards.session.v1': '{"session_id":"s"}'});
  });

  testWidgets(
    'the account reads credit once, not on every layout change; a browser is named in Arabic',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final counting = _CountingClient(fixtureRelay());
      await tester.pumpWidget(
        CardsApp(dependencies: fixtureDependencies(client: counting)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('حسابي'));
      await tester.pumpAndSettle();
      expect(find.text('متصفح'), findsOneWidget);
      // The shelf's read and the account's one.
      final afterOpen = counting.creditReads;

      tester.view.physicalSize = const Size(430 * 3, 932 * 3);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(844 * 3, 390 * 3);
      await tester.pumpAndSettle();
      expect(counting.creditReads, afterOpen);
    },
  );

  testWidgets(
    'a payment held for review says so, never "nothing was charged"',
    (tester) async {
      final dependencies = fixtureDependencies();
      final watcher = OrderWatcher(
        orders: dependencies.orders,
        vault: dependencies.vault,
        order: CardOrder.fromJson(
          fixtureOrder(status: 'failed', errorCode: 'payment_mismatch'),
        ),
      );
      addTearDown(watcher.dispose);
      await tester.pumpWidget(
        CardsApp(
          dependencies: dependencies,
          home: OrderProgressPage(watcher: watcher, openPaymentPage: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('نراجع دفعتك'), findsOneWidget);
      expect(find.text('لم يكتمل الدفع'), findsNothing);
    },
  );
}

/// Counts credit reads and passes every request on.
class _CountingClient extends http.BaseClient {
  _CountingClient(this.inner);

  final http.Client inner;
  int creditReads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path == '/v1/customers/credit') {
      creditReads++;
    }
    return inner.send(request);
  }
}
