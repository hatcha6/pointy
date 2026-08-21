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

/// A failed users load left the screen naming the failure with nothing to do
/// about it. The app-bar refresh is wrapped in [UserManagementGuard], so a
/// supervisor allowed to *see* the roster but not manage it had no escape at
/// all — the retry now sits in the error state itself, where the failure is.
void main() {
  testWidgets('a failed users load offers a retry that refills the list', (
    tester,
  ) async {
    final api = _UsersApi(failFirstRequest: true);
    final viewModel = UserManagementViewModel(UserRepository(api.service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(_usersApp(viewModel));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل المستخدمين.'), findsOneWidget);
    final retry = find.byKey(const ValueKey('users_retry_button'));
    expect(retry, findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsWidgets);

    final before = api.userRequestCount;
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(api.userRequestCount, before + 1);
    expect(find.text('تعذر تحميل المستخدمين.'), findsNothing);
    expect(find.text('سارة'), findsWidgets);
  });

  testWidgets('a healthy users load shows no retry', (tester) async {
    final api = _UsersApi(failFirstRequest: false);
    final viewModel = UserManagementViewModel(UserRepository(api.service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(_usersApp(viewModel));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('users_retry_button')), findsNothing);
    expect(find.text('سارة'), findsWidgets);
  });
}

/// A users backend that fails the *first* request and serves normally
/// afterwards — the shape of a LAN blip, which is what makes a retry the
/// correct affordance rather than a permanent error.
class _UsersApi {
  _UsersApi({required this.failFirstRequest});

  final bool failFirstRequest;
  int userRequestCount = 0;
  late final PosApiService service = PosApiService(client: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path.endsWith('/users/')) {
      userRequestCount += 1;
      if (failFirstRequest && userRequestCount == 1) {
        return http.Response('', 500);
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
    return http.Response('', 404);
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
  'permissions': const ['users.view_posuser', 'users.add_posuser'],
};

Map<String, Object?> _cashierJson() => {
  'id': 4,
  'username': 'sara',
  'display_name': 'سارة',
  'role': 'cashier',
  'is_active': true,
  'permissions': const <String>[],
};
