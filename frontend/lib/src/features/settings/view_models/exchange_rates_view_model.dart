import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/exchange_rate.dart';
import '../../../data/repositories/fx_repository.dart';
import '../../../shared/formatters.dart';

/// Drives the exchange-rates page: the current rates with their provenance, the
/// repricing proposals a rate move has produced, and the two write actions
/// (typing a rate, applying a reprice).
///
/// The load path is deliberately forgiving. Rates are reference data that a shop
/// can be missing entirely — a relay that has never been reachable, a
/// subscription that does not include the feed — and none of that is an error
/// worth blocking the screen on. What must never happen is a blank screen that
/// implies the shop has no rates when it has stale ones.
class ExchangeRatesViewModel extends ChangeNotifier {
  ExchangeRatesViewModel(this._repository);

  final FxRepository _repository;

  CurrentRates _rates = CurrentRates.empty;
  List<Currency> _currencies = const <Currency>[];
  RepricePreview _preview = RepricePreview.empty;
  final Set<int> _selectedVariantIds = <int>{};
  final Set<int> _selectedUnitIds = <int>{};

  bool _isLoading = false;
  bool _isSyncing = false;
  bool _isApplying = false;
  bool _hasLoadError = false;
  bool _lastSyncFailed = false;

  CurrentRates get rates => _rates;
  List<Currency> get currencies => _currencies;
  List<PriceProposal> get proposals => _preview.proposals;
  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing;
  bool get isApplying => _isApplying;
  bool get isBusy => _isLoading || _isSyncing || _isApplying;
  bool get hasLoadError => _hasLoadError;
  bool get lastSyncFailed => _lastSyncFailed;

  bool get hasRates => _rates.rates.isNotEmpty;
  bool get hasDrift => proposals.any((p) => !p.unpriceable);

  /// Currencies a rate can be entered for — everything except the shop's own.
  List<Currency> get quotableCurrencies => _currencies
      .where((c) => c.isEnabled && c.code != _rates.baseCode)
      .toList();

  bool isSelected(PriceProposal proposal) => proposal.kind == 'unit'
      ? _selectedUnitIds.contains(proposal.targetId)
      : _selectedVariantIds.contains(proposal.targetId);

  List<PriceProposal> get selectedProposals =>
      proposals.where(isSelected).toList();

  void toggle(PriceProposal proposal, bool selected) {
    final target = proposal.kind == 'unit'
        ? _selectedUnitIds
        : _selectedVariantIds;
    if (selected) {
      target.add(proposal.targetId);
    } else {
      target.remove(proposal.targetId);
    }
    notifyListeners();
  }

  void selectAll() {
    _selectedVariantIds.clear();
    _selectedUnitIds.clear();
    for (final proposal in proposals) {
      if (proposal.unpriceable) {
        continue;
      }
      (proposal.kind == 'unit' ? _selectedUnitIds : _selectedVariantIds).add(
        proposal.targetId,
      );
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedVariantIds.clear();
    _selectedUnitIds.clear();
    notifyListeners();
  }

  Future<void> load() => _load();

  /// [preserveSyncState] keeps the result of the sync that triggered this
  /// reload. Without it the refresh that follows a failed sync would wipe the
  /// very flag telling the owner the refresh did not land.
  Future<void> _load({bool preserveSyncState = false}) async {
    _isLoading = true;
    _hasLoadError = false;
    if (!preserveSyncState) {
      _lastSyncFailed = false;
    }
    notifyListeners();

    final ratesResult = await _repository.loadCurrentRates();
    switch (ratesResult) {
      case Ok<CurrentRates>(value: final loaded):
        _rates = loaded;
      case Error<CurrentRates>():
        _hasLoadError = true;
    }

    final currenciesResult = await _repository.loadCurrencies();
    if (currenciesResult case Ok<List<Currency>>(value: final loaded)) {
      _currencies = loaded;
      // Teach the formatters every symbol so a foreign price renders as "$"
      // rather than as a bare code the cashier has to decode.
      configureForeignCurrencySymbols(<String, String>{
        for (final currency in loaded) currency.code: currency.symbol,
      });
    }

    await _loadProposals();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadProposals() async {
    final result = await _repository.loadRepricePreview();
    if (result case Ok<RepricePreview>(value: final loaded)) {
      _preview = loaded;
      final rows = loaded.proposals;
      _selectedVariantIds.removeWhere(
        (id) => !rows.any((p) => p.kind != 'unit' && p.targetId == id),
      );
      _selectedUnitIds.removeWhere(
        (id) => !rows.any((p) => p.kind == 'unit' && p.targetId == id),
      );
    }
  }

  /// Pull from the relay now. A failure is soft — the shop keeps the rates it
  /// already has and is told the refresh did not land.
  Future<bool> syncNow() async {
    _isSyncing = true;
    _lastSyncFailed = false;
    notifyListeners();

    final result = await _repository.syncNow();
    var ok = false;
    switch (result) {
      case Ok<Map<String, Object?>>(value: final summary):
        // The endpoint answers 200 even when the relay was unreachable — that
        // is the soft no-op by design — so the payload, not the status, says
        // whether anything actually arrived.
        _lastSyncFailed = summary['error'] != null;
        ok = !_lastSyncFailed;
      case Error<Map<String, Object?>>():
        _lastSyncFailed = true;
    }

    _isSyncing = false;
    notifyListeners();
    await _load(preserveSyncState: true);
    return ok;
  }

  Future<bool> recordManualRate(ManualRateDraft draft) async {
    _isApplying = true;
    notifyListeners();
    final result = await _repository.recordManualRate(draft);
    _isApplying = false;
    notifyListeners();
    if (result is Ok<ExchangeRate>) {
      await load();
      return true;
    }
    return false;
  }

  /// Apply only what the owner ticked.
  Future<int> applySelectedReprice() async {
    final approved = selectedProposals;
    if (approved.isEmpty) {
      return 0;
    }
    _isApplying = true;
    notifyListeners();

    // Echo the instant the preview resolved at, so a rate landing while the
    // owner was reading the list cannot change what gets written.
    final result = await _repository.applyReprice(
      approved,
      resolvedAt: _preview.resolvedAt,
    );
    _isApplying = false;
    var written = 0;
    if (result case Ok<int>(value: final count)) {
      written = count;
      clearSelection();
    }
    notifyListeners();
    if (written > 0) {
      await load();
    }
    return written;
  }
}
