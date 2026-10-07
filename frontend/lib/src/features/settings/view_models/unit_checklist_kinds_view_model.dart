import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/unit_checklist_kind.dart';
import '../../../data/repositories/tracked_stock_repository.dart';

/// The first screen of «قوائم فحص الأجهزة»: every kind of device the shop
/// takes in, with how long each one's intake checklist is.
class UnitChecklistKindsViewModel extends ChangeNotifier {
  UnitChecklistKindsViewModel(this.repository);

  final TrackedStockRepository repository;

  List<UnitChecklistKind> _kinds = const [];
  bool _isLoading = false;
  Object? _loadError;
  bool _disposed = false;

  List<UnitChecklistKind> get kinds => _kinds;
  bool get isLoading => _isLoading;

  /// Set when the last load failed; the list keeps what it had before.
  Object? get loadError => _loadError;

  Future<void> load() async {
    _isLoading = true;
    _loadError = null;
    _notify();
    final result = await repository.loadChecklistKinds();
    switch (result) {
      case Ok<List<UnitChecklistKind>>(:final value):
        _kinds = value;
      case Error<List<UnitChecklistKind>>(:final exception):
        _loadError = exception;
    }
    _isLoading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
