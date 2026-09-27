import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/clock_time.dart';
import '../../../data/models/messaging_gateway.dart';
import '../../../data/models/messaging_status.dart';
import '../../../data/repositories/messaging_repository.dart';
import '../../../data/services/api_error_detail.dart';

/// Where the shop stands with SMS, in the order the page explains it.
enum MessagingServiceState {
  /// SMS is not in the subscription: a paid add-on to ask support for.
  notSubscribed,

  /// In the subscription, but not set up on Daftar's side yet.
  notReady,

  /// The shop switched it off.
  disabled,
  active,
}

enum MessagingTestOutcome { none, sending, sent, queued, failed }

/// Drives the SMS settings page: reads the service status (entitlement, usage,
/// the texts Daftar sends), edits the shop's own dials on its gateway — the
/// switch, pacing, daily cap, quiet hours for promotions — saves them in one
/// PATCH, and runs a test send.
///
/// There is nothing to connect: the provider account lives on the company's
/// relay, so this is a status page with a few brakes on it.
class MessagingSettingsViewModel extends ChangeNotifier {
  MessagingSettingsViewModel(this._repository);

  final MessagingRepository _repository;

  MessagingServiceStatus? _status;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  int _revision = 0;

  bool _saveFailed = false;
  String _saveErrorCode = '';
  String _saveErrorDetail = '';

  MessagingTestOutcome _testOutcome = MessagingTestOutcome.none;
  String _testBody = '';
  String _testErrorCode = '';
  String _testErrorDetail = '';

  // Editable form state, seeded from the saved gateway.
  bool isActive = true;
  int maxMessagesPerMinute = 30;
  int dailyCap = 0;
  ClockTime? quietHoursStart;
  ClockTime? quietHoursEnd;

  MessagingServiceStatus? get status => _status;
  MessagingGateway? get gateway => _status?.gateway;
  MessagingUsage? get usage => _status?.usage;
  List<MessagingTemplateInfo> get templates => _status?.templates ?? const [];

  /// In the subscription, by the relay's live word when it gave one: a stale
  /// local mirror must not offer dials for a service the relay refuses.
  bool get isEntitled {
    final status = _status;
    return status != null && status.entitled && !status.isRefusedByRelay;
  }

  bool get isTestMode => _status?.testMode ?? false;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasLoadError => _hasLoadError;
  bool get hasStatus => _status != null;
  bool get isTesting => _testOutcome == MessagingTestOutcome.sending;
  bool get isBusy => _isLoading || _isSaving || isTesting;

  /// Bumped whenever server state replaces the form, so the page knows to
  /// re-seed its text controllers (which the view model cannot touch).
  int get revision => _revision;

  MessagingServiceState get serviceState {
    final status = _status;
    if (status == null || !isEntitled) {
      return MessagingServiceState.notSubscribed;
    }
    final gateway = status.gateway;
    if (gateway == null || status.isNotConfigured) {
      return MessagingServiceState.notReady;
    }
    return gateway.isActive
        ? MessagingServiceState.active
        : MessagingServiceState.disabled;
  }

  /// The dials are the shop's to set only once SMS is in its subscription.
  bool get canEdit => isEntitled && gateway != null;

  /// A test send needs the service switched on — as saved, since that is what
  /// the server sends with.
  bool get canTest => canEdit && (gateway?.isActive ?? false);

  /// The relay could not be asked for this month's usage; retrying may help.
  bool get isUsageUnavailable =>
      isEntitled && usage == null && (_status?.isRelayUnreachable ?? false);

  bool get isDirty {
    final gateway = this.gateway;
    if (gateway == null) {
      return false;
    }
    return isActive != gateway.isActive ||
        maxMessagesPerMinute != gateway.maxMessagesPerMinute ||
        dailyCap != gateway.dailyCap ||
        quietHoursStart != gateway.quietHoursStart ||
        quietHoursEnd != gateway.quietHoursEnd;
  }

  /// Quiet hours are both ends or neither, and not the same minute twice: the
  /// server refuses half a window and ignores an empty one.
  bool get hasQuietHoursIssue {
    final start = quietHoursStart;
    final end = quietHoursEnd;
    if (start == null && end == null) {
      return false;
    }
    return start == null || end == null || start == end;
  }

  bool get canSave => canEdit && isDirty && !hasQuietHoursIssue && !isBusy;

  bool get saveFailed => _saveFailed;
  String get saveErrorCode => _saveErrorCode;
  String get saveErrorDetail => _saveErrorDetail;

  MessagingTestOutcome get testOutcome => _testOutcome;

  /// The text the test send delivered (or queued) — the approved template
  /// with the shop's name filled in.
  String get testBody => _testBody;
  String get testErrorCode => _testErrorCode;
  String get testErrorDetail => _testErrorDetail;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadStatus();
    switch (result) {
      case Ok<MessagingServiceStatus>(value: final status):
        _applyStatus(status);
      case Error<MessagingServiceStatus>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// A reload never throws away what the user is typing: with edits pending
  /// only the saved side moves, and the form stays as it is.
  void _applyStatus(MessagingServiceStatus status) {
    final keepEdits = isDirty;
    _status = status;
    if (!keepEdits) {
      _seedForm(status.gateway);
    }
  }

  void _seedForm(MessagingGateway? gateway) {
    isActive = gateway?.isActive ?? true;
    maxMessagesPerMinute = gateway?.maxMessagesPerMinute ?? 30;
    dailyCap = gateway?.dailyCap ?? 0;
    quietHoursStart = gateway?.quietHoursStart;
    quietHoursEnd = gateway?.quietHoursEnd;
    _revision++;
  }

  /// An edit retires the last save's failure: it described a form the user
  /// has moved on from.
  void _onEdited() {
    _saveFailed = false;
    _saveErrorCode = '';
    _saveErrorDetail = '';
    notifyListeners();
  }

  void setActive(bool value) {
    isActive = value;
    _onEdited();
  }

  void setMaxMessagesPerMinute(int value) {
    maxMessagesPerMinute = value < 0 ? 0 : value;
    _onEdited();
  }

  void setDailyCap(int value) {
    dailyCap = value < 0 ? 0 : value;
    _onEdited();
  }

  void setQuietHoursStart(ClockTime? value) {
    quietHoursStart = value;
    _onEdited();
  }

  void setQuietHoursEnd(ClockTime? value) {
    quietHoursEnd = value;
    _onEdited();
  }

  void clearQuietHours() {
    quietHoursStart = null;
    quietHoursEnd = null;
    _onEdited();
  }

  /// Puts the form back to what is saved — the answer to "discard changes?",
  /// so the page's next visit does not open on edits nobody kept.
  void discardEdits() {
    _seedForm(gateway);
    _onEdited();
  }

  Future<bool> save() async {
    final gateway = this.gateway;
    if (gateway == null || !canSave) {
      return false;
    }
    _isSaving = true;
    _saveFailed = false;
    _saveErrorCode = '';
    _saveErrorDetail = '';
    notifyListeners();

    final result = await _repository.updateGateway(
      gateway.id,
      MessagingGatewayUpdate(
        isActive: isActive,
        maxMessagesPerMinute: maxMessagesPerMinute,
        dailyCap: dailyCap,
        quietHoursStart: quietHoursStart,
        quietHoursEnd: quietHoursEnd,
      ),
    );

    var ok = false;
    switch (result) {
      case Ok<MessagingGateway>(value: final saved):
        _status = _status?.withGateway(saved);
        _seedForm(saved);
        ok = true;
      case Error<MessagingGateway>(exception: final exception):
        _saveFailed = true;
        _saveErrorCode = apiErrorCode(exception) ?? '';
        _saveErrorDetail = apiErrorDetail(exception);
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  Future<void> sendTest(String phone) async {
    final gateway = this.gateway;
    final to = phone.trim();
    if (gateway == null || to.isEmpty || !canTest || isBusy) {
      return;
    }
    _testOutcome = MessagingTestOutcome.sending;
    _testBody = '';
    _testErrorCode = '';
    _testErrorDetail = '';
    notifyListeners();

    final result = await _repository.testSend(id: gateway.id, to: to);
    switch (result) {
      case Ok<MessagingSendResult>(value: final sent):
        _testBody = sent.body;
        if (sent.ok) {
          _testOutcome = MessagingTestOutcome.sent;
        } else if (sent.isFailure) {
          _testOutcome = MessagingTestOutcome.failed;
          _testErrorCode = sent.errorCode;
          _testErrorDetail = sent.errorDetail;
        } else {
          _testOutcome = MessagingTestOutcome.queued;
        }
      case Error<MessagingSendResult>(exception: final exception):
        _testOutcome = MessagingTestOutcome.failed;
        _testErrorCode = apiErrorCode(exception) ?? '';
        _testErrorDetail = apiErrorDetail(exception);
    }
    notifyListeners();

    // A send is the truest probe there is: re-read so this month's usage and
    // the gateway's last error reflect it. The test result above stays put.
    await load();
  }
}
