import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/user_repository.dart';

class UserManagementViewModel extends ChangeNotifier {
  UserManagementViewModel(
    this._userRepository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine {
    loadUsers();
  }

  final UserRepository _userRepository;
  final AnalyticsEngine? _analyticsEngine;

  List<PosUser> _users = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSaving = false;
  bool _hasError = false;
  bool _hasSaveError = false;
  bool _hasMoreUsers = true;
  int _nextPage = 1;
  int? _totalCount;
  String _searchQuery = '';
  UserRole? _roleFilter;

  List<PosUser> get users => List.unmodifiable(_users);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSaving => _isSaving;
  bool get hasError => _hasError;
  bool get hasSaveError => _hasSaveError;
  bool get hasMoreUsers => _hasMoreUsers;
  String get searchQuery => _searchQuery;
  UserRole? get roleFilter => _roleFilter;

  /// Total users matching the active query across all pages, or — until the
  /// server count is known — the number currently loaded.
  int get totalCount => _totalCount ?? _users.length;

  /// Active-user count among the loaded set (exact once everything is loaded).
  int get activeCount => _users.where((user) => user.isActive).length;

  /// Number of loaded users carrying directly-granted (custom) permissions.
  int get customPermissionUserCount =>
      _users.where((user) => user.hasExtraPermissions).length;

  /// Whether any filter/search is narrowing the list.
  bool get isFiltered => _searchQuery.isNotEmpty || _roleFilter != null;

  Future<void> setSearchQuery(String value) async {
    final trimmed = value.trim();
    if (trimmed == _searchQuery) {
      return;
    }
    _searchQuery = trimmed;
    await loadUsers();
  }

  Future<void> setRoleFilter(UserRole? role) async {
    if (role == _roleFilter) {
      return;
    }
    _roleFilter = role;
    await loadUsers();
  }

  Future<void> loadUsers() async {
    _isLoading = true;
    _hasError = false;
    _hasMoreUsers = true;
    _nextPage = 1;
    notifyListeners();

    final result = await _userRepository.loadUsers(
      page: _nextPage,
      search: _searchQuery,
      role: _roleFilter?.toJson() ?? '',
    );
    switch (result) {
      case Ok<PosUserPage>(value: final page):
        _users = page.users;
        _hasMoreUsers = page.hasMore;
        _totalCount = page.totalCount;
        _nextPage = 2;
      case Error<PosUserPage>(exception: _):
        _hasError = true;
        _hasMoreUsers = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreUsers() async {
    if (_isLoading || _isLoadingMore || !_hasMoreUsers) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    final result = await _userRepository.loadUsers(
      page: _nextPage,
      search: _searchQuery,
      role: _roleFilter?.toJson() ?? '',
    );
    switch (result) {
      case Ok<PosUserPage>(value: final page):
        _users = [..._users, ...page.users];
        _hasMoreUsers = page.hasMore;
        _totalCount = page.totalCount ?? _totalCount;
        _nextPage += 1;
      case Error<PosUserPage>(exception: _):
        _hasError = true;
        _hasMoreUsers = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<bool> createUser(UserCreateDraft draft) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _userRepository.createUser(draft);
    _isSaving = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _users = [..._users, user];
        _totalCount = (_totalCount ?? _users.length - 1) + 1;
        _trackUserCreated(user, draft);
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> updateUserActive(PosUser user, bool isActive) {
    return _updateUser(
      user,
      UserUpdateDraft(isActive: isActive),
      eventName: 'users.management.user.active_changed',
    );
  }

  /// Apply an arbitrary edit (profile, role, and/or extra permissions) from the
  /// edit sheet or permissions editor, then patch the local row in place.
  Future<bool> saveUserEdits(PosUser user, UserUpdateDraft draft) {
    return _updateUser(
      user,
      draft,
      eventName: 'users.management.user.edited',
    );
  }

  /// Replace a row already updated elsewhere (e.g. the pushed permissions
  /// editor returned a fresh user) without another network round-trip.
  void replaceUser(PosUser updatedUser) {
    _users = [
      for (final existing in _users)
        if (existing.id == updatedUser.id) updatedUser else existing,
    ];
    notifyListeners();
  }

  Future<bool> _updateUser(
    PosUser user,
    UserUpdateDraft draft, {
    required String eventName,
  }) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _userRepository.updateUser(id: user.id, draft: draft);
    _isSaving = false;
    switch (result) {
      case Ok<PosUser>(value: final updatedUser):
        _users = [
          for (final existing in _users)
            if (existing.id == updatedUser.id) updatedUser else existing,
        ];
        _trackUserUpdated(
          name: eventName,
          previousUser: user,
          updatedUser: updatedUser,
        );
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  void _trackUserCreated(PosUser user, UserCreateDraft draft) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'users.management.user.created',
      entityType: 'user',
      entityId: user.id,
      attributes: {
        'target_user_id': user.id,
        'target_user_label': user.label,
        'assigned_role': user.role.toJson(),
        'is_active': user.isActive,
        'email_present': draft.email.trim().isNotEmpty,
        'display_name_present': draft.displayName.trim().isNotEmpty,
        'extra_permission_count': user.extraPermissionCount,
        'source': 'user_management',
      },
    );
  }

  void _trackUserUpdated({
    required String name,
    required PosUser previousUser,
    required PosUser updatedUser,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'user',
      entityId: updatedUser.id,
      attributes: {
        'target_user_id': updatedUser.id,
        'target_user_label': updatedUser.label,
        'previous_role': previousUser.role.toJson(),
        'new_role': updatedUser.role.toJson(),
        'previous_is_active': previousUser.isActive,
        'new_is_active': updatedUser.isActive,
        'extra_permission_count': updatedUser.extraPermissionCount,
        'source': 'user_management',
      },
    );
  }
}
