import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/permission_catalog.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_permissions_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_permissions_screen.dart';

/// The permission editor is a long checkbox list a manager works through group
/// by group. `hasChanges` already gated the Save button, but nothing consulted
/// it on the way out — a back press discarded every toggle silently.
void main() {
  const user = PosUser(
    id: 4,
    username: 'sara',
    role: UserRole.cashier,
    isActive: true,
    displayName: 'سارة',
    rolePermissions: {'sales.create'},
  );

  Future<GlobalKey<NavigatorState>> pushScreen(WidgetTester tester) async {
    final viewModel = UserPermissionsViewModel(
      _StubUserRepository(
        PosApiService(baseUrl: 'http://pointy.test/api'),
        user,
      ),
      user: user,
    );
    addTearDown(viewModel.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => UserPermissionsScreen(viewModel: viewModel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey;
  }

  testWidgets('leaving with toggled permissions asks before discarding', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushScreen(tester);

    await tester.tap(find.text('إلغاء فاتورة'));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsOneWidget);
    // Keeping the edit leaves the manager on the editor with the box still on.
    await tester.tap(find.text(l10n.keepEditingButton));
    await tester.pumpAndSettle();
    expect(find.byType(UserPermissionsScreen), findsOneWidget);
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .where((box) => box.value ?? false)
          .length,
      1,
    );
  });

  testWidgets('discarding confirms out of the editor', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushScreen(tester);

    await tester.tap(find.text('إلغاء فاتورة'));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.discardChangesButton));
    await tester.pumpAndSettle();

    expect(find.byType(UserPermissionsScreen), findsNothing);
  });

  testWidgets('an untouched editor leaves without a prompt', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushScreen(tester);

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(UserPermissionsScreen), findsNothing);
  });

  testWidgets('toggling back to the original state leaves without a prompt', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushScreen(tester);

    await tester.tap(find.text('إلغاء فاتورة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء فاتورة'));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(UserPermissionsScreen), findsNothing);
  });
}

class _StubUserRepository extends UserRepository {
  _StubUserRepository(super.service, this.user);

  final PosUser user;

  @override
  Future<Result<PosUser>> loadUser(int id) async => Ok(user);

  @override
  Future<Result<PermissionCatalog>> loadPermissionCatalog() async =>
      const Ok(catalogForTest);
}

const catalogForTest = PermissionCatalog(
  groups: [
    PermissionCatalogGroup(
      key: 'sales',
      label: 'المبيعات',
      description: 'صلاحيات نقطة البيع',
      permissions: [
        PermissionCatalogEntry(
          code: 'sales.process_return_lookup',
          label: 'البحث عن فاتورة للإرجاع',
          description: 'البحث في فواتير الورديات السابقة',
          grantable: true,
        ),
        PermissionCatalogEntry(
          code: 'sales.void',
          label: 'إلغاء فاتورة',
          description: 'إلغاء فاتورة مكتملة',
          grantable: true,
        ),
      ],
    ),
  ],
);
