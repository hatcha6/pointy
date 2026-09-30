import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/repositories/wallet_repository.dart';

/// Opens the gateway's checkout page. Injected so tests and the preview never
/// leave the app.
typedef WalletCheckoutLauncher = Future<bool> Function(Uri uri);

/// The payer pays on the gateway's own page, in the system browser: card
/// details never pass through Pointy, and it works on every platform the till
/// runs on. The app follows the payment by polling, so nothing is typed back.
Future<bool> openWalletCheckoutInBrowser(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Exception {
    return false;
  }
}

/// Where the top-up sheet is.
enum WalletTopUpStage {
  /// Choosing the amount.
  form,

  /// Asking the gateway for a checkout.
  starting,

  /// The checkout is open; waiting for the payer to come back paid.
  awaitingPayment,
  paid,
  canceled,
  failed,

  /// No verdict came back in time. The payment may still land: the relay
  /// credits a late approval, and the backend's sync books it.
  unconfirmed,
}

/// Drives the wallet on the subscription page: the balance, the top-up flow
/// (start, open the checkout, follow it to a verdict), the auto-expense
/// switch, and the paged history.
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

  /// While the payer is most likely on the checkout, ask often; after that,
  /// ask less — a card payment that has not landed in minutes is rare.
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
  WalletTopUp? _activeTopUp;
  String? _checkoutUrl;
  WalletException? _topUpError;
  bool _checkoutOpenFailed = false;
  bool _recordAsExpense = true;
  String? _attemptKey;
  String? _attemptAmount;
  DateTime? _awaitingSince;
  Timer? _pollTimer;
  bool _isChecking = false;

  WalletTopUpStage get topUpStage => _stage;
  WalletTopUp? get activeTopUp => _activeTopUp;
  String? get checkoutUrl => _checkoutUrl;
  WalletException? get topUpError => _topUpError;

  /// The browser did not open; the sheet offers the link instead.
  bool get checkoutOpenFailed => _checkoutOpenFailed;

  /// Whether THIS top-up goes in the books. Starts at the saved setting; a
  /// change here is saved as the new default when the top-up starts.
  bool get recordAsExpense => _recordAsExpense;

  bool get isPolling => _pollTimer != null;

  /// Opens the sheet on a clean form.
  void beginTopUp() {
    _stopPolling();
    _stage = WalletTopUpStage.form;
    _activeTopUp = null;
    _checkoutUrl = null;
    _topUpError = null;
    _checkoutOpenFailed = false;
    _recordAsExpense = recordTopUpsAsExpenses;
    _notify();
  }

  void setRecordAsExpense(bool value) {
    _recordAsExpense = value;
    _notify();
  }

  /// Asks the gateway for a checkout for [amount] dinars and opens it.
  Future<void> startTopUp(double amount) async {
    if (_stage == WalletTopUpStage.starting) {
      return;
    }
    final amountText = amount.toStringAsFixed(2);
    // One attempt, one key: a retry after a dropped response returns the same
    // checkout instead of a second one. A different amount is a new attempt.
    if (_attemptKey == null || _attemptAmount != amountText) {
      _attemptKey = _newAttemptKey();
      _attemptAmount = amountText;
    }
    _stage = WalletTopUpStage.starting;
    _topUpError = null;
    _checkoutOpenFailed = false;
    _notify();

    final result = await _repository.startTopUp(
      amount: amountText,
      method: WalletTopUpMethod.localBankCards,
      idempotencyKey: _attemptKey!,
      recordAsExpense: _recordAsExpense,
    );
    switch (result) {
      case Ok<WalletTopUpStart>(value: final start):
        _attemptKey = null;
        _activeTopUp = start.topUp;
        _checkoutUrl = start.checkoutUrl.isEmpty
            ? start.topUp.checkoutUrl
            : start.checkoutUrl;
        _rememberSettingChoice();
        if (_settleFrom(start.topUp)) {
          // A replayed key whose top-up already has a verdict.
          _notify();
          return;
        }
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

  /// Opens (or reopens) the checkout page in the browser.
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
    if (topUp == null ||
        _isChecking ||
        _stage != WalletTopUpStage.awaitingPayment) {
      return;
    }
    _isChecking = true;
    final result = await _repository.loadTopUp(topUp.id);
    _isChecking = false;
    if (_disposed || _stage != WalletTopUpStage.awaitingPayment) {
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

  /// Leaves the flow: stops asking. A payment still under way is not lost —
  /// the backend's sync books it, and the wallet shows it on the next load.
  void endTopUp() {
    // Past the form, a top-up exists: reload so the wallet shows where it
    // stands (paid, or still waiting on the gateway).
    final topUpStarted =
        _stage != WalletTopUpStage.form && _stage != WalletTopUpStage.starting;
    _stopPolling();
    _stage = WalletTopUpStage.form;
    if (topUpStarted) {
      unawaited(load());
    }
    _notify();
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
      case WalletTopUpStatus.pending:
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
    if (_disposed || _stage != WalletTopUpStage.awaitingPayment) {
      return;
    }
    _pollTimer = Timer.periodic(_currentPollInterval, (_) {
      unawaited(checkActiveTopUp());
    });
    _pollingSlowly = _currentPollInterval == slowPollInterval;
  }

  bool _pollingSlowly = false;

  Duration get _currentPollInterval {
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
    super.dispose();
  }
}

String _randomAttemptKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'app-topup-$hex';
}
