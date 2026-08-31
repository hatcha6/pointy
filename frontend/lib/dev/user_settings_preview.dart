// Dev-only preview harness for the account settings screen (profile, password,
// loans).
//
// Renders it full-viewport against in-memory fakes (no backend). Pick the
// scenario with a `?screen=` query param and resize the browser to test
// responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/user_settings_preview.dart
//
// Scenarios: default | strict (a deployment that raised the enforced floor)
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the shipping
// app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/password_policy.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/user_settings/view_models/user_settings_view_model.dart';
import 'package:pointy_frontend/src/features/user_settings/views/user_settings_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

const _user = PosUser(
  id: 1,
  username: 'hatem',
  firstName: 'حاتم',
  lastName: 'الشريف',
  email: 'hatem@example.test',
  role: UserRole.manager,
  isActive: true,
);

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
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
      home: UserSettingsScreen(
        viewModel: UserSettingsViewModel(
          _FakeAuthRepository(_screen()),
          _FakeEmployeeRepository(),
        ),
        currentUser: _user,
        onUserChanged: (_) {},
        navigation: _FakeNavigation(),
      ),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'default';
}

class _FakeNavigation implements AppNavigation {
  @override
  final AuthorizationCapabilities capabilities =
      AuthorizationCapabilities.forUser(_user);

  @override
  final PosUser currentUser = _user;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository(this.scenario) : super(PosApiService());

  final String scenario;

  @override
  Future<Result<PasswordPolicy>> loadPasswordPolicy() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    // "strict" mirrors a deployment that raised POINTY_PASSWORD_MIN_LENGTH: the
    // floor moves up and the length suggestion disappears from the advice.
    return Ok(
      scenario == 'strict'
          ? const PasswordPolicy(
              required: [PasswordRequirement.minLength],
              advisory: [
                PasswordAdvice.notNumeric,
                PasswordAdvice.notCommon,
                PasswordAdvice.notSimilarToUser,
              ],
              minLength: 10,
              recommendedMinLength: 8,
            )
          : PasswordPolicy.fallback,
    );
  }

  @override
  Future<Result<void>> changePassword(PasswordChangeDraft draft) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const Ok(null);
  }
}

class _FakeEmployeeRepository extends EmployeeRepository {
  _FakeEmployeeRepository() : super(PosApiService());

  @override
  Future<Result<MyEmployeeLoans>> loadMyEmployeeLoans() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return const Ok(MyEmployeeLoans(employee: null, loans: []));
  }
}
