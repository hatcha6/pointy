import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/messaging_gateway.dart';
import '../../../data/repositories/messaging_repository.dart';

enum MessagingTestOutcome { none, sending, success, failure }

/// Drives the SMS device settings page: loads the shop's default messaging
/// gateway (the SMS Gate phone), edits its connection + pacing config, saves
/// (create or update), and runs a Test-send. A single default gateway is managed
/// here for the common case; the endpoints support multiple.
class MessagingSettingsViewModel extends ChangeNotifier {
  MessagingSettingsViewModel(this._repository);

  final MessagingRepository _repository;

  MessagingGateway? _gateway;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;
  MessagingTestOutcome _testOutcome = MessagingTestOutcome.none;
  String _testMessage = '';
  bool _isActivating = false;

  // Editable form state.
  String baseUrl = '';
  String username = '';
  String password = ''; // a new secret; blank = keep the stored one
  int maxMessagesPerMinute = 6;
  int dailyCap = 0;

  MessagingGateway? get gateway => _gateway;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasLoadError => _hasLoadError;
  bool get hasSaveError => _hasSaveError;
  bool get hasGateway => _gateway != null;
  bool get isConfigured => _gateway?.isConfigured ?? false;
  MessagingTestOutcome get testOutcome => _testOutcome;
  String get testMessage => _testMessage;
  bool get isTesting => _testOutcome == MessagingTestOutcome.sending;
  bool get isActivating => _isActivating;
  bool get isBusy => _isLoading || _isSaving || isTesting || _isActivating;

  /// Can Test-send: only a saved, configured gateway with no unsaved edits can
  /// be exercised (Test-send hits the persisted config on the server).
  bool get canTest => _gateway != null && isConfigured && !isBusy;

  /// Can auto-activate: a saved, configured gateway (activation registers the
  /// device webhooks and makes this the active default).
  bool get canActivate => _gateway != null && isConfigured && !isBusy;

  bool get canSave =>
      baseUrl.trim().isNotEmpty &&
      !isBusy &&
      (_gateway?.hasPassword == true || password.isNotEmpty);

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadGateways();
    switch (result) {
      case Ok<List<MessagingGateway>>(value: final gateways):
        _applyGateway(_pickDefault(gateways));
      case Error<List<MessagingGateway>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Zero-touch activation: registers the device webhooks and makes this the
  /// active default. Returns the outcome, then reloads to reflect the new state.
  Future<GatewayActivation?> activate() async {
    final gateway = _gateway;
    if (gateway == null) return null;
    _isActivating = true;
    notifyListeners();

    final result = await _repository.activate(gateway.id);
    GatewayActivation? activation;
    switch (result) {
      case Ok<GatewayActivation>(value: final value):
        activation = value;
      case Error<GatewayActivation>():
        activation = null;
    }

    _isActivating = false;
    notifyListeners();
    if (activation != null) {
      await load();
    }
    return activation;
  }

  MessagingGateway? _pickDefault(List<MessagingGateway> gateways) {
    if (gateways.isEmpty) return null;
    return gateways.firstWhere(
      (gateway) => gateway.isDefault,
      orElse: () => gateways.first,
    );
  }

  void _applyGateway(MessagingGateway? gateway) {
    _gateway = gateway;
    baseUrl = gateway?.baseUrl ?? '';
    username = gateway?.username ?? '';
    password = '';
    maxMessagesPerMinute = gateway?.maxMessagesPerMinute ?? 6;
    dailyCap = gateway?.dailyCap ?? 0;
    _testOutcome = MessagingTestOutcome.none;
    _testMessage = '';
  }

  void setBaseUrl(String value) {
    baseUrl = value.trim();
    notifyListeners();
  }

  void setUsername(String value) {
    username = value;
    notifyListeners();
  }

  void setPassword(String value) {
    password = value;
    notifyListeners();
  }

  void setMaxMessagesPerMinute(int value) {
    maxMessagesPerMinute = value < 0 ? 0 : value;
    notifyListeners();
  }

  void setDailyCap(int value) {
    dailyCap = value < 0 ? 0 : value;
    notifyListeners();
  }

  Future<bool> save() async {
    if (!canSave) return false;
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final existing = _gateway;
    final draft = MessagingGatewayDraft(
      name: (existing != null && existing.name.isNotEmpty)
          ? existing.name
          : 'هاتف الرسائل',
      provider: existing?.provider ?? MessagingProvider.smsGate,
      baseUrl: baseUrl.trim(),
      username: username.trim(),
      password: password.isEmpty ? null : password,
      isDefault: true,
      isActive: true,
      maxMessagesPerMinute: maxMessagesPerMinute,
      dailyCap: dailyCap,
    );

    final Result<MessagingGateway> result = existing == null
        ? await _repository.createGateway(draft)
        : await _repository.updateGateway(existing.id, draft);

    var ok = false;
    switch (result) {
      case Ok<MessagingGateway>(value: final saved):
        _applyGateway(saved);
        ok = true;
      case Error<MessagingGateway>():
        _hasSaveError = true;
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  Future<void> sendTest(String phone) async {
    final gateway = _gateway;
    if (gateway == null || phone.trim().isEmpty) return;
    _testOutcome = MessagingTestOutcome.sending;
    _testMessage = '';
    notifyListeners();

    final result = await _repository.testSend(id: gateway.id, to: phone.trim());
    switch (result) {
      case Ok<MessagingSendResult>(value: final sendResult):
        if (sendResult.ok) {
          _testOutcome = MessagingTestOutcome.success;
          _testMessage = '';
        } else {
          _testOutcome = MessagingTestOutcome.failure;
          _testMessage = sendResult.errorDetail.isNotEmpty
              ? sendResult.errorDetail
              : sendResult.errorCode;
        }
      case Error<MessagingSendResult>():
        _testOutcome = MessagingTestOutcome.failure;
        _testMessage = '';
    }
    notifyListeners();
  }
}
