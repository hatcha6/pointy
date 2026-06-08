import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/employee_repository.dart';

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

  void setCurrentUser(PosUser user) {
    final shouldLoadLoans = _currentUser?.id != user.id;
    _currentUser = user;
    notifyListeners();
    if (shouldLoadLoans) {
      unawaited(loadMyLoans());
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
    notifyListeners();

    final result = await _authRepository.updateCurrentUser(draft);
    _isSavingProfile = false;
    switch (result) {
      case Ok<PosUser>(value: final user):
        _currentUser = user;
        _track('settings.user.profile.updated', 'user', user.id);
        notifyListeners();
        return user;
      case Error<PosUser>():
        _hasProfileSaveError = true;
        notifyListeners();
        return null;
    }
  }

  Future<bool> changePassword(PasswordChangeDraft draft) async {
    _isChangingPassword = true;
    _hasPasswordChangeError = false;
    notifyListeners();

    final result = await _authRepository.changePassword(draft);
    _isChangingPassword = false;
    switch (result) {
      case Ok<void>():
        final user = _currentUser;
        if (user != null) {
          _track('settings.user.password.changed', 'user', user.id);
        }
        notifyListeners();
        return true;
      case Error<void>():
        _hasPasswordChangeError = true;
        notifyListeners();
        return false;
    }
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
