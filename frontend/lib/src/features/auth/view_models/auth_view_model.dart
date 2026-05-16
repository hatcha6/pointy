import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/auth_repository.dart';

enum AuthStatus { checking, unauthenticated, authenticated }

class AuthViewModel extends ChangeNotifier {
  AuthViewModel(this._authRepository) {
    loadCurrentUser();
  }

  final AuthRepository _authRepository;

  AuthStatus _status = AuthStatus.checking;
  PosUser? _currentUser;
  bool _isSubmitting = false;
  bool _hasError = false;

  AuthStatus get status => _status;
  PosUser? get currentUser => _currentUser;
  bool get isSubmitting => _isSubmitting;
  bool get hasError => _hasError;

  Future<void> loadCurrentUser() async {
    _status = AuthStatus.checking;
    _hasError = false;
    notifyListeners();

    final result = await _authRepository.loadCurrentUser();
    switch (result) {
      case Ok<PosUser?>(value: final user):
        _currentUser = user;
        _status = user == null
            ? AuthStatus.unauthenticated
            : AuthStatus.authenticated;
      case Error<PosUser?>(exception: _):
        _currentUser = null;
        _status = AuthStatus.unauthenticated;
        _hasError = false;
    }
    notifyListeners();
  }

  Future<bool> login({
    required String username,
    required String password,
  }) async {
    _isSubmitting = true;
    _hasError = false;
    notifyListeners();

    final result = await _authRepository.login(
      username: username,
      password: password,
    );

    _isSubmitting = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _currentUser = user;
        _status = AuthStatus.authenticated;
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _currentUser = null;
        _status = AuthStatus.unauthenticated;
        _hasError = true;
        notifyListeners();
        return false;
    }
  }

  Future<void> logout() async {
    _isSubmitting = true;
    notifyListeners();

    await _authRepository.logout();

    _isSubmitting = false;
    _currentUser = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }
}
