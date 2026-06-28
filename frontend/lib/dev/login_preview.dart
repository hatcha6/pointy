// Dev-only preview harness for the login screen.
//
// Renders the login screen full-viewport with a non-loading AuthViewModel
// (no backend/auth), so the brand logo and layout can be checked in both the
// wide two-pane and compact single-column forms. Resize the browser to switch.
// Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/login_preview.dart
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/auth/view_models/auth_view_model.dart';
import 'package:pointy_frontend/src/features/auth/views/login_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    // autoLoad: false keeps the view model from hitting the network; the
    // screen only reads isSubmitting/hasError for this preview.
    final viewModel = AuthViewModel(
      AuthRepository(PosApiService()),
      autoLoad: false,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: LoginScreen(viewModel: viewModel),
    );
  }
}
