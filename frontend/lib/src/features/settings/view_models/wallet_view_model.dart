import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/repositories/wallet_repository.dart';
import 'wallet_bank_transfer_view_model.dart';
import 'wallet_spending_view_model.dart';

/// Opens the gateway's payment page. Injected so tests and the preview never
/// leave the app.
typedef WalletCheckoutLauncher = Future<bool> Function(Uri uri);

/// A bank-card payer pays on the gateway's own page, in the system browser:
/// card details never pass through Pointy, and it works on every platform the
/// till runs on. The app follows the payment by polling, so nothing is typed
/// back.
Future<bool> openWalletCheckoutInBrowser(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Exception {
    return false;
  }
}

/// Where the top-up sheet is.
enum WalletTopUpStage {
  /// Choosing the amount, the method and the payer.
  form,

  /// Asking the gateway to start the payment.
  starting,

  /// The provider texted the payer a code; waiting for them to type it.
  awaitingCode,

  /// Sending the code.
  confirmingCode,

  /// The payer is paying on the gateway's page — or the gateway took the code
  /// without a verdict yet — and the app is waiting for the outcome.
  awaitingPayment,
  paid,
  canceled,
  failed,

  /// No verdict came back in time. The payment may still land: the relay
  /// credits a late one, and the backend's sync books it.
  unconfirmed,

  /// A bank transfer: our account to send to, the owner's account and the
  /// receipt.
  bankTransfer,

  /// The receipt went up; the company's team is checking the transfer.
  awaitingReview,

  /// The team rejected the transfer, with its reason.
  rejected,
}

/// Drives the wallet on the subscription page: the balance, the top-up flow
/// (pick a method, start, confirm with the texted code or pay on the gateway's
/// page, follow it to a verdict), the auto-expense switch, and the paged
/// history. Spending it — the SMS balance, the plans — is [spending].
class WalletViewModel extends ChangeNotifier {
  WalletViewModel(
    this._repository, {
    WalletCheckoutLauncher? launchCheckout,
    this.fastPollInterval = const Duration(seconds: 3),
    this.slowPollInterval = const Duration(seconds: 10),
    this.fastPollFor = const Duration(minutes: 3),
    DateTime Function()? clock,
    String Function()? newAttemptKey,
  }) : _launchCheckout = launchCheckout ?? openWalletCheckoutInBrowser,
       _clock = clock ?? DateTime.now,
       _newAttemptKey = newAttemptKey ?? _randomAttemptKey;

  final WalletRepository _repository;
  final WalletCheckoutLauncher _launchCheckout;
  final DateTime Function() _clock;
  final String Function() _newAttemptKey;

  /// Moving money into the SMS balance and paying for plans.
  late final WalletSpendingViewModel spending = WalletSpendingViewModel(
    _repository,
    wallet: this,
  );

  /// The bank-transfer step of a top-up.
  late final WalletBankTransferViewModel transfer = WalletBankTransferViewModel(
    _repository,
    onSent: _followTransfer,
  );
  double? _transferAmount;

  /// The amount the owner is transferring, while the transfer step is open.
  double? get transferAmount => _transferAmount;

  /// While the payer is most likely on the payment page, ask often; after
  /// that, ask less — a card payment that has not landed in minutes is rare.
  final Duration fastPollInterval;
  final Duration slowPollInterval;
  final Duration fastPollFor;

  bool _disposed = false;

  // --- the wallet ---------------------------------------------------------

  WalletOverview? _overview;
  bool _isLoading = false;
  bool _hasLoadError = false;

  WalletOverview? get overview => _overview;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;

  Future<void> load() async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;
    _hasLoadError = false;
    _notify();
    final result = await _repository.loadWallet();
    switch (result) {
      case Ok<WalletOverview>(value: final overview):
        _overview = overview;
      case Error<WalletOverview>():
        _hasLoadError = true;
    }
    _isLoading = false;
    _notify();
  }

  /// Shows what a spend left at once, before the reload that follows it.
  void applySpending({
    double? balance,
    SmsWallet? sms,
    VoucherWallet? vouchers,
    WalletPlan? plan,
  }) {
    final overview = _overview;
    if (overview == null) {
      return;
    }
    _overview = overview.copyWith(
      balance: balance,
      sms: sms,
      vouchers: vouchers,
      plan: plan,
    );
    _notify();
  }

  // --- the books switch ---------------------------------------------------

  bool _isSavingSettings = false;
  bool _settingsSaveFailed = false;

  bool get isSavingSettings => _isSavingSettings;
  bool get settingsSaveFailed => _settingsSaveFailed;

  bool get recordTopUpsAsExpenses =>
      _overview?.settings.recordTopUpsAsExpenses ?? true;

  Future<bool> setRecordTopUpsAsExpenses(bool value) async {
    final overview = _overview;
    if (overview == null || _isSavingSettings) {
      return false;
    }
    _isSavingSettings = true;
    _settingsSaveFailed = false;
    _overview = overview.copyWith(
      settings: WalletSettings(
        recordTopUpsAsExpenses: value,
        expenseCategoryId: overview.settings.expenseCategoryId,
        expenseCategoryName: overview.settings.expenseCategoryName,
        defaultExpenseCategoryName:
            overview.settings.defaultExpenseCategoryName,
      ),
    );
    _notify();
    final result = await _repository.updateSettings(
      recordTopUpsAsExpenses: value,
    );
    var ok = false;
    switch (result) {
      case Ok<WalletSettings>(value: final settings):
        _overview = _overview?.copyWith(settings: settings);
        ok = true;
      case Error<WalletSettings>():
        _overview = _overview?.copyWith(settings: overview.settings);
        _settingsSaveFailed = true;
    }
    _isSavingSettings = false;
    _notify();
    return ok;
  }

  // --- a top-up -----------------------------------------------------------

  WalletTopUpStage _stage = WalletTopUpStage.form;
  String? _methodKey;
  WalletTopUp? _activeTopUp;
  String? _checkoutUrl;
  WalletException? _topUpError;
  WalletException? _codeError;
  WalletException? _verdictError;
  bool _checkoutOpenFailed = false;
  bool _recordAsExpense = true;
  String? _attemptKey;
  String? _attemptSignature;
  DateTime? _awaitingSince;
  Timer? _pollTimer;
  bool _isChecking = false;

  WalletTopUpStage get topUpStage => _stage;
  WalletTopUp? get activeTopUp => _activeTopUp;
  String? get checkoutUrl => _checkoutUrl;

  /// Why the payment could not start (shown on the form).
  WalletException? get topUpError => _topUpError;

  /// Why the last code was not taken, while another may be sent.
  WalletException? get codeError => _codeError;

  /// The refusal that ended the top-up, with the gateway's own sentence.
  WalletException? get verdictError => _verdictError;

  /// The browser did not open; the sheet offers the link instead.
  bool get checkoutOpenFailed => _checkoutOpenFailed;

  /// Whether THIS top-up goes in the books. Starts at the saved setting; a
  /// change here is saved as the new default when the top-up starts.
  bool get recordAsExpense => _recordAsExpense;

  bool get isPolling => _pollTimer != null;

  /// The ways to pay the company offers right now, in its order.
  List<WalletTopUpMethod> get methods =>
      _overview?.topUpOptions?.methods ?? const [];

  /// The method the form is set to: the owner's pick while it is still
  /// offered, else the first one offered.
  WalletTopUpMethod? get selectedMethod {
    final offered = methods;
    for (final method in offered) {
      if (method.key == _methodKey) {
        return method;
      }
    }
    return offered.isEmpty ? null : offered.first;
  }

  /// Whether the payment in hand is waiting on the gateway's page (true) or
  /// on the gateway's verdict about a code (false).
  bool get awaitingHostedPage => (_checkoutUrl ?? '').isNotEmpty;

  /// Opens the sheet on a clean form, on the method picked last time.
  void beginTopUp() {
    _stopPolling();
    _stage = WalletTopUpStage.form;
    _activeTopUp = null;
    _checkoutUrl = null;
    _topUpError = null;
    _codeError = null;
    _verdictError = null;
    _checkoutOpenFailed = false;
    _recordAsExpense = recordTopUpsAsExpenses;
    _notify();
  }

  void selectMethod(String key) {
    if (_stage != WalletTopUpStage.form || key == selectedMethod?.key) {
      return;
    }
    _methodKey = key;
    _topUpError = null;
    _notify();
  }

  void setRecordAsExpense(bool value) {
    _recordAsExpense = value;
    _notify();
  }

  /// Drops the reason the payment could not start, once something closer to
  /// the cause shows it — the payer dialog, beside the number it refused.
  void dismissTopUpError() {
    if (_topUpError == null) {
      return;
    }
    _topUpError = null;
    _notify();
  }

  /// Asks the gateway to start a payment of [amount] dinars by the selected
  /// method: a code goes to the payer's phone, or the payment page opens.
  Future<void> startTopUp(
    double amount, {
    String userIdentifier = '',
    String birthYear = '',
  }) async {
    final method = selectedMethod;
    if (_stage == WalletTopUpStage.starting || method == null) {
      return;
    }
    final amountText = walletAmountText(
      amount,
      _overview?.topUpOptions?.maxDecimals ?? 2,
    );
    final payer = userIdentifier.trim();
    final year = birthYear.trim();
    // One attempt, one key: a retry after a dropped response returns the same
    // payment instead of a second one. Anything changed is a new attempt.
    final signature = [amountText, method.key, payer, year].join('|');
    if (_attemptKey == null || _attemptSignature != signature) {
      _attemptKey = _newAttemptKey();
      _attemptSignature = signature;
    }
    _stage = WalletTopUpStage.starting;
    _topUpError = null;
    _codeError = null;
    _verdictError = null;
    _checkoutOpenFailed = false;
    _notify();

    final result = await _repository.startTopUp(
      amount: amountText,
      method: method.key,
      idempotencyKey: _attemptKey!,
      recordAsExpense: _recordAsExpense,
      userIdentifier: payer,
      birthYear: year,
    );
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<WalletTopUpStart>(value: final start):
        _attemptKey = null;
        _activeTopUp = start.topUp;
        _rememberSettingChoice();
        if (_settleFrom(start.topUp)) {
          // A replayed key whose top-up already has a verdict.
          _notify();
          return;
        }
        if (start.needsCode) {
          _checkoutUrl = null;
          _stage = WalletTopUpStage.awaitingCode;
          _notify();
          return;
        }
        _checkoutUrl = start.checkoutUrl.isEmpty
            ? start.topUp.checkoutUrl
            : start.checkoutUrl;
        _stage = WalletTopUpStage.awaitingPayment;
        _awaitingSince = _clock();
        _notify();
        await openCheckout();
        _startPolling();
      case Error<WalletTopUpStart>(exception: final exception):
        final error = exception is WalletException
            ? exception
            : const WalletException(code: 'network', message: '');
        if (!error.isRetryable) {
          _attemptKey = null;
        }
        _topUpError = error;
        _activeTopUp = error.topUp;
        _stage = WalletTopUpStage.form;
        _notify();
    }
  }

  /// Sends the code the payer's provider texted them.
  Future<void> confirmCode(String otp) async {
    final topUp = _activeTopUp;
    if (topUp == null || _stage != WalletTopUpStage.awaitingCode) {
      return;
    }
    _stage = WalletTopUpStage.confirmingCode;
    _codeError = null;
    _notify();
    final result = await _repository.confirmTopUp(id: topUp.id, otp: otp);
    if (_disposed || _stage != WalletTopUpStage.confirmingCode) {
      return;
    }
    switch (result) {
      case Ok<WalletTopUpConfirmation>(value: final confirmation):
        _activeTopUp = confirmation.topUp;
        if (_settleFrom(confirmation.topUp)) {
          if (confirmation.topUp.status == WalletTopUpStatus.paid) {
            // The balance moved; the expense (if any) is already booked.
            unawaited(load());
          }
        } else if (confirmation.awaitingGateway) {
          _stage = WalletTopUpStage.awaitingPayment;
          _awaitingSince = _clock();
          _startPolling();
        } else {
          _stage = WalletTopUpStage.awaitingCode;
        }
      case Error<WalletTopUpConfirmation>(exception: final exception):
        final error = exception is WalletException
            ? exception
            : const WalletException(code: 'network', message: '');
        final latest = error.topUp;
        if (latest != null) {
          _activeTopUp = latest;
        }
        final stillOpen =
            latest == null || latest.status == WalletTopUpStatus.pending;
        if (error.leavesCodeOpen && stillOpen) {
          _codeError = error;
          _stage = WalletTopUpStage.awaitingCode;
          if (error.code != 'otp_rejected' && error.code != 'invalid_otp') {
            // The answer was lost or the gateway was busy: the code may have
            // gone through all the same. Ask before the owner sends it again.
            unawaited(_recheckCodeTopUp());
          }
        } else {
          _verdictError = error;
          if (latest == null || !_settleFrom(latest)) {
            _stage = WalletTopUpStage.failed;
          }
        }
    }
    _notify();
  }

  /// Back from the code to the form — a wrong number, another method. The
  /// payment waiting for that code is called off, so it cannot linger.
  void changeDetails() {
    if (_stage != WalletTopUpStage.awaitingCode) {
      return;
    }
    _cancelWaitingCode();
    _stage = WalletTopUpStage.form;
    _activeTopUp = null;
    _codeError = null;
    _topUpError = null;
    _notify();
  }

  /// Opens (or reopens) the payment page in the browser.
  Future<bool> openCheckout() async {
    final url = _checkoutUrl;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      _checkoutOpenFailed = true;
      _notify();
      return false;
    }
    final opened = await _launchCheckout(uri);
    _checkoutOpenFailed = !opened;
    _notify();
    return opened;
  }

  /// Asks once where the active top-up stands. Called by the poll, and by the
  /// sheet when the app comes back to the front after the browser.
  Future<void> checkActiveTopUp() async {
    final topUp = _activeTopUp;
    if (topUp == null || _isChecking || !_following) {
      return;
    }
    _isChecking = true;
    final result = await _repository.loadTopUp(topUp.id);
    _isChecking = false;
    if (_disposed || !_following) {
      return;
    }
    switch (result) {
      case Ok<WalletTopUp>(value: final latest):
        _activeTopUp = latest;
        if (_settleFrom(latest)) {
          _stopPolling();
          if (latest.status == WalletTopUpStatus.paid) {
            // The balance moved; the expense (if any) is already booked.
            unawaited(load());
          }
        } else {
          _rescheduleIfSlowing();
        }
      case Error<WalletTopUp>():
        // A blip in the connection is not a verdict; keep asking.
        break;
    }
    _giveUpIfTooLong();
    _notify();
  }

  /// Waiting on someone else's verdict: the gateway's, or the company's team.
  bool get _following =>
      _stage == WalletTopUpStage.awaitingPayment ||
      _stage == WalletTopUpStage.awaitingReview;

  /// From the amount to the transfer step: our account, the owner's, and the
  /// receipt.
  void beginBankTransfer(double amount) {
    if (_stage != WalletTopUpStage.form) {
      return;
    }
    _transferAmount = amount;
    _topUpError = null;
    transfer.prepare(_overview?.topUpOptions?.bankTransfer);
    _stage = WalletTopUpStage.bankTransfer;
    _notify();
  }

  /// Back from the transfer step to change the amount or the method.
  void backToTopUpForm() {
    if (_stage != WalletTopUpStage.bankTransfer) {
      return;
    }
    _stage = WalletTopUpStage.form;
    _notify();
  }

  /// The amount as the transfer is sent: the wallet's decimals.
  String transferAmountText() => walletAmountText(
    _transferAmount ?? 0,
    _overview?.topUpOptions?.maxDecimals ?? 2,
  );

  void _followTransfer(WalletTopUp topUp, bool recordAsExpense) {
    if (_disposed) {
      return;
    }
    _activeTopUp = topUp;
    _recordAsExpense = recordAsExpense;
    _rememberSettingChoice();
    if (!_settleFrom(topUp)) {
      _stage = WalletTopUpStage.awaitingReview;
      _awaitingSince = _clock();
      _startPolling();
    }
    _notify();
  }

  /// Leaves the flow: stops asking. A payment still under way is not lost —
  /// the backend's sync books it, and the wallet shows it on the next load. A
  /// payment still waiting for its code is called off.
  void endTopUp() {
    // Past the form, a top-up exists: reload so the wallet shows where it
    // stands (paid, or still waiting on the gateway).
    final topUpStarted =
        _stage != WalletTopUpStage.form &&
        _stage != WalletTopUpStage.starting &&
        _stage != WalletTopUpStage.bankTransfer;
    if (_stage == WalletTopUpStage.awaitingCode) {
      _cancelWaitingCode();
    }
    _stopPolling();
    _stage = WalletTopUpStage.form;
    if (topUpStarted) {
      unawaited(load());
    }
    _notify();
  }

  void _cancelWaitingCode() {
    final topUp = _activeTopUp;
    if (topUp != null) {
      // Best effort: if it fails, the relay's expiry writes the top-up off.
      unawaited(_repository.cancelTopUp(topUp.id));
    }
  }

  /// After a code whose answer was lost: if the payment went through, say so
  /// instead of asking for the code again.
  Future<void> _recheckCodeTopUp() async {
    final topUp = _activeTopUp;
    if (topUp == null) {
      return;
    }
    final result = await _repository.loadTopUp(topUp.id);
    if (_disposed || _stage != WalletTopUpStage.awaitingCode) {
      return;
    }
    if (result case Ok<WalletTopUp>(value: final latest)) {
      if (latest.status != WalletTopUpStatus.pending && _settleFrom(latest)) {
        _activeTopUp = latest;
        _codeError = null;
        if (latest.status == WalletTopUpStatus.paid) {
          unawaited(load());
        }
        _notify();
      }
    }
  }

  /// Moves the stage to the verdict [topUp] carries. False while undecided.
  bool _settleFrom(WalletTopUp topUp) {
    switch (topUp.status) {
      case WalletTopUpStatus.paid:
        _stage = WalletTopUpStage.paid;
        return true;
      case WalletTopUpStatus.canceled:
        _stage = WalletTopUpStage.canceled;
        return true;
      case WalletTopUpStatus.failed:
        _stage = WalletTopUpStage.failed;
        return true;
      case WalletTopUpStatus.expired:
        _stage = WalletTopUpStage.unconfirmed;
        return true;
      case WalletTopUpStatus.rejected:
        _stage = WalletTopUpStage.rejected;
        return true;
      case WalletTopUpStatus.pending:
      case WalletTopUpStatus.review:
      case WalletTopUpStatus.unknown:
        return false;
    }
  }

  void _rememberSettingChoice() {
    final overview = _overview;
    if (overview == null ||
        overview.settings.recordTopUpsAsExpenses == _recordAsExpense) {
      return;
    }
    // The backend saved the sheet's choice as the new default.
    _overview = overview.copyWith(
      settings: WalletSettings(
        recordTopUpsAsExpenses: _recordAsExpense,
        expenseCategoryId: overview.settings.expenseCategoryId,
        expenseCategoryName: overview.settings.expenseCategoryName,
        defaultExpenseCategoryName:
            overview.settings.defaultExpenseCategoryName,
      ),
    );
  }

  Duration get _giveUpAfter {
    final ttl =
        _overview?.topUpOptions?.pendingTtl ?? const Duration(minutes: 30);
    return ttl + const Duration(minutes: 2);
  }

  void _startPolling() {
    _stopPolling();
    if (_disposed || !_following) {
      return;
    }
    _pollTimer = Timer.periodic(_currentPollInterval, (_) {
      unawaited(checkActiveTopUp());
    });
    _pollingSlowly = _currentPollInterval == slowPollInterval;
  }

  bool _pollingSlowly = false;

  Duration get _currentPollInterval {
    // A person checks a transfer; there is no point asking every 3 seconds.
    if (_stage == WalletTopUpStage.awaitingReview) {
      return slowPollInterval;
    }
    final since = _awaitingSince;
    if (since == null || _clock().difference(since) < fastPollFor) {
      return fastPollInterval;
    }
    return slowPollInterval;
  }

  void _rescheduleIfSlowing() {
    if (_pollTimer != null &&
        !_pollingSlowly &&
        _currentPollInterval == slowPollInterval) {
      _startPolling();
    }
  }

  void _giveUpIfTooLong() {
    final since = _awaitingSince;
    if (_stage == WalletTopUpStage.awaitingPayment &&
        since != null &&
        _clock().difference(since) >= _giveUpAfter) {
      _stopPolling();
      _stage = WalletTopUpStage.unconfirmed;
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // --- history ------------------------------------------------------------

  final List<WalletTopUp> _historyTopUps = [];
  bool _historyTopUpsHasMore = true;
  bool _isLoadingHistoryTopUps = false;
  bool _historyTopUpsFailed = false;

  List<WalletTopUp> get historyTopUps => List.unmodifiable(_historyTopUps);
  bool get historyTopUpsHasMore => _historyTopUpsHasMore;
  bool get isLoadingHistoryTopUps => _isLoadingHistoryTopUps;
  bool get historyTopUpsFailed => _historyTopUpsFailed;

  Future<void> loadHistoryTopUps({bool reset = false}) async {
    if (_isLoadingHistoryTopUps || (!reset && !_historyTopUpsHasMore)) {
      return;
    }
    _isLoadingHistoryTopUps = true;
    _historyTopUpsFailed = false;
    _notify();
    final before = reset || _historyTopUps.isEmpty
        ? null
        : _historyTopUps.last.id;
    final result = await _repository.loadTopUps(before: before);
    switch (result) {
      case Ok<WalletPage<WalletTopUp>>(value: final page):
        if (reset) {
          _historyTopUps.clear();
        }
        _historyTopUps.addAll(page.items);
        _historyTopUpsHasMore = page.hasMore;
      case Error<WalletPage<WalletTopUp>>():
        // A failed page keeps "more" on: the next scroll retries it instead
        // of the list ending where the network blinked.
        _historyTopUpsFailed = true;
    }
    _isLoadingHistoryTopUps = false;
    _notify();
  }

  final List<WalletEntry> _historyEntries = [];
  bool _historyEntriesHasMore = true;
  bool _isLoadingHistoryEntries = false;
  bool _historyEntriesFailed = false;

  List<WalletEntry> get historyEntries => List.unmodifiable(_historyEntries);
  bool get historyEntriesHasMore => _historyEntriesHasMore;
  bool get isLoadingHistoryEntries => _isLoadingHistoryEntries;
  bool get historyEntriesFailed => _historyEntriesFailed;

  Future<void> loadHistoryEntries({bool reset = false}) async {
    if (_isLoadingHistoryEntries || (!reset && !_historyEntriesHasMore)) {
      return;
    }
    _isLoadingHistoryEntries = true;
    _historyEntriesFailed = false;
    _notify();
    final before = reset || _historyEntries.isEmpty
        ? null
        : _historyEntries.last.id;
    final result = await _repository.loadEntries(before: before);
    switch (result) {
      case Ok<WalletPage<WalletEntry>>(value: final page):
        if (reset) {
          _historyEntries.clear();
        }
        _historyEntries.addAll(page.items);
        _historyEntriesHasMore = page.hasMore;
      case Error<WalletPage<WalletEntry>>():
        _historyEntriesFailed = true;
    }
    _isLoadingHistoryEntries = false;
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
    _stopPolling();
    spending.dispose();
    transfer.dispose();
    super.dispose();
  }
}

/// An amount as the gateway takes it: at most [decimals] places, without the
/// trailing zeros ("100", "10.5", "10.125").
String walletAmountText(double amount, int decimals) {
  final fixed = amount.toStringAsFixed(decimals.clamp(0, 3));
  if (!fixed.contains('.')) {
    return fixed;
  }
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _randomAttemptKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'app-topup-$hex';
}
