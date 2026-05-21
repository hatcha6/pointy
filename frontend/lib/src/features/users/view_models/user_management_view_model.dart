import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/user_repository.dart';

class UserManagementViewModel extends ChangeNotifier {
  UserManagementViewModel(this._userRepository) {
    loadUsers();
  }

  final UserRepository _userRepository;

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
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> updateUserRole(PosUser user, UserRole role) {
    return _updateUser(user, UserUpdateDraft(role: role));
  }

  Future<bool> updateUserActive(PosUser user, bool isActive) {
    return _updateUser(user, UserUpdateDraft(isActive: isActive));
  }

  Future<bool> _updateUser(PosUser user, UserUpdateDraft draft) async {
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
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }
}
