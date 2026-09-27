import 'package:flutter/widgets.dart';

import '../view_models/auth_view_model.dart';

/// Brings the sign-in page forward when a session ends under pushed screens.
///
/// The sign-in page is the app's first route — AuthGate swaps what that route
/// shows — while every section and detail screen is pushed on top of it. So a
/// session that ends without the logout button (a password changed from the
/// users screen, an account disabled elsewhere, the server signing this
/// device out) swapped the page nobody could see and left the pushed screens
/// standing: field telemetry, 2026-09-26, an owner on the users screen whose
/// every tap answered 401 for half a minute until they found logout. Popping
/// to the first route shows the sign-in page they now need.
class SignedOutRouteReset {
  SignedOutRouteReset({
    required Listenable authChanges,
    required AuthStatus Function() status,
    required GlobalKey<NavigatorState> navigatorKey,
  }) : _authChanges = authChanges,
       _status = status,
       _navigatorKey = navigatorKey;

  final Listenable _authChanges;
  final AuthStatus Function() _status;
  final GlobalKey<NavigatorState> _navigatorKey;

  /// The last status that was an answer rather than a question: a re-check
  /// (`checking`) that ends signed in again is not a sign-out.
  AuthStatus? _lastSettled;

  void attach() => _authChanges.addListener(_onAuthChanged);

  void detach() => _authChanges.removeListener(_onAuthChanged);

  void _onAuthChanged() {
    final status = _status();
    if (status == AuthStatus.checking) {
      return;
    }
    final signedOut =
        _lastSettled == AuthStatus.authenticated &&
        status != AuthStatus.authenticated;
    _lastSettled = status;
    if (!signedOut) {
      return;
    }
    // After the frame: never pop during the build or the notification that
    // announced the change (the logout-recursion lesson). The logout button
    // already pops the same way, so doing it again is a no-op. A post-frame
    // callback does not ask for a frame, so ask — otherwise the pop waits for
    // whatever happens to repaint next.
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
    binding.scheduleFrame();
  }
}
