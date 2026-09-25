import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/auth/view_models/auth_view_model.dart';
import 'package:pointy_frontend/src/features/auth/views/auth_gate.dart';

void main() {
  testWidgets('signed in with nobody signed in waits instead of building the '
      'shell', (tester) async {
    // The state a double-tapped logout used to reach. The gate handed it to
    // its authenticated builder, which handed it to another gate, which did
    // the same — until the stack overflowed and the till restarted.
    final viewModel = _SignedInWithoutUser();
    addTearDown(viewModel.dispose);
    var shellBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: AuthGate(
          viewModel: viewModel,
          authenticatedBuilder: (_) {
            shellBuilds++;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(AuthCheckingScreen), findsOneWidget);
    expect(shellBuilds, 0);
  });
}

class _SignedInWithoutUser extends AuthViewModel {
  _SignedInWithoutUser()
    : super(AuthRepository(PosApiService()), autoLoad: false);

  @override
  AuthStatus get status => AuthStatus.authenticated;

  @override
  PosUser? get currentUser => null;
}
