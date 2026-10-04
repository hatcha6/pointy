import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/error_messages.dart';
import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/card_settlement.dart';
import '../../../data/models/money_position.dart';
import '../../../data/repositories/treasury_repository.dart';
import '../../../data/services/api_session.dart';

/// Why a settlement could not be recorded, in the words the sheet shows.
enum CardSettlementFailure {
  /// The server refused with a sentence of its own (already Arabic).
  explained,

  /// A closed period, or a user without the right.
  forbidden,

  /// Anything else — the network, an unexpected answer.
  generic,
}

/// Drives the "record the processor's transfer" sheet.
///
/// The owner types the one number they have — the deposit in the bank's SMS —
/// and the server proposes which held days it paid. The proposal is applied
/// whenever the amount or the date changes; the owner can then tick days off
/// or on, and open a day to leave out a sale the processor did not pay.
///
/// Every figure is in whole cents, straight from the server's strings: the
/// difference this sheet shows is the one the server will store, to the cent.
class CardSettlementViewModel extends ChangeNotifier {
  CardSettlementViewModel(
    this._repository, {
    required this.account,
    DateTime? today,
    this.debounce = const Duration(milliseconds: 400),
  }) : _settledOn = _dayOf(today ?? DateTime.now());

  final TreasuryRepository _repository;
  final MoneyAccount account;
  final Duration debounce;

  HeldTakings? _takings;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isSubmitting = false;
  int? _amountCents;
  DateTime _settledOn;
  final Set<String> _selectedDays = {};
  final Map<String, Set<int>> _excluded = {};
  final Map<String, List<HeldPayment>> _dayPayments = {};
  final Set<String> _loadingDays = {};
  final Set<String> _dayErrors = {};
  Timer? _debounceTimer;
  int _requestSerial = 0;
  CardSettlementFailure? _failure;
  String? _failureMessage;
  String? _idempotencyKey;
  bool _disposed = false;

  HeldTakings? get takings => _takings;
  List<HeldDay> get days => _takings?.days ?? const [];
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get isSubmitting => _isSubmitting;
  int? get amountCents => _amountCents;
  DateTime get settledOn => _settledOn;
  SettlementMatch get match =>
      _takings?.suggestion.match ?? SettlementMatch.none;
  CardSettlementFailure? get failure => _failure;
  String? get failureMessage => _failureMessage;

  bool isSelected(HeldDay day) => _selectedDays.contains(day.key);
  bool isExcluded(HeldDay day, HeldPayment payment) =>
      _excluded[day.key]?.contains(payment.id) ?? false;
  List<HeldPayment>? paymentsFor(HeldDay day) => _dayPayments[day.key];
  bool isLoadingPayments(HeldDay day) => _loadingDays.contains(day.key);
  bool hasPaymentsError(HeldDay day) => _dayErrors.contains(day.key);

  /// What the chosen days should have brought in, less any sale left out.
  int get expectedCents {
    var total = 0;
    for (final day in days) {
      if (!_selectedDays.contains(day.key)) {
        continue;
      }
      total += day.netCents;
      final left = _excluded[day.key];
      if (left == null || left.isEmpty) {
        continue;
      }
      for (final payment in _dayPayments[day.key] ?? const <HeldPayment>[]) {
        if (left.contains(payment.id)) {
          total -= payment.netCents;
        }
      }
    }
    return total;
  }

  /// Received minus expected; null until an amount is typed.
  int? get differenceCents {
    final amount = _amountCents;
    return amount == null ? null : amount - expectedCents;
  }

  bool get canSubmit =>
      !_isSubmitting &&
      _amountCents != null &&
      _selectedDays.isNotEmpty &&
      _takings != null;

  Future<void> load() => _fetch(applySuggestion: true);

  /// The amount field changed: ask again which days it most likely paid.
  void setAmountText(String text) {
    final trimmed = text.trim();
    final cents = trimmed.isEmpty ? null : _parseCents(trimmed);
    if (cents == _amountCents) {
      return;
    }
    _amountCents = cents;
    _resetAttempt();
    notifyListeners();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => _fetch(applySuggestion: true));
  }

  void setSettledOn(DateTime value) {
    final day = _dayOf(value);
    if (day == _settledOn) {
      return;
    }
    _settledOn = day;
    _resetAttempt();
    notifyListeners();
    _fetch(applySuggestion: true);
  }

  void toggleDay(HeldDay day) {
    if (!_selectedDays.remove(day.key)) {
      _selectedDays.add(day.key);
    }
    _resetAttempt();
    notifyListeners();
  }

  void togglePayment(HeldDay day, HeldPayment payment) {
    final left = _excluded.putIfAbsent(day.key, () => <int>{});
    if (!left.remove(payment.id)) {
      left.add(payment.id);
    }
    _resetAttempt();
    notifyListeners();
  }

  Future<void> loadPayments(HeldDay day) async {
    if (_dayPayments.containsKey(day.key) || _loadingDays.contains(day.key)) {
      return;
    }
    _loadingDays.add(day.key);
    _dayErrors.remove(day.key);
    notifyListeners();
    final result = await _repository.loadHeldDayPayments(account.id, day.key);
    _loadingDays.remove(day.key);
    switch (result) {
      case Ok(:final value):
        _dayPayments[day.key] = value;
      case Error():
        _dayErrors.add(day.key);
    }
    notifyListeners();
  }

  /// Records the settlement. Null when it was refused; [failure] says why.
  Future<CardSettlement?> submit({
    String reference = '',
    String note = '',
  }) async {
    final amount = _amountCents;
    if (!canSubmit || amount == null) {
      return null;
    }
    _isSubmitting = true;
    _failure = null;
    _failureMessage = null;
    notifyListeners();

    // One key per attempt: a retry after a dropped connection records the
    // deposit once, while a changed form is a new attempt.
    _idempotencyKey ??=
        'card-settlement-${account.id}-${DateTime.now().microsecondsSinceEpoch}';
    final selected = [
      for (final day in days)
        if (_selectedDays.contains(day.key)) day.key,
    ];
    final excluded = [for (final key in selected) ...?_excluded[key]];
    final draft = CardSettlementDraft(
      clearingAccountId: account.id,
      settledOn: _settledOn,
      amountReceivedCents: amount,
      days: selected,
      excludePaymentIds: excluded,
      expectedCents: expectedCents,
      reference: reference.trim(),
      note: note.trim(),
    );
    final result = await _repository.recordCardSettlement(
      draft,
      idempotencyKey: _idempotencyKey,
    );
    _isSubmitting = false;
    switch (result) {
      case Ok(:final value):
        notifyListeners();
        return value;
      case Error(:final exception):
        _explain(exception);
        notifyListeners();
        if (_failureCode(exception) == 'held_amount_changed') {
          // Someone else moved the held takings; show what is held now.
          unawaited(_fetch(applySuggestion: false));
        }
        return null;
    }
  }

  Future<void> _fetch({required bool applySuggestion}) async {
    final serial = ++_requestSerial;
    _isLoading = true;
    _hasError = false;
    notifyListeners();
    final result = await _repository.loadHeldTakings(
      account.id,
      amountCents: _amountCents,
      settledOn: _settledOn,
    );
    if (serial != _requestSerial) {
      // A newer request (the owner kept typing) owns the screen now.
      return;
    }
    _isLoading = false;
    switch (result) {
      case Ok(:final value):
        _takings = value;
        final held = {for (final day in value.days) day.key};
        _selectedDays.removeWhere((key) => !held.contains(key));
        _excluded.removeWhere((key, _) => !held.contains(key));
        _dayPayments.removeWhere((key, _) => !held.contains(key));
        if (applySuggestion) {
          _selectedDays
            ..clear()
            ..addAll(value.suggestion.days.where(held.contains));
          _excluded.clear();
        }
      case Error():
        _hasError = true;
    }
    notifyListeners();
  }

  void _resetAttempt() {
    _idempotencyKey = null;
    _failure = null;
    _failureMessage = null;
  }

  void _explain(Object exception) {
    if (exception is PosApiException && exception.statusCode == 403) {
      _failure = CardSettlementFailure.forbidden;
      return;
    }
    final detail = backendDetailFor(exception);
    // The server words its own refusals in Arabic. Anything else — a
    // framework default in English — is replaced by the sheet's own sentence.
    if (detail != null && _arabic.hasMatch(detail)) {
      _failure = CardSettlementFailure.explained;
      _failureMessage = detail;
      return;
    }
    _failure = CardSettlementFailure.generic;
  }

  static String? _failureCode(Object exception) {
    if (exception is! PosApiException) {
      return null;
    }
    final body = exception.decodedBody;
    return body is Map ? body['code']?.toString() : null;
  }

  static final _arabic = RegExp(r'[؀-ۿ]');

  /// Arabic-Indic digits and an Arabic decimal mark are what an Arabic
  /// keyboard types; [parseDecimal] reads both. A deposit is never negative.
  static int? _parseCents(String text) {
    final value = parseDecimal(text);
    if (value == null || value < 0) {
      return null;
    }
    return (value * 100).round();
  }

  static DateTime _dayOf(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  @override
  void notifyListeners() {
    // A fetch the owner outran by closing the sheet answers into nothing.
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
