import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_management_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_management_screen.dart';

import '../../shared/fake_app_navigation.dart';

/// A refused create used to show one generic sentence whatever the server
/// said, so a username reused from the previous test account read exactly
/// like a role the admin may not assign. The sheet now shows the reason, and
/// pins a taken username to its own field.
void main() {
  Future<AppLocalizations> openCreateSheet(
    WidgetTester tester,
    _UsersApi api,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final viewModel = UserManagementViewModel(UserRepository(api.service));
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(_usersApp(viewModel));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.tap(find.text(l10n.addUserButton).first);
    await tester.pumpAndSettle();
    return l10n;
  }

  Future<void> submit(
    WidgetTester tester,
    AppLocalizations l10n, {
    required String username,
  }) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.usernameLabel),
      username,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.passwordLabel),
      'secret-pass-1',
    );
    await tester.tap(find.text(l10n.createUserButton));
    await tester.pumpAndSettle();
  }

  testWidgets('a taken username is reported on the field, not as a mystery', (
    tester,
  ) async {
    final api = _UsersApi(
      refusal: {
        'username': ['A user with that username already exists.'],
      },
    );
    final l10n = await openCreateSheet(tester, api);

    await submit(tester, l10n, username: 'sara');

    expect(find.text(l10n.usernameTakenError), findsOneWidget);
    expect(find.text(l10n.createUserError), findsOneWidget);
    expect(find.text(l10n.userRoleNotAssignableError), findsNothing);

    // Typing a different name lifts the objection from the field.
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.usernameLabel),
      'sara2',
    );
    await tester.pump();
    expect(find.text(l10n.usernameTakenError), findsNothing);
  });

  testWidgets('a role beyond the acting admin says so', (tester) async {
    final api = _UsersApi(
      refusal: {
        'role': [
          'You can only assign a role whose permissions you hold yourself.',
        ],
      },
    );
    final l10n = await openCreateSheet(tester, api);

    await submit(tester, l10n, username: 'new-supervisor');

    expect(find.text(l10n.userRoleNotAssignableError), findsOneWidget);
    expect(find.text(l10n.createUserError), findsNothing);
  });
}

/// A users backend that lists one cashier and refuses every create with the
/// given DRF-shaped body.
class _UsersApi {
  _UsersApi({required this.refusal});

  final Map<String, Object?> refusal;
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    if (!request.url.path.endsWith('/users/')) {
      return http.Response('', 404);
    }
    if (request.method == 'POST') {
      return http.Response(
        jsonEncode(refusal),
        400,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response(
      jsonEncode({
        'count': 1,
        'next': null,
        'results': [_cashierJson()],
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Widget _usersApp(UserManagementViewModel viewModel) {
  final currentUser = PosUser.fromJson(_managerJson());
  final capabilities = AuthorizationCapabilities.forUser(currentUser);

  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: UserManagementScreen(
      viewModel: viewModel,
      currentUser: currentUser,
      capabilities: capabilities,
      onOpenUserDetails: (_) {},
      onOpenUserPermissions: (_) async => false,
      navigation: FakeAppNavigation(
        currentUser: currentUser,
        capabilities: capabilities,
      ),
    ),
  );
}

Map<String, Object?> _managerJson() => {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير النظام',
  'role': 'manager',
  'is_active': true,
  'permissions': const ['*'],
};

Map<String, Object?> _cashierJson() => {
  'id': 4,
  'username': 'sara',
  'display_name': 'سارة',
  'role': 'cashier',
  'is_active': true,
  'extra_permission_count': 0,
};
