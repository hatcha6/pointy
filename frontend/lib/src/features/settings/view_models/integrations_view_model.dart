import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/integration_card.dart';
import '../../../data/models/integration_provider.dart';
import '../../../data/repositories/integrations_repository.dart';

/// What the screen is doing to one provider right now. Scoped to a single
/// provider key rather than to the page, so testing HD Box never greys out
/// the rest of the list.
enum IntegrationBusyKind { none, saving, probing, disconnecting }

/// Drives Shop Settings → Integrations: loads the provider catalog with the
/// shop's accounts merged in, saves credentials, tests a connection, and
/// disconnects.
///
/// The catalog is always whole — planned providers included — so the page can
/// show what is coming rather than only what happens to work today. Errors are
/// kept as exceptions and localized at the view, the way the rest of Settings
/// does it.
class IntegrationsViewModel extends ChangeNotifier {
  IntegrationsViewModel(this._repository);

  final IntegrationsRepository _repository;

  List<IntegrationProvider> _providers = const [];
  bool _isLoading = false;
  bool _hasLoadError = false;
  String? _busyProviderKey;
  IntegrationBusyKind _busyKind = IntegrationBusyKind.none;
  Exception? _actionException;
  IntegrationProbeResult? _lastProbe;
  String? _lastProbeProviderKey;

  List<IntegrationProvider> get providers => _providers;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;

  /// The provider currently being saved/tested/disconnected, if any.
  String? get busyProviderKey => _busyProviderKey;
  IntegrationBusyKind get busyKind => _busyKind;

  /// A failed *request* (network, permission). A provider merely saying "no"
  /// is not this — that arrives as [lastProbe] with `ok == false`.
  Exception? get actionException => _actionException;

  IntegrationProbeResult? get lastProbe => _lastProbe;
  String? get lastProbeProviderKey => _lastProbeProviderKey;

  bool isBusy(IntegrationProviderKey key) =>
      _busyProviderKey != null &&
      _busyProviderKey == integrationProviderKeyToJson(key);

  IntegrationProvider? providerFor(IntegrationProviderKey key) {
    for (final provider in _providers) {
      if (provider.key == key) return provider;
    }
    return null;
  }

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadProviders();
    switch (result) {
      case Ok<List<IntegrationProvider>>(value: final providers):
        _providers = providers;
      case Error<List<IntegrationProvider>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> saveCredentials(
    IntegrationProviderKey key,
    IntegrationCredentialsDraft draft,
  ) {
    return _run(
      key,
      IntegrationBusyKind.saving,
      (providerKey) => _repository.saveCredentials(providerKey, draft),
    );
  }

  Future<bool> disconnect(IntegrationProviderKey key) {
    return _run(key, IntegrationBusyKind.disconnecting, _repository.disconnect);
  }

  /// Test the stored credentials. The returned bool is whether the *request*
  /// worked; read [lastProbe] for what the provider actually said.
  Future<bool> probe(IntegrationProviderKey key) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return false;

    _beginBusy(providerKey, IntegrationBusyKind.probing);
    final result = await _repository.probe(providerKey);
    var ok = false;
    switch (result) {
      case Ok<IntegrationProbeResult>(value: final probe):
        _lastProbe = probe;
        _lastProbeProviderKey = providerKey;
        final refreshed = probe.provider;
        if (refreshed != null) {
          _replaceProvider(refreshed);
        }
        ok = true;
      case Error<IntegrationProbeResult>(exception: final exception):
        _actionException = exception;
    }
    _endBusy();
    return ok;
  }

  /// Clear the result banner once the page has shown it.
  void acknowledgeResult() {
    if (_lastProbe == null && _actionException == null) return;
    _lastProbe = null;
    _lastProbeProviderKey = null;
    _actionException = null;
    notifyListeners();
  }

  Future<bool> _run(
    IntegrationProviderKey key,
    IntegrationBusyKind kind,
    Future<Result<IntegrationProvider>> Function(String providerKey) action,
  ) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return false;

    _beginBusy(providerKey, kind);
    final result = await action(providerKey);
    var ok = false;
    switch (result) {
      case Ok<IntegrationProvider>(value: final provider):
        _replaceProvider(provider);
        ok = true;
      case Error<IntegrationProvider>(exception: final exception):
        _actionException = exception;
    }
    _endBusy();
    return ok;
  }

  void _beginBusy(String providerKey, IntegrationBusyKind kind) {
    _busyProviderKey = providerKey;
    _busyKind = kind;
    _actionException = null;
    _lastProbe = null;
    _lastProbeProviderKey = null;
    notifyListeners();
  }

  void _endBusy() {
    _busyProviderKey = null;
    _busyKind = IntegrationBusyKind.none;
    notifyListeners();
  }

  void _replaceProvider(IntegrationProvider updated) {
    _providers = [
      for (final provider in _providers)
        if (provider.key == updated.key) updated else provider,
    ];
  }

  // --- confirming this device with the provider ----------------------------
  // One-shot calls the verification sheet drives step by step. Each answers
  // null when the *request* failed ([actionException] says why); a provider
  // saying no is a result with `ok == false`, rendered by the sheet.

  Future<IntegrationVerificationChallenge?> startVerification(
    IntegrationProviderKey key,
  ) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return null;
    final result = await _repository.startVerification(providerKey);
    return _valueOrRecord(result);
  }

  Future<IntegrationVerificationStep?> sendVerificationCode(
    IntegrationProviderKey key, {
    required String challengeRef,
    required String answer,
  }) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return null;
    final result = await _repository.sendVerificationCode(
      providerKey,
      challengeRef: challengeRef,
      answer: answer,
    );
    return _valueOrRecord(result);
  }

  Future<IntegrationVerificationStep?> confirmVerification(
    IntegrationProviderKey key, {
    required String code,
  }) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return null;
    final result = await _repository.confirmVerification(
      providerKey,
      code: code,
    );
    final step = _valueOrRecord(result);
    final refreshed = step?.provider;
    if (refreshed != null) {
      _replaceProvider(refreshed);
      notifyListeners();
    }
    return step;
  }

  // --- which profile (shop) the provider login buys as -----------------------
  Future<IntegrationProfileList?> loadProfiles(
    IntegrationProviderKey key,
  ) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return null;
    return _valueOrRecord(await _repository.loadProfiles(providerKey));
  }

  Future<bool> chooseProfile(
    IntegrationProviderKey key,
    String profileId,
  ) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return false;
    final result = await _repository.chooseProfile(providerKey, profileId);
    switch (result) {
      case Ok<IntegrationProvider?>(value: final provider):
        if (provider != null) {
          _replaceProvider(provider);
          notifyListeners();
        }
        return true;
      case Error<IntegrationProvider?>(exception: final exception):
        _actionException = exception;
        notifyListeners();
        return false;
    }
  }

  T? _valueOrRecord<T>(Result<T> result) {
    switch (result) {
      case Ok<T>(value: final value):
        return value;
      case Error<T>(exception: final exception):
        _actionException = exception;
        notifyListeners();
        return null;
    }
  }

  // --- the owner's retail price list --------------------------------------
  IntegrationPriceList? _priceList;
  bool _isLoadingPrices = false;
  bool _isSavingPrices = false;

  IntegrationPriceList? get priceList => _priceList;
  bool get isLoadingPrices => _isLoadingPrices;
  bool get isSavingPrices => _isSavingPrices;

  Future<void> loadPrices(IntegrationProviderKey key) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return;

    _isLoadingPrices = true;
    _priceList = null;
    notifyListeners();

    final result = await _repository.loadPrices(providerKey);
    switch (result) {
      case Ok<IntegrationPriceList>(value: final list):
        _priceList = list;
      case Error<IntegrationPriceList>(exception: final exception):
        _actionException = exception;
    }
    _isLoadingPrices = false;
    notifyListeners();
  }

  /// Save the prices the owner changed. Returns whether the call worked.
  Future<bool> savePrices(
    IntegrationProviderKey key,
    Map<String, double?> prices,
  ) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty || prices.isEmpty) return true;

    _isSavingPrices = true;
    _actionException = null;
    notifyListeners();

    final result = await _repository.savePrices(providerKey, prices);
    var ok = false;
    switch (result) {
      case Ok<IntegrationPriceList>(value: final list):
        _priceList = list;
        ok = true;
      case Error<IntegrationPriceList>(exception: final exception):
        _actionException = exception;
    }
    _isSavingPrices = false;
    notifyListeners();
    return ok;
  }

  // --- the provider float --------------------------------------------------
  IntegrationFloat? _float;
  bool _isLoadingFloat = false;
  bool _isSavingTopUp = false;

  IntegrationFloat? get providerFloat => _float;
  bool get isLoadingFloat => _isLoadingFloat;
  bool get isSavingTopUp => _isSavingTopUp;

  Future<void> loadFloat(IntegrationProviderKey key) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return;

    _isLoadingFloat = true;
    _float = null;
    notifyListeners();

    final result = await _repository.loadFloat(providerKey);
    switch (result) {
      case Ok<IntegrationFloat>(value: final value):
        _float = value;
      case Error<IntegrationFloat>(exception: final exception):
        _actionException = exception;
    }
    _isLoadingFloat = false;
    notifyListeners();
  }

  Future<bool> recordTopUp(
    IntegrationProviderKey key, {
    required double amount,
    int? fromAccountId,
    String reference = '',
    String note = '',
  }) async {
    final providerKey = integrationProviderKeyToJson(key);
    if (providerKey.isEmpty) return false;

    _isSavingTopUp = true;
    _actionException = null;
    notifyListeners();

    final result = await _repository.recordTopUp(
      providerKey,
      amount: amount,
      fromAccountId: fromAccountId,
      reference: reference,
      note: note,
    );
    var ok = false;
    switch (result) {
      case Ok<IntegrationFloat>(value: final value):
        _float = value;
        ok = true;
      case Error<IntegrationFloat>(exception: final exception):
        _actionException = exception;
    }
    _isSavingTopUp = false;
    notifyListeners();
    return ok;
  }
}
