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
  bool _isSaving = false;
  bool _hasError = false;
  bool _hasSaveError = false;

  List<PosUser> get users => List.unmodifiable(_users);
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasError => _hasError;
  bool get hasSaveError => _hasSaveError;

  Future<void> loadUsers() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _userRepository.loadUsers();
    switch (result) {
      case Ok<List<PosUser>>(value: final users):
        _users = users;
      case Error<List<PosUser>>(exception: _):
        _hasError = true;
    }

    _isLoading = false;
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
