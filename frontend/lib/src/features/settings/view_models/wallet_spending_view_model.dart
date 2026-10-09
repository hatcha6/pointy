import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/repositories/wallet_repository.dart';
import 'wallet_view_model.dart';

/// Spending the Daftar wallet: moving money from the main wallet into the SMS
/// balance each message is paid from — or into the voucher balance the till's
/// «كروت دفتر» are paid from — paying for a plan (remote access, the
/// assistant) a period at a time, and those balances' own statements.
///
/// The balances themselves are the [wallet]'s; a spend patches them at once
/// and reloads the wallet, so every screen showing them moves together.
class WalletSpendingViewModel extends ChangeNotifier {
  WalletSpendingViewModel(
    this._repository, {
    required this.wallet,
    String Function(String purpose)? newAttemptKey,
  }) : _newAttemptKey = newAttemptKey ?? _randomAttemptKey;

  final WalletRepository _repository;
  final WalletViewModel wallet;
  final String Function(String purpose) _newAttemptKey;

  bool _disposed = false;

  // --- moving money into the SMS or the voucher balance ---------------------
  //
  // One transfer at a time, whichever balance it fills: the sheets that start
  // them are modal, and each clears the last refusal when it opens.

  bool _isAllocating = false;
  WalletException? _allocationError;

  /// The key and amount of the last attempt per balance: a retry after a lost
  /// answer resends the same key, so the money moves once.
  final Map<WalletAccount, ({String key, String amount})> _allocationAttempts =
      {};

  bool get isAllocating => _isAllocating;

  /// Why the last transfer was refused, until the next one is tried.
  WalletException? get allocationError => _allocationError;

  /// Clears what the transfer sheet showed last time it was open.
  void beginAllocation() {
    if (_allocationError == null) {
      return;
    }
    _allocationError = null;
    _notify();
  }

  /// Moves [amount] dinars into the SMS balance. True once it is there.
  Future<bool> allocateToSms(double amount) {
    return _allocate<WalletSmsAllocation>(
      account: WalletAccount.sms,
      // Dirhams: a message costs 0.150.
      amountText: walletAmountText(amount, 3),
      purpose: 'sms',
      send: (amount, key) =>
          _repository.allocateToSms(amount: amount, idempotencyKey: key),
      apply: (allocation) => wallet.applySpending(
        balance: allocation.balance,
        sms: allocation.sms,
      ),
    );
  }

  /// Moves [amount] dinars into the voucher balance the till's cards are paid
  /// from. True once it is there.
  Future<bool> allocateToVouchers(double amount) {
    return _allocate<WalletVoucherAllocation>(
      account: WalletAccount.vouchers,
      // Two places, like every amount the shop's books keep for the cards.
      amountText: walletAmountText(amount, 2),
      purpose: 'vouchers',
      send: (amount, key) =>
          _repository.allocateToVouchers(amount: amount, idempotencyKey: key),
      apply: (allocation) => wallet.applySpending(
        balance: allocation.balance,
        vouchers: allocation.vouchers,
      ),
    );
  }

  Future<bool> _allocate<T>({
    required WalletAccount account,
    required String amountText,
    required String purpose,
    required Future<Result<T>> Function(String amount, String key) send,
    required void Function(T allocation) apply,
  }) async {
    if (_isAllocating) {
      return false;
    }
    // One attempt, one key: a retry after a lost answer moves the money once.
    final previous = _allocationAttempts[account];
    final attempt = previous != null && previous.amount == amountText
        ? previous
        : (key: _newAttemptKey(purpose), amount: amountText);
    _allocationAttempts[account] = attempt;
    _isAllocating = true;
    _allocationError = null;
    _notify();
    final result = await send(amountText, attempt.key);
    if (_disposed) {
      return false;
    }
    var ok = false;
    switch (result) {
      case Ok<T>(value: final allocation):
        _allocationAttempts.remove(account);
        apply(allocation);
        unawaited(wallet.load());
        ok = true;
      case Error<T>(exception: final exception):
        final error = _walletError(exception);
        if (!error.isRetryable) {
          _allocationAttempts.remove(account);
        }
        _allocationError = error;
    }
    _isAllocating = false;
    _notify();
    return ok;
  }

  // --- plans ------------------------------------------------------------------

  String? _purchasingPlan;
  WalletException? _purchaseError;
  String? _purchaseKey;
  String? _purchaseSignature;

  /// The plan being paid for right now, if any.
  String? get purchasingPlan => _purchasingPlan;
  bool get isPurchasing => _purchasingPlan != null;

  /// Why the last purchase was refused, until the next one is tried.
  WalletException? get purchaseError => _purchaseError;

  void beginPurchase() {
    if (_purchaseError == null) {
      return;
    }
    _purchaseError = null;
    _notify();
  }

  /// Pays for [periods] periods of [plan] from the main wallet. Returns the
  /// plan as it now stands, or null when the purchase was refused.
  Future<WalletPlan?> purchasePlan(String plan, int periods) async {
    if (isPurchasing) {
      return null;
    }
    final signature = '$plan|$periods';
    if (_purchaseKey == null || _purchaseSignature != signature) {
      _purchaseKey = _newAttemptKey('plan');
      _purchaseSignature = signature;
    }
    _purchasingPlan = plan;
    _purchaseError = null;
    _notify();
    final result = await _repository.purchasePlan(
      plan: plan,
      periods: periods,
      idempotencyKey: _purchaseKey!,
    );
    if (_disposed) {
      return null;
    }
    WalletPlan? bought;
    switch (result) {
      case Ok<WalletPlanPurchase>(value: final purchase):
        _purchaseKey = null;
        // A paid purchase always answers with its plan; this only guards a
        // malformed answer from turning a payment into "nothing happened".
        bought =
            purchase.plan ??
            WalletPlan(key: plan, available: true, active: true);
        wallet.applySpending(balance: purchase.balance, plan: bought);
        unawaited(wallet.load());
      case Error<WalletPlanPurchase>(exception: final exception):
        final error = _walletError(exception);
        if (!error.isRetryable) {
          _purchaseKey = null;
        }
        _purchaseError = error;
    }
    _purchasingPlan = null;
    _notify();
    return bought;
  }

  // --- the SMS and voucher statements ----------------------------------------

  final _smsStatement = _EntryStatement();
  final _voucherStatement = _EntryStatement();

  List<WalletEntry> get smsEntries => List.unmodifiable(_smsStatement.entries);
  bool get smsEntriesHasMore => _smsStatement.hasMore;
  bool get isLoadingSmsEntries => _smsStatement.isLoading;
  bool get smsEntriesFailed => _smsStatement.failed;

  Future<void> loadSmsEntries({bool reset = false}) =>
      _loadStatement(_smsStatement, WalletAccount.sms, reset: reset);

  List<WalletEntry> get voucherEntries =>
      List.unmodifiable(_voucherStatement.entries);
  bool get voucherEntriesHasMore => _voucherStatement.hasMore;
  bool get isLoadingVoucherEntries => _voucherStatement.isLoading;
  bool get voucherEntriesFailed => _voucherStatement.failed;

  Future<void> loadVoucherEntries({bool reset = false}) =>
      _loadStatement(_voucherStatement, WalletAccount.vouchers, reset: reset);

  Future<void> _loadStatement(
    _EntryStatement statement,
    WalletAccount account, {
    required bool reset,
  }) async {
    if (statement.isLoading || (!reset && !statement.hasMore)) {
      return;
    }
    statement
      ..isLoading = true
      ..failed = false;
    _notify();
    final entries = statement.entries;
    final before = reset || entries.isEmpty ? null : entries.last.id;
    final result = await _repository.loadEntries(
      before: before,
      account: account,
    );
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<WalletPage<WalletEntry>>(value: final page):
        if (reset) {
          entries.clear();
        }
        entries.addAll(page.items);
        statement.hasMore = page.hasMore;
      case Error<WalletPage<WalletEntry>>():
        // A failed page keeps "more" on, so the next scroll retries it.
        statement.failed = true;
    }
    statement.isLoading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// One balance's statement, paged newest first.
class _EntryStatement {
  final List<WalletEntry> entries = [];
  bool hasMore = true;
  bool isLoading = false;
  bool failed = false;
}

WalletException _walletError(Object exception) {
  return exception is WalletException
      ? exception
      : const WalletException(code: 'network', message: '');
}

String _randomAttemptKey(String purpose) {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'app-$purpose-$hex';
}
