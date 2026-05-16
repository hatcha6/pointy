import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../view_models/auth_view_model.dart';
import 'login_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.viewModel,
    required this.authenticatedBuilder,
  });

  final AuthViewModel viewModel;
  final WidgetBuilder authenticatedBuilder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return switch (viewModel.status) {
          AuthStatus.checking => const _AuthCheckingScreen(),
          AuthStatus.unauthenticated => LoginScreen(viewModel: viewModel),
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

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.authCheckingSession),
            ],
          ),
        ),
      ),
    );
  }
}
