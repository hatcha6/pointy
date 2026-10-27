import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/analytics/analytics.dart';
import 'package:pointy_cards/src/core/analytics/follow_customer.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/repositories/orders_repository.dart';

/// Writes down what the app tells analytics.
class RecordingAnalytics extends NoAnalytics {
  final calls = <String>[];

  @override
  late final NavigatorObserver observer = _Names(calls);

  @override
  void screen(String name) => calls.add('screen $name');

  @override
  void identify(String customerId) => calls.add('identify $customerId');

  @override
  void reset() => calls.add('reset');

  @override
  void share(bool on) => calls.add('share $on');

  final events = <(String, Map<String, Object>)>[];

  @override
  void capture(String event, [Map<String, Object> properties = const {}]) =>
      events.add((event, properties));
}

/// The pages' names as the PostHog observer reads them.
class _Names extends NavigatorObserver {
  _Names(this.calls);

  final List<String> calls;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.arguments case ScreenName(:final name)) {
      calls.add('page $name');
    }
  }
}

void main() {
  test('a sign-in joins the customer; a sign-out, and only that, '
      'starts over', () {
    final analytics = RecordingAnalytics();
    final dependencies = fixtureDependencies(analytics: analytics);
    final session = dependencies.auth.session;
    final signedIn = session.value!;
    followCustomer(dependencies);
    expect(analytics.calls, ['share true', 'identify ${signedIn.customerId}']);
    session.value = null;
    session.value = signedIn;
    expect(analytics.calls, [
      'share true',
      'identify ${signedIn.customerId}',
      'reset',
      'identify ${signedIn.customerId}',
    ]);
  });

  test('a launch signed out is one visitor, not a new one', () {
    final analytics = RecordingAnalytics();
    followCustomer(fixtureDependencies(analytics: analytics, signedIn: false));
    expect(analytics.calls, ['share true']);
  });

  testWidgets('the tabs and the pages say their names', (tester) async {
    final analytics = RecordingAnalytics();
    await tester.pumpWidget(
      CardsApp(dependencies: fixtureDependencies(analytics: analytics)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('كروتي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ليبيانا · 10 دينار').first);
    await tester.pumpAndSettle();
    expect(analytics.calls, ['screen shelf', 'screen my_cards', 'page card']);
    await tester.pumpWidget(const SizedBox());
  });

  test('a purchase tells its story once: placed, paid, delivered', () async {
    final analytics = RecordingAnalytics();
    final orders = fixtureDependencies(analytics: analytics).orders;
    final placed = await orders.place(
      OrderRequest(
        itemKey: 'libyana-10',
        quantity: 1,
        unitPrice: Money.parse('10.000'),
        idempotencyKey: 'k1',
        method: 'dafa_sadad',
        payerIdentifier: '0912345678',
        birthYear: '1990',
      ),
    );
    final order = (placed as Ok<CardOrder>).value;
    await orders.confirm(order.id, '123456');
    // Asked about again: nothing new to tell.
    await orders.order(order.id);
    expect(analytics.events.map((e) => e.$1), [
      'order_placed',
      'order_paid',
      'order_delivered',
    ]);
    final paid = analytics.events[1].$2;
    expect(paid['revenue'], 10.0);
    expect(paid['currency'], 'LYD');
    expect(paid['method'], 'dafa_sadad');
    expect(paid.containsKey('codes'), isFalse);
  });

  test('turning sharing off stops it; on starts it again', () {
    final analytics = RecordingAnalytics();
    final dependencies = fixtureDependencies(analytics: analytics);
    followCustomer(dependencies);
    analytics.calls.clear();
    dependencies.settings
      ..setShareUsage(false)
      ..setShareUsage(true);
    expect(analytics.calls, ['share false', 'share true']);
  });
}
