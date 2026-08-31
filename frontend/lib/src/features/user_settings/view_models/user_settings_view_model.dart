import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/password_policy.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/services/api_session.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/employee_repository.dart';

/// Why a password change was refused. Each one needs different words: a wrong
/// current password is a typo in a different field, a rule failure points at the
/// checklist, and a throttle is "wait", not "wrong".
enum PasswordChangeFailure {
  none,
  currentPasswordWrong,
  ruleRejected,
  throttled,
  unknown,
}

/// Which profile field the server rejected, so the message lands on the field
/// instead of in a banner that does not say where to look.
enum ProfileFieldIssue { none, usernameTaken, emailInvalid, other }

class UserSettingsViewModel extends ChangeNotifier {
  UserSettingsViewModel(
    this._authRepository,
    this._employeeRepository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine;

  final AuthRepository _authRepository;
  final EmployeeRepository _employeeRepository;
  final AnalyticsEngine? _analyticsEngine;

  PosUser? _currentUser;
  Employee? _employee;
  List<EmployeeLoan> _loans = [];
  bool _isLoadingLoans = false;
  bool _isSavingProfile = false;
  bool _isChangingPassword = false;
  bool _isRequestingLoan = false;
  bool _hasLoanLoadError = false;
  bool _hasProfileSaveError = false;
  bool _hasPasswordChangeError = false;
  bool _hasLoanRequestError = false;
  ProfileFieldIssue _profileIssue = ProfileFieldIssue.none;
  PasswordChangeFailure _passwordFailure = PasswordChangeFailure.none;
  // Until the policy call answers, the shipped configuration stands in — a
  // checklist from a stale default beats the blank field that prompted this.
  PasswordPolicy _passwordPolicy = PasswordPolicy.fallback;
  String _newPassword = '';
  Set<PasswordRequirement> _serverFailures = const {};

  PosUser? get currentUser => _currentUser;
  Employee? get employee => _employee;
  List<EmployeeLoan> get loans => List.unmodifiable(_loans);
  bool get hasEmployeeRecord => _employee != null;
  bool get isLoadingLoans => _isLoadingLoans;
  bool get isSavingProfile => _isSavingProfile;
  bool get isChangingPassword => _isChangingPassword;
  bool get isRequestingLoan => _isRequestingLoan;
  bool get hasLoanLoadError => _hasLoanLoadError;
  bool get hasProfileSaveError => _hasProfileSaveError;
  bool get hasPasswordChangeError => _hasPasswordChangeError;
  bool get hasLoanRequestError => _hasLoanRequestError;
  ProfileFieldIssue get profileIssue => _profileIssue;
  PasswordChangeFailure get passwordFailure => _passwordFailure;
  PasswordPolicy get passwordPolicy => _passwordPolicy;

  /// How the password being typed measures up. Only the *requirements* half can
  /// block the submit — the advice is shown, never enforced, because staff here
  /// sign in dozens of times a shift and will pick a short PIN regardless.
  PasswordAssessment get passwordAssessment => assessPassword(
    password: _newPassword,
    policy: _passwordPolicy,
    owner: _owner,
    serverFailures: _serverFailures,
  );

  bool get canChangePassword =>
      !_isChangingPassword &&
      _newPassword.isNotEmpty &&
      passwordAssessment.meetsRequirements;

  PasswordOwner get _owner {
    final user = _currentUser;
    if (user == null) return const PasswordOwner();
    return PasswordOwner(
      username: user.username,
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
    );
  }

  /// The password being drafted. Held here so the checklist, the submit gate and
  /// the server's verdict all read the same value.
  void setNewPassword(String value) {
    _newPassword = value;
    // The server's verdict described the previous value; keeping it would mark
    // a rule red against a password that no longer exists.
    if (_serverFailures.isNotEmpty ||
        _passwordFailure != PasswordChangeFailure.none) {
      _serverFailures = const {};
      _passwordFailure = PasswordChangeFailure.none;
      _hasPasswordChangeError = false;
    }
    notifyListeners();
  }

  Future<void> loadPasswordPolicy() async {
    final result = await _authRepository.loadPasswordPolicy();
    if (result case Ok<PasswordPolicy>(value: final policy)) {
      _passwordPolicy = policy;
      notifyListeners();
    }
  }

  void setCurrentUser(PosUser user) {
    final shouldLoadLoans = _currentUser?.id != user.id;
    _currentUser = user;
    notifyListeners();
    if (shouldLoadLoans) {
      unawaited(loadMyLoans());
      unawaited(loadPasswordPolicy());
    }
  }

  Future<void> loadMyLoans() async {
    _isLoadingLoans = true;
    _hasLoanLoadError = false;
    notifyListeners();

    final result = await _employeeRepository.loadMyEmployeeLoans();
    switch (result) {
      case Ok<MyEmployeeLoans>(value: final summary):
        _employee = summary.employee;
        _loans = summary.loans;
      case Error<MyEmployeeLoans>():
        _hasLoanLoadError = true;
    }

    _isLoadingLoans = false;
    notifyListeners();
  }

  Future<PosUser?> updateProfile(CurrentUserProfileDraft draft) async {
    _isSavingProfile = true;
    _hasProfileSaveError = false;
    _profileIssue = ProfileFieldIssue.none;
    notifyListeners();

    final result = await _authRepository.updateCurrentUser(draft);
    _isSavingProfile = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _currentUser = user;
        _track('settings.user.profile.updated', 'user', user.id);
        notifyListeners();
        return user;
      case Error<PosUser>(exception: final exception):
        _hasProfileSaveError = true;
        _profileIssue = _profileIssueFrom(exception);
        notifyListeners();
        return null;
    }
  }

  /// Which field the server rejected. Keyed on the field name in the body, not
  /// on the message text: the messages are English (the backend runs with
  /// LANGUAGE_CODE en-us) and the UI is Arabic, so only the key travels well.
  static ProfileFieldIssue _profileIssueFrom(Exception exception) {
    if (exception is! PosApiException || exception.statusCode != 400) {
      return ProfileFieldIssue.other;
    }
    final body = exception.decodedBody;
    if (body is! Map) return ProfileFieldIssue.other;
    // The username is required client-side already, so a username error that
    // reaches here is in practice the uniqueness check.
    if (body.containsKey('username')) return ProfileFieldIssue.usernameTaken;
    if (body.containsKey('email')) return ProfileFieldIssue.emailInvalid;
    return ProfileFieldIssue.other;
  }

  Future<bool> changePassword(PasswordChangeDraft draft) async {
    _isChangingPassword = true;
    _hasPasswordChangeError = false;
    _passwordFailure = PasswordChangeFailure.none;
    _serverFailures = const {};
    notifyListeners();

    final result = await _authRepository.changePassword(draft);
    _isChangingPassword = false;
    switch (result) {
      case Ok<void>():
        final user = _currentUser;
        if (user != null) {
          _track('settings.user.password.changed', 'user', user.id);
        }
        _newPassword = '';
        notifyListeners();
        return true;
      case Error<void>(exception: final exception):
        _hasPasswordChangeError = true;
        _applyPasswordFailure(exception);
        notifyListeners();
        return false;
    }
  }

  void _applyPasswordFailure(Exception exception) {
    if (exception is! PosApiException) {
      _passwordFailure = PasswordChangeFailure.unknown;
      return;
    }
    if (exception.statusCode == 429) {
      // The endpoint verifies the current password, so it is rate limited. That
      // is "wait", not "wrong" — saying "incorrect" here would send someone
      // hunting a password that was fine.
      _passwordFailure = PasswordChangeFailure.throttled;
      return;
    }
    final body = exception.decodedBody;
    if (exception.statusCode != 400 || body is! Map) {
      _passwordFailure = PasswordChangeFailure.unknown;
      return;
    }
    if (body.containsKey('current_password')) {
      _passwordFailure = PasswordChangeFailure.currentPasswordWrong;
      return;
    }
    final codes = body['codes'];
    if (codes is List) {
      _serverFailures = codes
          .map((code) => passwordRequirementFromServerCode(code.toString()))
          .whereType<PasswordRequirement>()
          .toSet();
    }
    _passwordFailure = _serverFailures.isEmpty
        ? PasswordChangeFailure.unknown
        : PasswordChangeFailure.ruleRejected;
  }

  Future<bool> requestLoan(EmployeeLoanRequestDraft draft) async {
    _isRequestingLoan = true;
    _hasLoanRequestError = false;
    notifyListeners();

    final result = await _employeeRepository.requestEmployeeLoan(draft);
    _isRequestingLoan = false;
    switch (result) {
      case Ok<EmployeeLoan>(value: final loan):
        _loans = [loan, ..._loans];
        _track('settings.user.loan.requested', 'employee_loan', loan.id);
        notifyListeners();
        return true;
      case Error<EmployeeLoan>():
        _hasLoanRequestError = true;
        notifyListeners();
        return false;
    }
  }

  void _track(String name, String entityType, int entityId) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: entityType,
      entityId: entityId,
      attributes: {'source': 'user_settings'},
    );
  }
}
