import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/factory_reset.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/api_error_detail.dart';

/// Drives the danger zone: load what a reset would take, then take it.
///
/// Its own view model rather than more surface on [ShopSettingsViewModel],
/// which already carries the settings form, the telemetry export and the
/// backups. The reset is the one screen in the app where a stale flag from an
/// unrelated operation could be read as "safe to press", so it gets state
/// nothing else writes to.
class FactoryResetViewModel extends ChangeNotifier {
  FactoryResetViewModel(this._repository);

  final ShopSettingsRepository _repository;

  FactoryResetPreview? _preview;
  bool _isLoading = false;
  bool _isResetting = false;
  bool _hasLoadError = false;
  String? _failureMessage;

  FactoryResetPreview? get preview => _preview;
  bool get isLoading => _isLoading;
  bool get isResetting => _isResetting;
  bool get hasLoadError => _hasLoadError;

  /// The server's own reason for refusing the last attempt — a wrong password,
  /// a shop name that does not match. Shown verbatim: the backend words these
  /// in Arabic and it knows which of the two failed, which the client does not.
  String? get failureMessage => _failureMessage;

  Future<void> loadPreview() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadFactoryResetPreview();
    _isLoading = false;
    switch (result) {
      case Ok<FactoryResetPreview>():
        _preview = result.value;
      case Error<FactoryResetPreview>():
        _hasLoadError = true;
    }
    notifyListeners();
  }

  /// Returns true only when the shop was actually emptied.
  ///
  /// A false here is a refusal, not a partial reset: both checks run before
  /// anything is deleted, and the delete itself is one transaction.
  Future<bool> reset({
    required String password,
    required String confirmation,
  }) async {
    _isResetting = true;
    _failureMessage = null;
    notifyListeners();

    final result = await _repository.performFactoryReset(
      password: password,
      confirmation: confirmation,
    );
    _isResetting = false;

    switch (result) {
      case Ok<FactoryResetOutcome>():
        notifyListeners();
        return true;
      case Error<FactoryResetOutcome>():
        final detail = apiErrorDetail(result.exception);
        _failureMessage = detail.isEmpty ? null : detail;
        notifyListeners();
        return false;
    }
  }
}
