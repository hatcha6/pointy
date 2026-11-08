import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/push/in_app_notices.dart';
import 'package:pointy_cards/src/core/push/push.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// A relay whose order is paid and still waiting for its card.
http.Client waitingRelay() => MockClient((request) async {
  if (request.method == 'GET' &&
      request.url.path == '/v1/customers/orders/order-1') {
    return http.Response(
      jsonEncode({
        'order': fixtureOrder(status: 'fulfilling', withCodes: false)
          ..['codes_pending'] = true,
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return http.Response('{"error":"not here"}', 404);
});

void main() {
  test('an order on screen keeps its own message quiet', () {
    final push = Push();
    var front = true;
    final stop = push.watch('order-1', () => front);
    push.arrived(const PushNotice(title: 't', body: 'b', order: 'order-1'));
    expect(push.notice.value, isNull);
    // Covered by another page: it is not on screen any more.
    front = false;
    push.arrived(const PushNotice(title: 't', body: 'b', order: 'order-1'));
    expect(push.notice.value?.order, 'order-1');
    push.notice.value = null;
    front = true;
    stop();
    push.arrived(const PushNotice(title: 't', body: 'b', order: 'order-1'));
    expect(push.notice.value?.order, 'order-1');
  });

  testWidgets('a message while the app is open drops in along the top', (
    tester,
  ) async {
    await phone(tester);
    final push = FixturePush();
    var opened = 0;
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(push: push),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    push.arrived(
      PushNotice(
        title: 'رمز بطاقتك جاهز',
        body: 'ليبيانا · 10 دينار: اضغط لعرض الرمز.',
        order: 'order-9',
        onOpen: () => opened++,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('رمز بطاقتك جاهز'), findsOneWidget);
    await tester.tap(find.text('رمز بطاقتك جاهز'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('رمز بطاقتك جاهز'), findsNothing);

    // Left alone, it goes by itself.
    push.arrived(const PushNotice(title: 'عرض', body: 'خصم ليبيانا'));
    await tester.pumpAndSettle();
    expect(find.text('عرض'), findsOneWidget);
    await tester.pump(InAppNotices.shownFor);
    await tester.pumpAndSettle();
    expect(find.text('عرض'), findsNothing);
  });

  testWidgets('an order paid minutes ago opens already late', (tester) async {
    await phone(tester);
    final dependencies = fixtureDependencies(client: waitingRelay());
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: CardOrder.fromJson(
        fixtureOrder(status: 'fulfilling', withCodes: false)
          ..['paid_at'] = DateTime.now()
              .subtract(const Duration(minutes: 4))
              .toIso8601String(),
      ),
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: OrderProgressPage(watcher: watcher),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('يتأخر المورّد هذه المرة'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    watcher.dispose();
  });

  testWidgets('a late card says the customer need not wait for it here', (
    tester,
  ) async {
    await phone(tester);
    final push = FixturePush();
    final dependencies = fixtureDependencies(
      client: waitingRelay(),
      push: push,
    );
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: CardOrder.fromJson(
        fixtureOrder(status: 'fulfilling', withCodes: false),
      ),
    )..start();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: OrderProgressPage(watcher: watcher),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('نجهّز كرتك…'), findsOneWidget);
    // On screen: its own notification would stay quiet.
    expect(push.showing('order-1'), isTrue);

    await tester.pump(OrderProgressPage.slowAfter);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('يتأخر المورّد هذه المرة'), findsOneWidget);
    expect(
      find.text(
        'فعّل الإشعارات ونخبرك حين يجهز طلبك، أو عُد إليه لاحقاً في «كروتي».',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('تفعيل الإشعارات'));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text(
        'لا داعي للانتظار هنا: حين يجهز طلبك نرسل لك إشعاراً يفتحه مباشرةً في «كروتي».',
      ),
      findsOneWidget,
    );
    expect(find.text('تفعيل الإشعارات'), findsNothing);

    await tester.tap(find.text('اذهب إلى «كروتي»'));
    await tester.pump();
    expect(dependencies.links.pending, const TabLink(CardsTab.myCards));

    await tester.pumpWidget(const SizedBox());
    watcher.dispose();
    expect(push.showing('order-1'), isFalse);
  });

  testWidgets("the waiting page waits as long as the relay says", (
    tester,
  ) async {
    await phone(tester);
    final dependencies = fixtureDependencies(
      client: waitingRelay(),
      push: FixturePush(),
    );
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: CardOrder.fromJson({
        ...fixtureOrder(status: 'fulfilling', withCodes: false),
        'wait_seconds': 30,
      }),
    )..start();
    expect(watcher.order.wait, const Duration(seconds: 30));
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: OrderProgressPage(watcher: watcher),
      ),
    );
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('يتأخر المورّد هذه المرة'), findsNothing);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('يتأخر المورّد هذه المرة'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    watcher.dispose();
  });
}
