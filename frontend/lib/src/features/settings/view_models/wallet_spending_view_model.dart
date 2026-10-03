import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/repositories/wallet_repository.dart';
import 'wallet_view_model.dart';

/// Spending the Daftar wallet: moving money from the main wallet into the SMS
/// balance each message is paid from, paying for a plan (remote access, the
/// assistant) a period at a time, and the SMS balance's own statement.
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

  // --- the SMS balance ------------------------------------------------------

  bool _isAllocating = false;
  WalletException? _allocationError;
  String? _allocationKey;
  String? _allocationAmount;

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
  Future<bool> allocateToSms(double amount) async {
    if (_isAllocating) {
      return false;
    }
    final amountText = walletAmountText(amount, 3);
    // One attempt, one key: a retry after a lost answer moves the money once.
    if (_allocationKey == null || _allocationAmount != amountText) {
      _allocationKey = _newAttemptKey('sms');
      _allocationAmount = amountText;
    }
    _isAllocating = true;
    _allocationError = null;
    _notify();
    final result = await _repository.allocateToSms(
      amount: amountText,
      idempotencyKey: _allocationKey!,
    );
    if (_disposed) {
      return false;
    }
    var ok = false;
    switch (result) {
      case Ok<WalletSmsAllocation>(value: final allocation):
        _allocationKey = null;
        wallet.applySpending(balance: allocation.balance, sms: allocation.sms);
        unawaited(wallet.load());
        ok = true;
      case Error<WalletSmsAllocation>(exception: final exception):
        final error = _walletError(exception);
        if (!error.isRetryable) {
          _allocationKey = null;
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

  // --- the SMS statement ------------------------------------------------------

  final List<WalletEntry> _smsEntries = [];
  bool _smsEntriesHasMore = true;
  bool _isLoadingSmsEntries = false;
  bool _smsEntriesFailed = false;

  List<WalletEntry> get smsEntries => List.unmodifiable(_smsEntries);
  bool get smsEntriesHasMore => _smsEntriesHasMore;
  bool get isLoadingSmsEntries => _isLoadingSmsEntries;
  bool get smsEntriesFailed => _smsEntriesFailed;

  Future<void> loadSmsEntries({bool reset = false}) async {
    if (_isLoadingSmsEntries || (!reset && !_smsEntriesHasMore)) {
      return;
    }
    _isLoadingSmsEntries = true;
    _smsEntriesFailed = false;
    _notify();
    final before = reset || _smsEntries.isEmpty ? null : _smsEntries.last.id;
    final result = await _repository.loadEntries(
      before: before,
      account: WalletAccount.sms,
    );
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<WalletPage<WalletEntry>>(value: final page):
        if (reset) {
          _smsEntries.clear();
        }
        _smsEntries.addAll(page.items);
        _smsEntriesHasMore = page.hasMore;
      case Error<WalletPage<WalletEntry>>():
        // A failed page keeps "more" on, so the next scroll retries it.
        _smsEntriesFailed = true;
    }
    _isLoadingSmsEntries = false;
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
