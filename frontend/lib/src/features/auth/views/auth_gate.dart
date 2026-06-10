import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../shared/components/components.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/auth_view_model.dart';
import 'initial_admin_setup_screen.dart';
import 'login_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.viewModel,
    required this.authenticatedBuilder,
    this.analyticsEngine,
  });

  final AuthViewModel viewModel;
  final WidgetBuilder authenticatedBuilder;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final status = viewModel.status;
        analyticsEngine?.setCurrentScreen(_screenName(status));
        return switch (status) {
          AuthStatus.checking => const _AuthCheckingScreen(),
          AuthStatus.setupRequired => InitialAdminSetupScreen(
            viewModel: viewModel,
          ),
          AuthStatus.unauthenticated => LoginScreen(viewModel: viewModel),
          AuthStatus.authenticated => authenticatedBuilder(context),
        };
      },
    );
  }

  String _screenName(AuthStatus status) {
    return switch (status) {
      AuthStatus.checking => 'auth_checking',
      AuthStatus.setupRequired => 'onboarding',
      AuthStatus.unauthenticated => 'login',
      AuthStatus.authenticated => 'authenticated',
    };
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
