import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/auth/view_models/auth_view_model.dart';
import 'package:pointy_frontend/src/features/auth/views/signed_out_route_reset.dart';

/// A session that ends under pushed screens must not leave them standing.
/// Field telemetry, 2026-09-26: an owner reset their own password from the
/// users screen; the app swapped the (hidden) first route to sign-in and left
/// the users screens on top, where every tap answered 401.
class _Auth extends ChangeNotifier {
  AuthStatus status = AuthStatus.authenticated;

  void set(AuthStatus next) {
    status = next;
    notifyListeners();
  }
}

Future<(_Auth, SignedOutRouteReset)> _pumpWithPushedScreen(
  WidgetTester tester,
) async {
  final auth = _Auth();
  final navigatorKey = GlobalKey<NavigatorState>();
  final reset = SignedOutRouteReset(
    authChanges: auth,
    status: () => auth.status,
    navigatorKey: navigatorKey,
  )..attach();
  addTearDown(reset.detach);
  // The reset learns the settled status from its first notification.
  auth.set(AuthStatus.authenticated);

  await tester.pumpWidget(
    MaterialApp(navigatorKey: navigatorKey, home: const Text('first route')),
  );
  navigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const Text('users screen')),
  );
  await tester.pumpAndSettle();
  expect(find.text('users screen'), findsOneWidget);
  return (auth, reset);
}

void main() {
  testWidgets('a session that ends pops back to the sign-in route', (
    tester,
  ) async {
    final (auth, _) = await _pumpWithPushedScreen(tester);

    auth.set(AuthStatus.unauthenticated);
    await tester.pumpAndSettle();

    expect(find.text('users screen'), findsNothing);
    expect(find.text('first route'), findsOneWidget);
  });

  testWidgets('a re-check that ends signed in again leaves the screen alone', (
    tester,
  ) async {
    final (auth, _) = await _pumpWithPushedScreen(tester);

    auth.set(AuthStatus.checking);
    await tester.pumpAndSettle();
    auth.set(AuthStatus.authenticated);
    await tester.pumpAndSettle();

    expect(find.text('users screen'), findsOneWidget);
  });

  testWidgets('signing in pops nothing', (tester) async {
    final (auth, _) = await _pumpWithPushedScreen(tester);
    auth.set(AuthStatus.unauthenticated);
    await tester.pumpAndSettle();

    auth.set(AuthStatus.authenticated);
    await tester.pumpAndSettle();

    expect(find.text('first route'), findsOneWidget);
  });
}
