import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/repositories/wallet_repository.dart';

/// The bank-transfer step of a top-up: which app the owner sends with, the
/// account they send from (one tap when they used it before), and the
/// receipt — a file on this device or what their phone sent. Sending it hands
/// the top-up back to [onSent], which follows it until the company's team
/// decides.
class WalletBankTransferViewModel extends ChangeNotifier {
  WalletBankTransferViewModel(
    this._repository, {
    required this.onSent,
    String Function()? newAttemptKey,
  }) : _newAttemptKey = newAttemptKey ?? _randomKey;

  final WalletRepository _repository;
  final void Function(WalletTopUp topUp, bool recordAsExpense) onSent;
  final String Function() _newAttemptKey;

  WalletBankTransferOffer? _offer;
  WalletTransferChannel _channel = WalletTransferChannel.lyPay;
  String _payerBank = '';
  String _payerAccount = '';
  String _payerIban = '';
  WalletTransferReceipt? _receipt;
  bool _sending = false;
  double? _progress;
  WalletException? _error;
  String? _attemptKey;
  String? _attemptSignature;
  bool _disposed = false;

  WalletBankTransferOffer? get offer => _offer;
  WalletTransferChannel get channel => _channel;
  String get payerBank => _payerBank;
  String get payerAccount => _payerAccount;
  String get payerIban => _payerIban;
  WalletTransferReceipt? get receipt => _receipt;
  bool get isSending => _sending;

  /// How much of the receipt has gone up, while it goes.
  double? get progress => _progress;
  WalletException? get error => _error;

  /// The company's account this transfer goes to: the first offered.
  WalletBankAccount? get account {
    final accounts = _offer?.accounts ?? const [];
    return accounts.isEmpty ? null : accounts.first;
  }

  List<WalletPayerAccount> get savedPayers => _offer?.savedPayers ?? const [];

  bool get ibanValid => LibyanIban.isValid(_payerIban);
  bool get accountValid => isBankAccountNumber(_payerAccount);
  bool get canSend =>
      !_sending &&
      account != null &&
      _payerBank.isNotEmpty &&
      accountValid &&
      ibanValid &&
      _receipt != null;

  /// Opens the step on [offer], filled with the account used last time.
  void prepare(WalletBankTransferOffer? offer) {
    _offer = offer;
    _error = null;
    _progress = null;
    _sending = false;
    _receipt = null;
    final last = savedPayers.isEmpty ? null : savedPayers.first;
    if (last != null && _payerIban.isEmpty) {
      useSavedPayer(last, notify: false);
    }
    _notify();
  }

  void selectChannel(WalletTransferChannel channel) {
    if (_channel == channel) {
      return;
    }
    _channel = channel;
    _notify();
  }

  void useSavedPayer(WalletPayerAccount payer, {bool notify = true}) {
    _payerBank = payer.bank;
    _payerAccount = payer.accountNumber;
    _payerIban = LibyanIban.normalize(payer.iban);
    _channel = payer.channel;
    _error = null;
    if (notify) {
      _notify();
    }
  }

  void setPayerBank(String slug) {
    _payerBank = slug;
    _error = null;
    _notify();
  }

  void setPayerAccount(String value) {
    _payerAccount = normalizeBankAccountNumber(value);
    _error = null;
    _notify();
  }

  /// The IBAN carries the account number: a valid one fills it in when the
  /// field is still empty, so the owner types one number, not two.
  void setPayerIban(String value) {
    _payerIban = LibyanIban.normalize(value);
    final number = LibyanIban.accountNumber(_payerIban);
    if (number != null && _payerAccount.isEmpty) {
      _payerAccount = number;
    }
    _error = null;
    _notify();
  }

  void attachReceipt(WalletTransferReceipt receipt) {
    final max = _offer?.maxReceiptBytes ?? 10 * 1024 * 1024;
    if (receipt.size > max) {
      _error = const WalletException(code: 'receipt_too_large', message: '');
      _notify();
      return;
    }
    _receipt = receipt;
    _error = null;
    _notify();
  }

  void removeReceipt() {
    _receipt = null;
    _notify();
  }

  /// Sends the transfer and its receipt. One attempt, one key: a retry after a
  /// dropped answer returns the same top-up instead of a second one.
  Future<void> send({
    required String amount,
    required bool recordAsExpense,
  }) async {
    final receipt = _receipt;
    final to = account;
    if (!canSend || receipt == null || to == null) {
      return;
    }
    final signature = [
      amount,
      _channel.key,
      _payerBank,
      _payerAccount,
      _payerIban,
      receipt.attachmentId ?? receipt.name,
      receipt.size,
    ].join('|');
    if (_attemptKey == null || _attemptSignature != signature) {
      _attemptKey = _newAttemptKey();
      _attemptSignature = signature;
    }
    _sending = true;
    _progress = 0;
    _error = null;
    _notify();
    final result = await _repository.startBankTransfer(
      WalletBankTransferRequest(
        amount: amount,
        channel: _channel,
        payerBank: _payerBank,
        payerAccount: _payerAccount,
        payerIban: _payerIban,
        receipt: receipt,
        idempotencyKey: _attemptKey!,
        toAccount: to.id,
        recordAsExpense: recordAsExpense,
      ),
      onProgress: (sent, total) {
        if (total > 0 && !_disposed) {
          _progress = sent / total;
          _notify();
        }
      },
    );
    if (_disposed) {
      return;
    }
    _sending = false;
    _progress = null;
    switch (result) {
      case Ok<WalletTopUpStart>(value: final start):
        _attemptKey = null;
        _receipt = null;
        _notify();
        onSent(start.topUp, recordAsExpense);
      case Error<WalletTopUpStart>(exception: final exception):
        final error = exception is WalletException
            ? exception
            : const WalletException(code: 'network', message: '');
        if (!error.isRetryable) {
          _attemptKey = null;
        }
        _error = error;
        _notify();
    }
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

String _randomKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(12, (_) => random.nextInt(256));
  return 'transfer-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}
