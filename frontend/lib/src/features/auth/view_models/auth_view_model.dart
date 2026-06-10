import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/onboarding.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/auth_repository.dart';

enum AuthStatus { checking, setupRequired, unauthenticated, authenticated }

class AuthViewModel extends ChangeNotifier {
  AuthViewModel(
    this._authRepository, {
    AnalyticsEngine? analyticsEngine,
    bool autoLoad = true,
  }) : _analyticsEngine = analyticsEngine {
    if (autoLoad) {
      loadCurrentUser();
    }
  }

  final AuthRepository _authRepository;
  final AnalyticsEngine? _analyticsEngine;

  AuthStatus _status = AuthStatus.checking;
  PosUser? _currentUser;
  bool _isSubmitting = false;
  bool _hasError = false;

  AuthStatus get status => _status;
  PosUser? get currentUser => _currentUser;
  bool get isSubmitting => _isSubmitting;
  bool get hasError => _hasError;

  void replaceCurrentUser(PosUser user) {
    if (_currentUser?.id != user.id) {
      return;
    }
    _currentUser = user;
    notifyListeners();
  }

  Future<void> loadCurrentUser({bool forgetRememberedUser = false}) async {
    _status = AuthStatus.checking;
    _hasError = false;
    notifyListeners();

    if (forgetRememberedUser) {
      await _authRepository.forgetCurrentUser();
      _currentUser = null;
      _status = await _resolveUnauthenticatedStatus();
      _hasError = false;
      notifyListeners();
      return;
    }

    final result = await _authRepository.loadCurrentUser();
    switch (result) {
      case Ok<PosUser?>(value: final user):
        _currentUser = user;
        _status = user == null
            ? await _resolveUnauthenticatedStatus()
            : AuthStatus.authenticated;
      case Error<PosUser?>(exception: _):
        _currentUser = null;
        _status = await _resolveUnauthenticatedStatus();
        _hasError = false;
    }
    notifyListeners();
  }

  Future<AuthStatus> _resolveUnauthenticatedStatus() async {
    final result = await _authRepository.loadOnboardingStatus();
    return switch (result) {
      Ok<OnboardingStatus>(value: final status) =>
        status.requiresOnboarding
            ? AuthStatus.setupRequired
            : AuthStatus.unauthenticated,
      Error<OnboardingStatus>() => AuthStatus.unauthenticated,
    };
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
        _analyticsEngine?.setCurrentUser(user.id);
        unawaited(
          _analyticsEngine?.trackUsage(
                AnalyticsEventName.authLoginSucceeded,
                attributes: {'role': user.role.toJson()},
                flushImmediately: true,
              ) ??
              Future<void>.value(),
        );
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _currentUser = null;
        _status = AuthStatus.unauthenticated;
        _hasError = true;
        unawaited(
          _analyticsEngine?.trackUsage(
                AnalyticsEventName.authLoginFailed,
                severity: AnalyticsEventSeverity.warning,
                flushImmediately: true,
              ) ??
              Future<void>.value(),
        );
        notifyListeners();
        return false;
    }
  }

  Future<bool> createInitialAdmin(InitialAdminDraft draft) async {
    _isSubmitting = true;
    _hasError = false;
    notifyListeners();

    final result = await _authRepository.createInitialAdmin(draft);

    _isSubmitting = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _currentUser = user;
        _status = AuthStatus.authenticated;
        _analyticsEngine?.setCurrentUser(user.id);
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _currentUser = null;
        _status = await _resolveUnauthenticatedStatus();
        _hasError = _status == AuthStatus.setupRequired;
        notifyListeners();
        return false;
    }
  }

  Future<void> logout() async {
    _isSubmitting = true;
    notifyListeners();

    unawaited(
      _analyticsEngine?.trackUsage(
            AnalyticsEventName.authLogout,
            flushImmediately: true,
          ) ??
          Future<void>.value(),
    );
    await _authRepository.logout();
    _analyticsEngine?.setCurrentUser(null);

    _isSubmitting = false;
    _currentUser = null;
    _status = await _resolveUnauthenticatedStatus();
    notifyListeners();
  }
}
