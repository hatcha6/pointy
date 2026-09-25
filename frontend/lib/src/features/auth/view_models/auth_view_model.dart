import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/onboarding.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/auth_repository.dart';
import 'login_failure.dart';

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
  bool _requiresShopSetup = false;
  LoginFailure? _loginFailure;
  LoginFailure? _connectionProblem;

  AuthStatus get status => _status;
  PosUser? get currentUser => _currentUser;
  bool get isSubmitting => _isSubmitting;
  bool get hasError => _hasError;

  /// Why the last sign-in attempt failed, or null after a success or before
  /// any attempt.
  LoginFailure? get loginFailure => _loginFailure;

  /// The way to the server is broken, as the last session probe found it —
  /// so the login screen can say so before anyone types a password that
  /// cannot get through. Cleared by the next probe or sign-in that works.
  LoginFailure? get connectionProblem => _connectionProblem;

  /// True for the one session right after the initial admin is created, so the
  /// app shows the first-run shop-setup wizard before the main shell.
  bool get requiresShopSetup => _requiresShopSetup;

  void completeShopSetup() {
    if (_requiresShopSetup) {
      _requiresShopSetup = false;
      notifyListeners();
    }
  }

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
    // A new probe is a new situation: whatever the last attempt ran into (a
    // server that has since come back, say) is not it. The probe below
    // records its own finding, if the way to the server is still broken.
    _loginFailure = null;
    _connectionProblem = null;
    notifyListeners();

    if (forgetRememberedUser) {
      await _authRepository.forgetCurrentUser();
      _currentUser = null;
      _status = await _resolveUnauthenticatedStatus(retryOnFailure: true);
      _hasError = false;
      notifyListeners();
      return;
    }

    final result = await _authRepository.loadCurrentUser();
    switch (result) {
      case Ok<PosUser?>(value: final user):
        _currentUser = user;
        if (user != null) {
          _connectionProblem = null;
          _status = AuthStatus.authenticated;
        } else {
          _status = await _resolveUnauthenticatedStatus(retryOnFailure: true);
        }
      case Error<PosUser?>(exception: final exception):
        _noteConnectionProblem(exception);
        _currentUser = null;
        _status = await _resolveUnauthenticatedStatus(retryOnFailure: true);
        _hasError = false;
    }
    notifyListeners();
  }

  /// Remember a probe that failed on the way to the server. A failure of any
  /// other kind says nothing about the connection and is not kept.
  void _noteConnectionProblem(Object exception) {
    final failure = classifyLoginFailure(
      exception,
      viaRelay: _authRepository.usesRelay,
    );
    if (failure.isConnectionProblem) {
      _connectionProblem = failure;
    }
  }

  /// Re-read who we are, quietly.
  ///
  /// Called when the server's permissions counter moves: the cashier is still
  /// signed in, but what they may do has changed and the UI has to reshape.
  /// [loadCurrentUser] cannot serve here — it sets [AuthStatus.checking]
  /// first, which sends the whole app back to the loading gate mid-shift.
  Future<void> refreshCurrentUser() async {
    if (_status != AuthStatus.authenticated) {
      return;
    }
    final result = await _authRepository.loadCurrentUser();
    switch (result) {
      case Ok<PosUser?>(value: final user):
        if (user == null) {
          // The session really is gone — disabled account, or signed out from
          // elsewhere. That is a logout, and it has to take effect. The user
          // goes with the status, never before it (see [logout]).
          final status = await _resolveUnauthenticatedStatus();
          _currentUser = null;
          _status = status;
        } else {
          _currentUser = user;
        }
        notifyListeners();
      case Error<PosUser?>():
        // Keep the permissions we have. The network blinking must not throw a
        // cashier out mid-sale; the next bump (or the next login) tries again.
        break;
    }
  }

  /// Waits between tries of the onboarding probe. One entry per extra attempt.
  static const List<Duration> _onboardingProbeRetryDelays = [
    Duration(milliseconds: 400),
    Duration(seconds: 1),
  ];

  /// Decide which screen an unauthenticated app belongs on.
  ///
  /// [retryOnFailure] buys a few more tries for the callers that cannot afford
  /// to guess wrong. This probe chooses between the first-run wizard and the
  /// login screen, and on a fresh install the login screen is a dead end —
  /// there are no accounts to sign in with, so an owner who lands there has no
  /// way forward but to restart the app and hope. The probe's timeout is five
  /// seconds, sized for a till mid-shift rather than for the cold start of a
  /// backend that came up moments ago, so a single timed-out request must not
  /// be what settles it.
  ///
  /// Logout passes false deliberately: we were signed in a moment ago, so
  /// accounts demonstrably exist, and a cashier whose server has gone down
  /// should reach the login screen immediately rather than sit through retries
  /// of a question already answered.
  Future<AuthStatus> _resolveUnauthenticatedStatus({
    bool retryOnFailure = false,
  }) async {
    final delays = retryOnFailure
        ? _onboardingProbeRetryDelays
        : const <Duration>[];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(delays[attempt - 1]);
      }
      final result = await _authRepository.loadOnboardingStatus();
      switch (result) {
        case Ok<OnboardingStatus>(value: final status):
          // The server answered, whatever it said: the way there is open.
          _connectionProblem = null;
          return status.requiresOnboarding
              ? AuthStatus.setupRequired
              : AuthStatus.unauthenticated;
        case Error<OnboardingStatus>(exception: final exception):
          _noteConnectionProblem(exception);
      }
    }
    return AuthStatus.unauthenticated;
  }

  Future<bool> login({
    required String username,
    required String password,
  }) async {
    _isSubmitting = true;
    _hasError = false;
    _loginFailure = null;
    notifyListeners();

    final result = await _authRepository.login(
      username: username,
      password: password,
    );

    _isSubmitting = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _currentUser = user;
        _connectionProblem = null;
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
      case Error<PosUser>(exception: final exception):
        final failure = classifyLoginFailure(
          exception,
          viaRelay: _authRepository.usesRelay,
        );
        _currentUser = null;
        _status = AuthStatus.unauthenticated;
        _hasError = true;
        _loginFailure = failure;
        // A refused password, a throttle, a server error: the server was
        // reached, so any earlier connection problem is over.
        _connectionProblem = failure.isConnectionProblem ? failure : null;
        unawaited(
          _analyticsEngine?.trackUsage(
                AnalyticsEventName.authLoginFailed,
                severity: AnalyticsEventSeverity.warning,
                // Which failure, so a field export can tell a wrong password
                // from a shop whose relay was down at every sign-in.
                attributes: {
                  'failure': failure.name,
                  'via_relay': _authRepository.usesRelay,
                },
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
        // Fresh install: walk the new admin through shop setup once.
        _requiresShopSetup = true;
        _analyticsEngine?.setCurrentUser(user.id);
        notifyListeners();
        return true;
      case Error<PosUser>(exception: _):
        _currentUser = null;
        _status = await _resolveUnauthenticatedStatus(retryOnFailure: true);
        _hasError = _status == AuthStatus.setupRequired;
        notifyListeners();
        return false;
    }
  }

  Future<void>? _logoutInFlight;

  /// Signs out. A call made while a sign-out is already running joins it.
  ///
  /// A till's touchscreen can deliver one press twice — the field saw the
  /// logout button fire twice 40 ms apart — and two sign-outs interleaved used
  /// to leave the app signed in with nobody signed in, which the auth gate
  /// could not draw: the stack overflowed and the app restarted.
  Future<void> logout() {
    return _logoutInFlight ??= _logout().whenComplete(() {
      _logoutInFlight = null;
    });
  }

  Future<void> _logout() async {
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

    final status = await _resolveUnauthenticatedStatus();
    // The user and the status change in the same step: a rebuild in between
    // would find "authenticated" with no user to build the shell for.
    _isSubmitting = false;
    _currentUser = null;
    _requiresShopSetup = false;
    _status = status;
    notifyListeners();
  }
}
