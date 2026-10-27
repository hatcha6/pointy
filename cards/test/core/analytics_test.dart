import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/analytics/analytics.dart';
import 'package:pointy_cards/src/core/analytics/follow_customer.dart';

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
}
