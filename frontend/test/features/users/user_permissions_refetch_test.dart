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

/// The editor is opened from the users list, whose rows carry a name and a
/// role but neither the role's permissions nor the extras already granted.
/// Edited off such a row, every inherited permission looked grantable and
/// every existing extra looked absent — so the first save replaced them with
/// whatever boxes were ticked that visit. The editor now fetches the account
/// before it lets anyone toggle.
void main() {
  const listRow = PosUser(
    id: 4,
    username: 'sara',
    role: UserRole.cashier,
    isActive: true,
    displayName: 'سارة',
    extraPermissionCount: 2,
  );
  const account = PosUser(
    id: 4,
    username: 'sara',
    role: UserRole.cashier,
    isActive: true,
    displayName: 'سارة',
    rolePermissions: {'sales.add_order'},
    extraPermissions: {'catalog.add_product', 'inventory.add_stockcount'},
    extraPermissionCount: 2,
  );

  PermissionCatalogEntry entry(String code) => _catalog.groups
      .expand((group) => group.permissions)
      .firstWhere((candidate) => candidate.code == code);

  test('the editor works on the fetched account, not the list row', () async {
    final repository = _AccountRepository(account);
    final viewModel = UserPermissionsViewModel(repository, user: listRow);
    addTearDown(viewModel.dispose);

    // Nothing is toggleable until the account has arrived.
    expect(viewModel.isEditable, isFalse);
    expect(viewModel.canToggle(entry('inventory.apply_stockcount')), isFalse);

    await settle(viewModel, () => !viewModel.isLoading);

    expect(viewModel.isReady, isTrue);
    expect(viewModel.isEditable, isTrue);
    expect(viewModel.isInRole('sales.add_order'), isTrue);
    expect(viewModel.canToggle(entry('sales.add_order')), isFalse);
    expect(viewModel.isExtra('catalog.add_product'), isTrue);
    expect(viewModel.isExtra('inventory.add_stockcount'), isTrue);
    expect(viewModel.inheritedCount, 1);
    expect(viewModel.extraCount, 2);
    expect(viewModel.hasChanges, isFalse);

    // One more grant is saved on top of the two that were already there.
    viewModel.toggle(entry('inventory.apply_stockcount'), true);
    expect(await viewModel.save(), isTrue);
    expect(
      repository.lastDraft!.extraPermissions,
      unorderedEquals([
        'catalog.add_product',
        'inventory.add_stockcount',
        'inventory.apply_stockcount',
      ]),
    );
  });

  test('a refused save explains itself', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final repository = _AccountRepository(account)
      ..onUpdate = (_) => Error(
        const PosApiException(
          message: 'User update failed with status 400',
          statusCode: 400,
          responseBody:
              '{"extra_permissions": ["You can only grant permissions you '
              'hold yourself: inventory.apply_stockcount."]}',
        ),
      );
    final viewModel = UserPermissionsViewModel(repository, user: listRow);
    addTearDown(viewModel.dispose);
    await settle(viewModel, () => !viewModel.isLoading);

    viewModel.toggle(entry('inventory.apply_stockcount'), true);

    expect(await viewModel.save(), isFalse);
    expect(viewModel.hasSaveError, isTrue);
    expect(
      viewModel.saveFailure!.describe(l10n),
      l10n.userPermissionsNotGrantableError,
    );
  });

  test(
    'a failed account fetch keeps the editor locked until a retry',
    () async {
      final repository = _AccountRepository(account)..failAccountFetch = true;
      final viewModel = UserPermissionsViewModel(repository, user: listRow);
      addTearDown(viewModel.dispose);
      await settle(viewModel, () => !viewModel.isLoading);

      expect(viewModel.hasError, isTrue);
      expect(viewModel.isReady, isFalse);
      expect(viewModel.isEditable, isFalse);
      expect(viewModel.canToggle(entry('inventory.apply_stockcount')), isFalse);

      repository.failAccountFetch = false;
      await viewModel.load();

      expect(viewModel.hasError, isFalse);
      expect(viewModel.isEditable, isTrue);
      expect(viewModel.isExtra('catalog.add_product'), isTrue);
    },
  );
}

/// Completes once [done] holds, checking again on every notification.
Future<void> settle(ChangeNotifier notifier, bool Function() done) {
  if (done()) {
    return Future.value();
  }
  final completer = Completer<void>();
  late void Function() listener;
  listener = () {
    if (done() && !completer.isCompleted) {
      notifier.removeListener(listener);
      completer.complete();
    }
  };
  notifier.addListener(listener);
  return completer.future;
}

class _AccountRepository extends UserRepository {
  _AccountRepository(this.account)
    : super(PosApiService(baseUrl: 'http://pointy.test/api'));

  final PosUser account;
  bool failAccountFetch = false;
  Result<PosUser> Function(UserUpdateDraft draft)? onUpdate;
  UserUpdateDraft? lastDraft;

  @override
  Future<Result<PosUser>> loadUser(int id) async {
    if (failAccountFetch) {
      return Error(Exception('offline'));
    }
    return Ok(account);
  }

  @override
  Future<Result<PermissionCatalog>> loadPermissionCatalog() async =>
      const Ok(_catalog);

  @override
  Future<Result<PosUser>> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    lastDraft = draft;
    return onUpdate?.call(draft) ?? Ok(account);
  }
}

const _catalog = PermissionCatalog(
  groups: [
    PermissionCatalogGroup(
      key: 'sales',
      label: 'المبيعات',
      description: '',
      permissions: [
        PermissionCatalogEntry(
          code: 'sales.add_order',
          label: 'إجراء المبيعات',
          description: '',
          grantable: true,
        ),
        PermissionCatalogEntry(
          code: 'sales.process_return_lookup',
          label: 'المرتجعات',
          description: '',
          grantable: true,
        ),
      ],
    ),
    PermissionCatalogGroup(
      key: 'catalog',
      label: 'المنتجات',
      description: '',
      permissions: [
        PermissionCatalogEntry(
          code: 'catalog.add_product',
          label: 'إضافة المنتجات',
          description: '',
          grantable: true,
        ),
      ],
    ),
    PermissionCatalogGroup(
      key: 'inventory',
      label: 'المخزون',
      description: '',
      permissions: [
        PermissionCatalogEntry(
          code: 'inventory.add_stockcount',
          label: 'إجراء الجرد',
          description: '',
          grantable: true,
        ),
        PermissionCatalogEntry(
          code: 'inventory.apply_stockcount',
          label: 'اعتماد الجرد',
          description: '',
          grantable: true,
        ),
      ],
    ),
  ],
);
