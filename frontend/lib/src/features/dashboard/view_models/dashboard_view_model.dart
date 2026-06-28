import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/dashboard.dart';
import '../../../data/models/dashboard_ai_digest.dart';
import '../../../data/repositories/dashboard_repository.dart';

class DashboardViewModel extends ChangeNotifier {
  DashboardViewModel(this._dashboardRepository) {
    loadDashboard();
  }

  final DashboardRepository _dashboardRepository;

  DashboardSnapshot? _snapshot;
  int _selectedDays = 30;
  bool _isLoading = false;
  bool _hasError = false;
  DashboardAiDigest _aiDigest = DashboardAiDigest.empty;
  bool _isDigestLoading = false;

  DashboardSnapshot? get snapshot => _snapshot;
  int get selectedDays => _selectedDays;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;

  /// The inline AI text (brief + per-card explainers). Empty until it loads, or
  /// when the shop has no AI entitlement / nothing to narrate.
  DashboardAiDigest get aiDigest => _aiDigest;
  bool get isDigestLoading => _isDigestLoading;

  Future<void> loadDashboard() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _dashboardRepository.loadDashboard(
      days: _selectedDays,
    );
    switch (result) {
      case Ok<DashboardSnapshot>(value: final snapshot):
        _snapshot = snapshot;
      case Error<DashboardSnapshot>(exception: _):
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();

    // The AI digest is a separate, non-blocking call so the dashboard paints
    // immediately and the inline AI text fills in when ready. A failure (no AI
    // entitlement, relay hiccup) just leaves it empty — never an error.
    if (_snapshot != null) {
      unawaited(_loadAiDigest());
    }
  }

  Future<void> _loadAiDigest() async {
    final days = _selectedDays;
    _isDigestLoading = true;
    notifyListeners();

    final result = await _dashboardRepository.loadAiDigest(days: days);
    // A period change mid-flight supersedes this result — drop it.
    if (days != _selectedDays) {
      return;
    }
    _aiDigest = switch (result) {
      Ok<DashboardAiDigest>(value: final digest) => digest,
      Error<DashboardAiDigest>() => DashboardAiDigest.empty,
    };
    _isDigestLoading = false;
    notifyListeners();
  }

  Future<void> changePeriod(int days) async {
    if (_selectedDays == days || _isLoading) {
      return;
    }
    _selectedDays = days;
    // Drop the previous period's digest so its text never lingers over the new
    // period's numbers; loadDashboard regenerates it for the new range.
    _aiDigest = DashboardAiDigest.empty;
    await loadDashboard();
  }
}
