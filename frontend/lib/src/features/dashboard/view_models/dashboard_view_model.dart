import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/dashboard.dart';
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

  DashboardSnapshot? get snapshot => _snapshot;
  int get selectedDays => _selectedDays;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;

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
  }

  Future<void> changePeriod(int days) async {
    if (_selectedDays == days || _isLoading) {
      return;
    }
    _selectedDays = days;
    await loadDashboard();
  }
}
