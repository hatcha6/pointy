import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/money_position.dart';
import '../../../data/repositories/treasury_repository.dart';
import 'bank_routing.dart';

/// Drives the money position screen (الخزينة): the shop-wide balances, the
/// breakdown behind each account, and the two writes that keep them honest —
/// a count and a transfer.
///
/// Both writes reload the position rather than patching state locally: a count
/// snapshots the expected balance server-side, and a transfer changes two
/// accounts at once, so the screen must show what the backend now believes
/// rather than what the client guessed it would.
class MoneyPositionViewModel extends ChangeNotifier {
  MoneyPositionViewModel(this._repository);

  final TreasuryRepository _repository;

  MoneyPosition? _position;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isSubmitting = false;

  // Per-account drill-down, loaded lazily when an account is opened.
  final Map<int, MoneyMovementPage> _movements = {};
  final Set<int> _loadingMovements = {};
  final Set<int> _movementErrors = {};

  MoneyPosition? get position => _position;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get isSubmitting => _isSubmitting;
  bool get hasLoaded => _position != null;

  List<MoneyAccountPosition> get accounts => _position?.accounts ?? const [];
  MoneyPositionTotals get totals =>
      _position?.totals ?? const MoneyPositionTotals();

  MoneyAccountPosition? accountById(int id) {
    for (final entry in accounts) {
      if (entry.account.id == id) {
        return entry;
      }
    }
    return null;
  }

  MoneyMovementPage? movementsFor(int accountId) => _movements[accountId];
  bool isLoadingMovements(int accountId) =>
      _loadingMovements.contains(accountId);
  bool hasMovementsError(int accountId) => _movementErrors.contains(accountId);

  Future<void> load() async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _repository.loadPosition();
    _isLoading = false;
    switch (result) {
      case Ok(:final value):
        _position = value;
        // Balances moved, so every cached drill-down is now stale.
        _movements.clear();
        _movementErrors.clear();
      case Error():
        _hasError = true;
    }
    notifyListeners();
  }

  Future<void> loadMovements(int accountId, {bool force = false}) async {
    if (_loadingMovements.contains(accountId)) {
      return;
    }
    if (!force && _movements.containsKey(accountId)) {
      return;
    }
    _loadingMovements.add(accountId);
    _movementErrors.remove(accountId);
    notifyListeners();

    final result = await _repository.loadAccountMovements(accountId);
    _loadingMovements.remove(accountId);
    switch (result) {
      case Ok(:final value):
        _movements[accountId] = value;
      case Error():
        _movementErrors.add(accountId);
    }
    notifyListeners();
  }

  /// Records what was physically found. Returns the stored count (which carries
  /// the variance the backend computed) or null when the write failed.
  Future<MoneyCount?> recordCount({
    required int accountId,
    required double countedAmount,
    String note = '',
  }) async {
    if (_isSubmitting) {
      return null;
    }
    _isSubmitting = true;
    notifyListeners();

    final result = await _repository.recordCount(
      accountId: accountId,
      countedAmount: countedAmount,
      note: note,
      idempotencyKey: _idempotencyKey('count', accountId),
    );
    _isSubmitting = false;
    if (result is! Ok<MoneyCount>) {
      notifyListeners();
      return null;
    }
    await load();
    return result.value;
  }

  Future<bool> recordTransfer(MoneyTransferDraft draft) async {
    if (_isSubmitting) {
      return false;
    }
    _isSubmitting = true;
    notifyListeners();

    final result = await _repository.recordTransfer(
      draft,
      idempotencyKey: _idempotencyKey(
        'transfer',
        draft.fromAccountId ?? draft.toAccountId ?? 0,
      ),
    );
    _isSubmitting = false;
    if (result is! Ok<void>) {
      notifyListeners();
      return false;
    }
    await load();
    return true;
  }

  /// Creates an account, or saves changes to one.
  ///
  /// Reloads rather than patching the list: making an account the default
  /// un-defaults another, and an opening balance re-derives every figure on the
  /// screen — both are the server's arithmetic, not a guess this client should
  /// make.
  Future<bool> saveAccount(
    MoneyAccount account, {
    int? accountId,
    BankRouting? routing,
  }) async {
    if (_isSubmitting) {
      return false;
    }
    _isSubmitting = true;
    notifyListeners();

    final result = accountId == null
        ? await _repository.createAccount(account)
        : await _repository.updateAccount(accountId, account.toJson());
    _isSubmitting = false;
    if (result is! Ok<MoneyAccount>) {
      notifyListeners();
      return false;
    }
    await load();
    // The till's picker reads its own cached copy of these accounts; a new
    // bank account that only appeared on this screen would be invisible at
    // checkout until the app restarted.
    await routing?.load(force: true);
    return true;
  }

  /// A key that is stable for one submission attempt, so a retry after a
  /// dropped connection settles the same move once instead of twice.
  String _idempotencyKey(String action, int accountId) {
    return 'treasury-$action-$accountId-'
        '${DateTime.now().microsecondsSinceEpoch}';
  }
}
