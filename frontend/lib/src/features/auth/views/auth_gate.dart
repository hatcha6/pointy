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
            child: _AuthCheckingScreen(),
          ),
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

class _AuthCheckingScreen extends StatelessWidget {
  const _AuthCheckingScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyScaffold(
      body: PointyLoadingArea(label: l10n.authCheckingSession),
    );
  }
}
