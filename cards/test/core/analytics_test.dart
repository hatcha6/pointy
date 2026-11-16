import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/analytics/analytics.dart';
import 'package:pointy_cards/src/core/analytics/events.dart';
import 'package:pointy_cards/src/core/analytics/follow_customer.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/repositories/orders_repository.dart';
import 'package:pointy_cards/src/data/session/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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

  @override
  void setPersonOnce(Map<String, Object> properties) =>
      calls.add('person $properties');

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

const _customer = CustomerSession(
  sessionId: 's1',
  customerId: 'customer-1',
  phone: '218912345678',
  accessToken: 'a',
  refreshToken: 'r',
);
const _customer2 = CustomerSession(
  sessionId: 's2',
  customerId: 'customer-2',
  phone: '218912345679',
  accessToken: 'a',
  refreshToken: 'r',
);

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

  test('an answer given before sign-in reaches the customer once known, '
      'and is not the next customer\'s', () async {
    final analytics = RecordingAnalytics();
    final dependencies = fixtureDependencies(
      analytics: analytics,
      signedIn: false,
    );
    final session = dependencies.auth.session;
    followCustomer(dependencies);

    await dependencies.attribution.answer(heardFrom: 'tiktok');
    expect(analytics.calls, ['share true']);

    session.value = _customer;
    expect(analytics.calls, [
      'share true',
      'identify customer-1',
      'person {heard_from: tiktok}',
    ]);

    // The relay took it; then someone else signs in on this phone.
    dependencies.attribution.signedIn(const {
      'attribution': <String, Object>{},
    });
    session.value = null;
    session.value = _customer2;
    expect(analytics.calls.last, 'identify customer-2');
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

  test('a payment that lands after the app restarts is told, once', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final preferences = SharedPreferencesAsync();
    OrdersRepository launch(Analytics analytics) => OrdersRepository(
      api: RelayApi(
        baseUrl: Uri.parse('https://relay.preview'),
        sessions: MemorySessionStore(fixtureSession),
        client: fixtureRelay(),
      ),
      channel: 'apk',
      analytics: analytics,
      preferences: preferences,
    );
    final placed = await launch(RecordingAnalytics()).place(
      OrderRequest(
        itemKey: 'libyana-10',
        quantity: 1,
        unitPrice: Money.parse('10.000'),
        idempotencyKey: 'k1',
        method: 'dafa_moamalat',
      ),
    );
    final order = (placed as Ok<CardOrder>).value;

    // The app closes before the relay hears of the payment.
    final analytics = RecordingAnalytics();
    final relaunched = launch(analytics);
    // Orders never seen open on this phone are past telling.
    await relaunched.orders();
    expect(analytics.events, isEmpty);
    await relaunched.order(order.id);
    await relaunched.order(order.id);
    expect(analytics.events.map((e) => e.$1), [
      'order_paid',
      'order_delivered',
    ]);
  });

  test("a refused payment says Dafa's code and the relay's detail", () {
    final analytics = RecordingAnalytics();
    analytics.orderPlaceFailed(
      const RelayApiException(
        status: 502,
        code: 'gateway_rejected',
        body: {
          'code': 'gateway_rejected',
          'gateway_code': 'PROVIDER_DOWN',
          'detail': '502 PROVIDER_DOWN',
          'retryable': false,
        },
      ),
      method: 'dafa_moamalat',
    );
    expect(analytics.events.single.$1, 'order_place_failed');
    expect(analytics.events.single.$2, {
      'error_code': 'gateway_rejected',
      'method': 'dafa_moamalat',
      'gateway_code': 'PROVIDER_DOWN',
      'detail': '502 PROVIDER_DOWN',
    });
  });

  test("a payer's number in Dafa's words never reaches analytics", () {
    final analytics = RecordingAnalytics();
    analytics.orderPlaceFailed(
      const RelayApiException(
        status: 422,
        code: 'invalid_card_number',
        body: {
          'detail':
              '422 user_identifier: 6396 0412 3456 7890 is not valid, '
              'nor 0912345678',
        },
      ),
      method: 'dafa_moamalat',
    );
    expect(
      analytics.events.single.$2['detail'],
      '422 user_identifier: ••• is not valid, nor •••',
    );
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
