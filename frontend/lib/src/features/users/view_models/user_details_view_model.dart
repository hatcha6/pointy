import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/user_activity.dart';
import '../../../data/repositories/user_repository.dart';

class UserDetailsViewModel extends ChangeNotifier {
  UserDetailsViewModel(this._userRepository, {required PosUser initialUser})
    : _user = initialUser {
    loadActivity();
  }

  final UserRepository _userRepository;

  PosUser _user;
  UserActivityOverview? _activity;
  bool _isLoading = false;
  bool _hasError = false;

  PosUser get user => _activity?.user ?? _user;
  UserActivityOverview? get activity => _activity;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;

  Future<void> loadActivity() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _userRepository.loadUserActivity(_user.id);
    switch (result) {
      case Ok<UserActivityOverview>(value: final overview):
        _activity = overview;
        _user = overview.user;
      case Error<UserActivityOverview>(exception: _):
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }
}
