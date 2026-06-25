import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/ai_chat.dart';
import '../../../data/models/relay_installation_status.dart';
import '../../../data/repositories/subscription_repository.dart';

/// Drives the subscription status page: loads the relay installation snapshot
/// (installation ID + remote-access/AI entitlements) and, when AI is entitled,
/// the current usage windows. [sync] additionally refreshes the entitlement
/// state from the relay control server.
class SubscriptionStatusViewModel extends ChangeNotifier {
  SubscriptionStatusViewModel(this._repository);

  final SubscriptionRepository _repository;

  RelayInstallationStatus? _status;
  AiUsage? _usage;
  bool _isLoading = false;
  bool _isSyncing = false;
  bool _hasLoadError = false;
  bool _lastSyncFailed = false;

  RelayInstallationStatus? get status => _status;
  AiUsage? get usage => _usage;
  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing;
  bool get isBusy => _isLoading || _isSyncing;
  bool get hasLoadError => _hasLoadError;

  /// True after a [sync] that reached the backend but failed to refresh from the
  /// relay (e.g. the relay was unreachable). The cached snapshot is still shown.
  bool get lastSyncFailed => _lastSyncFailed;

  /// Initial load — reads the cached snapshot without hitting the relay server,
  /// so it always resolves even when the relay is offline.
  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    _lastSyncFailed = false;
    notifyListeners();

    final result = await _repository.loadStatus();
    switch (result) {
      case Ok<RelayInstallationStatus>(value: final status):
        _status = status;
      case Error<RelayInstallationStatus>():
        _hasLoadError = true;
    }

    await _refreshUsage();

    _isLoading = false;
    notifyListeners();
  }

  /// Re-fetches the snapshot with a relay-server sync. Returns false (and keeps
  /// the cached snapshot) when the relay could not be reached.
  Future<bool> sync() async {
    if (_isSyncing) {
      return false;
    }
    _isSyncing = true;
    _lastSyncFailed = false;
    notifyListeners();

    final result = await _repository.loadStatus(sync: true);
    var ok = false;
    switch (result) {
      case Ok<RelayInstallationStatus>(value: final status):
        _status = status;
        _hasLoadError = false;
        ok = true;
      case Error<RelayInstallationStatus>():
        _lastSyncFailed = true;
    }

    await _refreshUsage();

    _isSyncing = false;
    notifyListeners();
    return ok;
  }

  /// Loads AI usage only when the snapshot says AI is entitled; otherwise clears
  /// it. A usage fetch failure is non-fatal — the page just omits the bars.
  Future<void> _refreshUsage() async {
    if (_status?.aiAvailable != true) {
      _usage = null;
      return;
    }
    final result = await _repository.loadAiUsage();
    switch (result) {
      case Ok<AiUsage>(value: final usage):
        _usage = usage;
      case Error<AiUsage>():
        _usage = null;
    }
  }
}
