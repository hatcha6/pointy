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

  List<PosUser> get users => List.unmodifiable(_users);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSaving => _isSaving;
  bool get hasError => _hasError;
  bool get hasSaveError => _hasSaveError;
  bool get hasMoreUsers => _hasMoreUsers;

  Future<void> loadUsers() async {
    _isLoading = true;
    _hasError = false;
    _hasMoreUsers = true;
    _nextPage = 1;
    notifyListeners();

    final result = await _userRepository.loadUsers(page: _nextPage);
    switch (result) {
      case Ok<PosUserPage>(value: final page):
        _users = page.users;
        _hasMoreUsers = page.hasMore;
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

    final result = await _userRepository.loadUsers(page: _nextPage);
    switch (result) {
      case Ok<PosUserPage>(value: final page):
        _users = [..._users, ...page.users];
        _hasMoreUsers = page.hasMore;
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
        _trackUserCreated(user, draft);
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> updateUserRole(PosUser user, UserRole role) {
    return _updateUser(
      user,
      UserUpdateDraft(role: role),
      eventName: 'users.management.user.role_changed',
    );
  }

  Future<bool> updateUserActive(PosUser user, bool isActive) {
    return _updateUser(
      user,
      UserUpdateDraft(isActive: isActive),
      eventName: 'users.management.user.active_changed',
    );
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
        'source': 'user_management',
      },
    );
  }
}
