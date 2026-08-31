import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/password_policy.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/auth_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/user_settings/view_models/user_settings_view_model.dart';
import 'package:pointy_frontend/src/features/user_settings/views/user_settings_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../shared/fake_app_navigation.dart';

const _user = PosUser(
  id: 1,
  username: 'hatem',
  role: UserRole.manager,
  isActive: true,
);

void main() {
  testWidgets('the rules are stated before anything is typed', (tester) async {
    final viewModel = _viewModel();
    await _pump(tester, viewModel);

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    // The complaint this fixes: the form demanded things it never named.
    expect(find.text(l10n.passwordRulesTitle), findsOneWidget);
    expect(find.text(l10n.passwordRuleMinLength(4)), findsOneWidget);
    expect(find.text(l10n.passwordAdviceTitle), findsOneWidget);
    expect(find.text(l10n.passwordAdviceNotNumeric), findsOneWidget);
    expect(find.text(l10n.passwordAdviceNote), findsOneWidget);
  });

  testWidgets('a four-digit PIN can be submitted', (tester) async {
    final viewModel = _viewModel();
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await _fillPasswords(tester, l10n, current: 'old-pass', next: '1234');

    // Advice unmet, requirements met — the save must go through.
    expect(viewModel.passwordAssessment.meetsRequirements, isTrue);
    expect(
      viewModel.passwordAssessment.advice[PasswordAdvice.notNumeric],
      PasswordRuleState.failed,
    );
    expect(_changeButton(tester, l10n).onPressed, isNotNull);
  });

  testWidgets('an empty confirmation leaves the button disabled', (
    tester,
  ) async {
    // An enabled button that only paints "required" when pressed is a lie about
    // what pressing it will do.
    final viewModel = _viewModel();
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await tester.enterText(
      _fieldByLabel(l10n.currentPasswordLabel),
      'old-pass',
    );
    await tester.enterText(_fieldByLabel(l10n.newPasswordLabel), '1234');
    await tester.pumpAndSettle();

    expect(_changeButton(tester, l10n).onPressed, isNull);
  });

  testWidgets('below the floor the button stays disabled', (tester) async {
    final viewModel = _viewModel();
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await _fillPasswords(tester, l10n, current: 'old-pass', next: '12');

    expect(_changeButton(tester, l10n).onPressed, isNull);
  });

  testWidgets('a mismatched confirmation is reported as it is typed', (
    tester,
  ) async {
    final viewModel = _viewModel();
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await _fillPasswords(
      tester,
      l10n,
      current: 'old-pass',
      next: '1234',
      confirmation: '9999',
    );

    expect(find.text(l10n.passwordConfirmationMismatch), findsOneWidget);
    expect(_changeButton(tester, l10n).onPressed, isNull);
  });

  testWidgets('a wrong current password says so, not "check the rules"', (
    tester,
  ) async {
    final repo = _FakeAuthRepo(
      changeResult: Error(
        _apiError(
          400,
          '{"current_password": ["Current password is incorrect."]}',
        ),
      ),
    );
    final viewModel = _viewModel(auth: repo);
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await _fillPasswords(
      tester,
      l10n,
      current: 'wrong',
      next: 'a-good-password',
    );
    expect(_changeButton(tester, l10n).onPressed, isNotNull);
    // The section sits below the fold at the default test surface size.
    await tester.ensureVisible(find.text(l10n.changePasswordButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.changePasswordButton));
    await tester.pumpAndSettle();

    expect(
      viewModel.passwordFailure,
      PasswordChangeFailure.currentPasswordWrong,
    );
    expect(find.text(l10n.passwordCurrentIncorrectError), findsOneWidget);
  });

  testWidgets('a throttle says wait rather than wrong', (tester) async {
    final repo = _FakeAuthRepo(
      changeResult: Error(
        _apiError(429, '{"detail": "Request was throttled."}'),
      ),
    );
    final viewModel = _viewModel(auth: repo);
    await _pump(tester, viewModel);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    await _fillPasswords(
      tester,
      l10n,
      current: 'old-pass',
      next: 'a-good-password',
    );
    expect(_changeButton(tester, l10n).onPressed, isNotNull);
    // The section sits below the fold at the default test surface size.
    await tester.ensureVisible(find.text(l10n.changePasswordButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.changePasswordButton));
    await tester.pumpAndSettle();

    expect(viewModel.passwordFailure, PasswordChangeFailure.throttled);
    expect(find.text(l10n.passwordChangeThrottledError), findsOneWidget);
  });
}

UserSettingsViewModel _viewModel({_FakeAuthRepo? auth}) {
  return UserSettingsViewModel(auth ?? _FakeAuthRepo(), _FakeEmployeeRepo());
}

/// Located by label rather than by index: the section grows fields over time,
/// and a positional lookup would silently start testing the wrong box.
Finder _fieldByLabel(String label) => find.widgetWithText(TextFormField, label);

/// `FilledButton.icon` builds a private subclass, so `byType(FilledButton)`
/// finds nothing — match the base class by predicate instead.
ButtonStyleButton _changeButton(WidgetTester tester, AppLocalizations l10n) {
  return tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.text(l10n.changePasswordButton),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ),
  );
}

Future<void> _fillPasswords(
  WidgetTester tester,
  AppLocalizations l10n, {
  required String current,
  required String next,
  String? confirmation,
}) async {
  await tester.enterText(_fieldByLabel(l10n.currentPasswordLabel), current);
  await tester.pump();
  await tester.enterText(_fieldByLabel(l10n.newPasswordLabel), next);
  await tester.pump();
  await tester.enterText(
    _fieldByLabel(l10n.confirmPasswordLabel),
    confirmation ?? next,
  );
  await tester.pumpAndSettle();
}

Exception _apiError(int statusCode, String body) {
  return PosApiException(
    message: 'failed with status $statusCode',
    statusCode: statusCode,
    responseBody: body,
  );
}

Future<void> _pump(WidgetTester tester, UserSettingsViewModel viewModel) async {
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
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: UserSettingsScreen(
        viewModel: viewModel,
        currentUser: _user,
        onUserChanged: (_) {},
        navigation: FakeAppNavigation(currentUser: _user),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeAuthRepo extends AuthRepository {
  _FakeAuthRepo({this.changeResult}) : super(PosApiService());

  final Result<void>? changeResult;

  @override
  Future<Result<PasswordPolicy>> loadPasswordPolicy() async {
    return const Ok(PasswordPolicy.fallback);
  }

  @override
  Future<Result<void>> changePassword(PasswordChangeDraft draft) async {
    return changeResult ?? const Ok(null);
  }
}

class _FakeEmployeeRepo extends EmployeeRepository {
  _FakeEmployeeRepo() : super(PosApiService());

  @override
  Future<Result<MyEmployeeLoans>> loadMyEmployeeLoans() async {
    return const Ok(MyEmployeeLoans(employee: null, loans: []));
  }
}
