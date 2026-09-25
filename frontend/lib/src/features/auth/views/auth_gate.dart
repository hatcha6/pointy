import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../shared/components/components.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/auth_view_model.dart';
import 'initial_admin_setup_screen.dart';
import 'login_screen.dart';
import '../../../core/analytics_screen_tracker.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.viewModel,
    required this.authenticatedBuilder,
    this.analyticsEngine,
    this.onEnterPriceCheckerMode,
  });

  final AuthViewModel viewModel;
  final WidgetBuilder authenticatedBuilder;
  final AnalyticsEngine? analyticsEngine;

  /// Forwarded to [LoginScreen] to offer a price-checker (kiosk) entry without
  /// signing in.
  final Future<void> Function(BuildContext context)? onEnterPriceCheckerMode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final status = viewModel.status;
        // Wrapped per branch, not set inline: this builder runs on every auth
        // notification, and setting the screen here overwrote whatever the user
        // was actually on with 'authenticated'.
        //
        // The authenticated branch is deliberately not wrapped. It is a state,
        // not a screen, and the shell inside it names its own — a second
        // tracker on this same route would just fire a duplicate view event
        // every time the user came back to it.
        return switch (status) {
          AuthStatus.checking => const TrackedScreen(
            name: 'auth_checking',
            child: AuthCheckingScreen(),
          ),
          // Signed in with nobody signed in: only ever a passing state, but
          // one the signed-in shell cannot be built for. It used to be handed
          // back to another gate, which saw the same state and did the same —
          // a loop that overflowed the stack on a double-tapped logout.
          AuthStatus.authenticated when viewModel.currentUser == null =>
            const AuthCheckingScreen(),
          AuthStatus.setupRequired => TrackedScreen(
            name: 'onboarding',
            child: InitialAdminSetupScreen(viewModel: viewModel),
          ),
          AuthStatus.unauthenticated => TrackedScreen(
            name: 'login',
            child: LoginScreen(
              viewModel: viewModel,
              onEnterPriceCheckerMode: onEnterPriceCheckerMode,
            ),
          ),
          AuthStatus.authenticated => authenticatedBuilder(context),
        };
      },
    );
  }
}

/// The wait while the app works out who is signed in.
class AuthCheckingScreen extends StatelessWidget {
  const AuthCheckingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyScaffold(
      body: PointyLoadingArea(label: l10n.authCheckingSession),
    );
  }
}
