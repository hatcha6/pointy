import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/permission_catalog.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/user_repository.dart';
import '../user_save_failure.dart';

/// Drives the per-user permission editor: loads the grantable catalog, tracks
/// the desired set of directly-granted (extra) permissions, and saves them.
///
/// Permissions inherited from the role are shown locked; only grantable,
/// non-role permissions can be toggled. Managers hold everything, so the editor
/// renders read-only for them.
///
/// The [user] handed in is only a starting point — usually a row from the
/// users list, which carries the name and role but neither the role's
/// permissions nor the extras already granted. The editor fetches the full
/// account before it lets anyone toggle: edited off a bare row, every
/// inherited permission looked grantable and every existing extra looked
/// absent, so the first save replaced them with just the boxes ticked that
/// visit.
class UserPermissionsViewModel extends ChangeNotifier {
  UserPermissionsViewModel(this._repository, {required PosUser user})
    : _user = user,
      _selectedExtras = Set.of(user.extraPermissions) {
    load();
  }

  final UserRepository _repository;

  PosUser _user;
  PermissionCatalog _catalog = PermissionCatalog.empty;
  Set<String> _selectedExtras;
  String _search = '';
  bool _userLoaded = false;
  bool _catalogLoaded = false;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isSaving = false;
  bool _hasSaveError = false;
  UserSaveFailure? _saveFailure;
  bool _savedOnce = false;

  PosUser get user => _user;
  PermissionCatalog get catalog => _catalog;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get isSaving => _isSaving;
  bool get hasSaveError => _hasSaveError;
  String get search => _search;

  /// Why the last save was refused, when the server said.
  UserSaveFailure? get saveFailure => _saveFailure;

  /// Both the full account and the catalog have arrived. Before that the
  /// editor has nothing trustworthy to show, let alone save.
  bool get isReady => _userLoaded && _catalogLoaded;

  /// Whether the target user holds every permission via their role (manager).
  bool get roleHasAll =>
      _user.role.isManager || _user.rolePermissions.contains('*');

  bool get isEditable => isReady && !roleHasAll;

  bool isInRole(String code) =>
      roleHasAll || _user.rolePermissions.contains(code);

  bool isExtra(String code) => _selectedExtras.contains(code);

  bool isGranted(String code) => isInRole(code) || isExtra(code);

  /// A code is toggleable only if it is grantable by the current admin and not
  /// already supplied by the role.
  bool canToggle(PermissionCatalogEntry entry) =>
      isEditable && entry.grantable && !isInRole(entry.code);

  int get inheritedCount {
    if (roleHasAll) {
      return _catalog.totalCount;
    }
    return _catalog.groups
        .expand((group) => group.permissions)
        .where((entry) => _user.rolePermissions.contains(entry.code))
        .length;
  }

  int get extraCount => _selectedExtras.length;

  bool get hasChanges =>
      !setEquals(_selectedExtras, Set.of(_user.extraPermissions));

  /// Groups filtered by the active search term (matches label, description or
  /// code), preserving order. Empty groups are dropped.
  List<PermissionCatalogGroup> get visibleGroups {
    if (_search.isEmpty) {
      return _catalog.groups;
    }
    final term = _search.toLowerCase();
    final result = <PermissionCatalogGroup>[];
    for (final group in _catalog.groups) {
      final matches = group.permissions
          .where(
            (entry) =>
                entry.label.toLowerCase().contains(term) ||
                entry.description.toLowerCase().contains(term) ||
                entry.code.toLowerCase().contains(term),
          )
          .toList(growable: false);
      if (matches.isNotEmpty) {
        result.add(
          PermissionCatalogGroup(
            key: group.key,
            label: group.label,
            description: group.description,
            permissions: matches,
          ),
        );
      }
    }
    return result;
  }

  int grantedInGroup(PermissionCatalogGroup group) =>
      group.permissions.where((entry) => isGranted(entry.code)).length;

  /// Fetches the full account and the grantable catalog together. A failure
  /// of either leaves the editor in its error state, where a retry runs both
  /// again.
  Future<void> load() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final userFuture = _repository.loadUser(_user.id);
    final catalogFuture = _repository.loadPermissionCatalog();
    switch (await userFuture) {
      case Ok<PosUser>(value: final account):
        _user = account;
        _selectedExtras = Set.of(account.extraPermissions);
        _userLoaded = true;
      case Error<PosUser>(exception: _):
        _hasError = true;
    }
    switch (await catalogFuture) {
      case Ok<PermissionCatalog>(value: final catalog):
        _catalog = catalog;
        _catalogLoaded = true;
      case Error<PermissionCatalog>(exception: _):
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  void setSearch(String value) {
    final trimmed = value.trim();
    if (trimmed == _search) {
      return;
    }
    _search = trimmed;
    notifyListeners();
  }

  void toggle(PermissionCatalogEntry entry, bool granted) {
    if (!canToggle(entry)) {
      return;
    }
    if (granted) {
      _selectedExtras.add(entry.code);
    } else {
      _selectedExtras.remove(entry.code);
    }
    notifyListeners();
  }

  void setGroup(PermissionCatalogGroup group, bool granted) {
    for (final entry in group.permissions) {
      if (!canToggle(entry)) {
        continue;
      }
      if (granted) {
        _selectedExtras.add(entry.code);
      } else {
        _selectedExtras.remove(entry.code);
      }
    }
    notifyListeners();
  }

  /// Whether every grantable, non-role entry in [group] is currently selected.
  bool isGroupFullyGranted(PermissionCatalogGroup group) {
    final toggleable = group.permissions.where(canToggle).toList();
    if (toggleable.isEmpty) {
      return false;
    }
    return toggleable.every((entry) => isExtra(entry.code));
  }

  Future<bool> save() async {
    if (!isEditable) {
      return false;
    }
    _isSaving = true;
    _hasSaveError = false;
    _saveFailure = null;
    notifyListeners();

    final result = await _repository.updateUser(
      id: _user.id,
      draft: UserUpdateDraft(extraPermissions: _selectedExtras.toList()),
    );
    _isSaving = false;
    switch (result) {
      case Ok<PosUser>(value: final updated):
        _user = updated;
        _selectedExtras = Set.of(updated.extraPermissions);
        _savedOnce = true;
        notifyListeners();
        return true;
      case Error<PosUser>(exception: final exception):
        _hasSaveError = true;
        _saveFailure = UserSaveFailure.fromError(exception);
        notifyListeners();
        return false;
    }
  }

  /// Whether at least one successful save happened this session (so the opener
  /// knows to refresh its list/detail copy).
  bool get didSave => _savedOnce;
}
