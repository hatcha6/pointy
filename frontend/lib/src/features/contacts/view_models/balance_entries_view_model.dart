import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/balance_entry.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/balance_labels.dart';

/// The opening balances and adjustments on one customer's or supplier's
/// account: listing them, writing one, and withdrawing one.
///
/// Its own view model rather than more of the details screens': both parties
/// share it, and the details view models are already large. The screen that
/// hosts it reloads its own balance figures through [onChanged].
class BalanceEntriesViewModel extends ChangeNotifier {
  BalanceEntriesViewModel({
    required ContactRepository repository,
    required this.party,
    required this.partyId,
    this.onChanged,
    bool autoload = true,
  }) : _repository = repository {
    if (autoload) {
      load();
    }
  }

  final ContactRepository _repository;
  final BalanceParty party;
  final int partyId;

  /// Called after an entry is written or withdrawn, so the balance shown
  /// beside the list is re-read from the server rather than guessed at.
  final Future<void> Function()? onChanged;

  List<BalanceEntry> _entries = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  bool _hasError = false;
  bool _isSaving = false;
  int _nextPage = 1;
  // One key per intended write, so a double tap — or a retry after a timeout
  // whose request did land — cannot record the same balance twice.
  final Map<String, String> _idempotencyKeys = {};

  List<BalanceEntry> get entries => List.unmodifiable(_entries);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  bool get hasError => _hasError;
  bool get isSaving => _isSaving;

  /// Whether the account already has an opening balance that stands. The
  /// server enforces one per account; this only decides what to offer.
  bool get hasLiveOpening =>
      _entries.any((entry) => entry.isOpening && !entry.isCancelled);

  Future<void> load() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _repository.loadBalanceEntries(
      party: party,
      partyId: partyId,
    );
    switch (result) {
      case Ok<BalanceEntryPage>():
        _entries = result.value.entries;
        _hasMore = result.value.hasMore;
        _nextPage = 2;
      case Error<BalanceEntryPage>():
        _entries = [];
        _hasMore = false;
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) {
      return;
    }
    _isLoadingMore = true;
    notifyListeners();

    final result = await _repository.loadBalanceEntries(
      party: party,
      partyId: partyId,
      page: _nextPage,
    );
    switch (result) {
      case Ok<BalanceEntryPage>():
        _entries = [..._entries, ...result.value.entries];
        _hasMore = result.value.hasMore;
        _nextPage += 1;
      case Error<BalanceEntryPage>():
        // Kept, not cleared: a failed page is not the end of the list.
        _hasError = true;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  /// Writes one entry. Returns null on success, or why it was refused.
  Future<BalanceFailure?> create(BalanceEntryDraft draft) async {
    if (_isSaving) {
      return BalanceFailure.generic;
    }
    _isSaving = true;
    notifyListeners();

    final signature = [
      'balance-entry',
      party.fieldName,
      partyId,
      draft.kind.apiValue,
      draft.direction.apiValue,
      draft.amount.toStringAsFixed(2),
      draft.effectiveDate?.toIso8601String() ?? '',
      draft.note.trim(),
    ].join(':');
    final result = await _repository.createBalanceEntry(
      party: party,
      partyId: partyId,
      draft: draft,
      idempotencyKey: _keyFor(signature),
    );

    BalanceFailure? failure;
    switch (result) {
      case Ok<BalanceEntry>():
        _idempotencyKeys.remove(signature);
      case Error<BalanceEntry>(:final exception):
        failure = classifyBalanceFailure(exception);
    }
    _isSaving = false;
    notifyListeners();

    if (failure == null) {
      await Future.wait([load(), if (onChanged != null) onChanged!()]);
    }
    return failure;
  }

  /// Settles a balance with cash through the caller's own open drawer — for an
  /// employee, the side [settles] names. Returns null on success, or why it
  /// was refused.
  Future<BalanceFailure?> refund(
    double amount, {
    String note = '',
    BalanceDirection? settles,
  }) async {
    if (_isSaving) {
      return BalanceFailure.generic;
    }
    _isSaving = true;
    notifyListeners();

    final signature = [
      'balance-refund',
      party.fieldName,
      partyId,
      settles?.apiValue ?? '',
      amount.toStringAsFixed(2),
      note.trim(),
    ].join(':');
    final result = await _repository.refundBalance(
      party: party,
      partyId: partyId,
      amount: amount,
      note: note,
      settles: settles,
      idempotencyKey: _keyFor(signature),
    );

    BalanceFailure? failure;
    switch (result) {
      case Ok<BalanceEntry>():
        _idempotencyKeys.remove(signature);
      case Error<BalanceEntry>(:final exception):
        failure = classifyBalanceFailure(exception);
    }
    _isSaving = false;
    notifyListeners();

    if (failure == null) {
      await Future.wait([load(), if (onChanged != null) onChanged!()]);
    }
    return failure;
  }

  /// Withdraws an entry nothing has been settled against. Returns null on
  /// success, or why it was refused.
  Future<BalanceFailure?> cancel(BalanceEntry entry, String reason) async {
    if (_isSaving) {
      return BalanceFailure.generic;
    }
    _isSaving = true;
    notifyListeners();

    final signature = ['balance-cancel', party.fieldName, entry.id].join(':');
    final result = await _repository.cancelBalanceEntry(
      party: party,
      entryId: entry.id,
      reason: reason.trim(),
      idempotencyKey: _keyFor(signature),
    );

    BalanceFailure? failure;
    switch (result) {
      case Ok<BalanceEntry>():
        _idempotencyKeys.remove(signature);
      case Error<BalanceEntry>(:final exception):
        failure = classifyBalanceFailure(exception);
    }
    _isSaving = false;
    notifyListeners();

    if (failure == null) {
      await Future.wait([load(), if (onChanged != null) onChanged!()]);
    }
    return failure;
  }

  String _keyFor(String signature) {
    return _idempotencyKeys.putIfAbsent(
      signature,
      () => 'balance-entry:${generateAnalyticsEventId()}',
    );
  }
}
