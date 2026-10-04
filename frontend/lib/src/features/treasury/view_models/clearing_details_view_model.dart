import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/card_settlement.dart';
import '../../../data/repositories/treasury_repository.dart';

/// What a clearing account's detail sheet shows beyond its balance: the held
/// days still waiting for the processor, and the deposits already recorded —
/// each of which can be undone, putting its sales back among the held ones.
class ClearingDetailsViewModel extends ChangeNotifier {
  ClearingDetailsViewModel(this._repository, {required this.accountId});

  final TreasuryRepository _repository;
  final int accountId;

  HeldTakings? _held;
  List<CardSettlement> _settlements = const [];
  bool _isLoading = false;
  bool _hasError = false;
  final Set<int> _cancelling = {};
  bool _disposed = false;

  HeldTakings? get held => _held;
  List<CardSettlement> get settlements => _settlements;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool isCancelling(int settlementId) => _cancelling.contains(settlementId);

  Future<void> load() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();
    final results = await Future.wait([
      _repository.loadHeldTakings(accountId),
      _repository.loadCardSettlements(accountId),
    ]);
    _isLoading = false;
    final held = results[0];
    final settlements = results[1];
    if (held case Ok<HeldTakings>(:final value)) {
      _held = value;
    } else {
      _hasError = true;
    }
    if (settlements case Ok<List<CardSettlement>>(:final value)) {
      _settlements = value;
    } else {
      _hasError = true;
    }
    notifyListeners();
  }

  /// Undoes a settlement. True once the server confirmed it.
  Future<bool> cancel(CardSettlement settlement, {String reason = ''}) async {
    if (_cancelling.contains(settlement.id)) {
      return false;
    }
    _cancelling.add(settlement.id);
    notifyListeners();
    final result = await _repository.cancelCardSettlement(
      settlement.id,
      reason: reason.trim(),
      idempotencyKey:
          'card-settlement-cancel-${settlement.id}-'
          '${DateTime.now().microsecondsSinceEpoch}',
    );
    _cancelling.remove(settlement.id);
    final ok = result is Ok<CardSettlement>;
    if (ok) {
      await load();
    } else {
      notifyListeners();
    }
    return ok;
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
