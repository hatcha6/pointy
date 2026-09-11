import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/barcode/scale_barcode.dart';

/// Drives the scale-label settings screen.
///
/// Loads every rule (active and not) and writes through the repository, which
/// drops the till's cached rules on every write — a rule that has been changed
/// but is still being used to read stickers is the one thing this screen must
/// never leave behind.
class ScaleRulesViewModel extends ChangeNotifier {
  ScaleRulesViewModel(this._repository);

  final CatalogRepository _repository;

  List<ScaleBarcodeRule> _rules = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  String _errorMessage = '';

  List<ScaleBarcodeRule> get rules => _rules;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  String get errorMessage => _errorMessage;

  /// The rules in the order the till will try them, so the screen shows the
  /// shop the sequence it will actually get rather than the one it typed.
  List<ScaleBarcodeRule> get orderedRules => orderScaleRules(_rules);

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();
    final result = await _repository.loadScaleBarcodeRules(activeOnly: false);
    switch (result) {
      case Ok<List<ScaleBarcodeRule>>(:final value):
        _rules = value;
      case Error<List<ScaleBarcodeRule>>():
        _hasLoadError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> save({int? id, required Map<String, Object?> draft}) async {
    _isMutating = true;
    _errorMessage = '';
    notifyListeners();
    final result = await _repository.saveScaleBarcodeRule(id: id, draft: draft);
    _isMutating = false;
    switch (result) {
      case Ok<ScaleBarcodeRule>():
        notifyListeners();
        await load();
        return true;
      case Error<ScaleBarcodeRule>(:final exception):
        _errorMessage = exception.toString();
        notifyListeners();
        return false;
    }
  }

  Future<bool> remove(int id) async {
    _isMutating = true;
    _errorMessage = '';
    notifyListeners();
    final result = await _repository.deleteScaleBarcodeRule(id);
    _isMutating = false;
    switch (result) {
      case Ok<void>():
        await load();
        return true;
      case Error<void>(:final exception):
        _errorMessage = exception.toString();
        notifyListeners();
        return false;
    }
  }
}
