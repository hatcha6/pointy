import 'package:flutter/foundation.dart';

import '../../../core/error_messages.dart';
import '../../../core/result.dart';
import '../../../data/models/messaging_gateway.dart';
import '../../../data/repositories/messaging_repository.dart';

enum MessagingTestOutcome { none, sending, success, failure }

/// Outcome of the page's primary action (save, then register the device
/// webhooks). "Saved but not activated" is its own state on purpose: the save
/// can succeed against our own database while the phone is unreachable, and
/// telling the shop "saved ✓" there would hide a gateway that can never receive
/// a reply or a delivery report.
enum MessagingConnectOutcome {
  none,
  running,
  connected,
  savedNotActivated,
  failed,
}

/// How far along setup is. Sending only needs [configured]; two-way messaging
/// needs the device webhooks too, which is what [ready] adds.
enum MessagingSetupStage { unconfigured, configured, ready }

/// Why the device address is not usable, for the page to localize.
enum MessagingBaseUrlIssue { none, missing, invalid }

/// Drives the SMS device settings page: loads the shop's default messaging
/// gateway (the SMS Gate phone), edits its connection + pacing config, saves
/// (create or update), registers the device webhooks, and runs a Test-send.
/// A single default gateway is managed here for the common case; the endpoints
/// support multiple.
class MessagingSettingsViewModel extends ChangeNotifier {
  MessagingSettingsViewModel(this._repository);

  final MessagingRepository _repository;

  MessagingGateway? _gateway;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  MessagingTestOutcome _testOutcome = MessagingTestOutcome.none;
  String _testMessage = '';
  MessagingConnectOutcome _connectOutcome = MessagingConnectOutcome.none;
  String _connectDetail = '';
  int _registeredWebhooks = 0;
  bool _isActivating = false;
  int _revision = 0;

  // Editable form state.
  String baseUrl = '';
  String username = '';
  String password = ''; // a new secret; blank = keep the stored one
  int maxMessagesPerMinute = 6;
  int dailyCap = 0;

  // The last saved values, so an edit can be told apart from a reload.
  String _savedBaseUrl = '';
  String _savedUsername = '';
  int _savedMaxPerMinute = 6;
  int _savedDailyCap = 0;

  MessagingGateway? get gateway => _gateway;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasLoadError => _hasLoadError;
  bool get hasGateway => _gateway != null;
  bool get isConfigured => _gateway?.isConfigured ?? false;
  bool get isActivated => _gateway?.isActivated ?? false;
  MessagingTestOutcome get testOutcome => _testOutcome;
  String get testMessage => _testMessage;
  bool get isTesting => _testOutcome == MessagingTestOutcome.sending;
  bool get isActivating => _isActivating;
  bool get isBusy => _isLoading || _isSaving || isTesting || _isActivating;

  MessagingConnectOutcome get connectOutcome => _connectOutcome;

  /// The backend's own explanation of the last failure, when it sent one.
  String get connectDetail => _connectDetail;
  int get registeredWebhooks => _registeredWebhooks;

  /// Bumped whenever server state replaces the form, so the page knows to
  /// re-seed its text controllers (which the view model cannot touch).
  int get revision => _revision;

  MessagingSetupStage get setupStage {
    if (!isConfigured) return MessagingSetupStage.unconfigured;
    return isActivated
        ? MessagingSetupStage.ready
        : MessagingSetupStage.configured;
  }

  /// True while the form holds edits that are not on the server yet. Everything
  /// that acts on the *saved* gateway — Test-send, activation — has to know,
  /// because those run against the stored config, not what is on screen.
  bool get isDirty {
    final gateway = _gateway;
    if (gateway == null) {
      return baseUrl.trim().isNotEmpty ||
          username.trim().isNotEmpty ||
          password.isNotEmpty;
    }
    return normalizeGatewayBaseUrl(baseUrl) != _savedBaseUrl ||
        username.trim() != _savedUsername ||
        password.isNotEmpty ||
        maxMessagesPerMinute != _savedMaxPerMinute ||
        dailyCap != _savedDailyCap;
  }

  MessagingBaseUrlIssue get baseUrlIssue {
    final raw = baseUrl.trim();
    if (raw.isEmpty) return MessagingBaseUrlIssue.missing;
    return isValidGatewayBaseUrl(raw)
        ? MessagingBaseUrlIssue.none
        : MessagingBaseUrlIssue.invalid;
  }

  /// What the address will actually be saved as, once normalized — shown back
  /// to the user when it differs from what they typed, so the correction is
  /// visible rather than silent.
  String get normalizedBaseUrl => normalizeGatewayBaseUrl(baseUrl);

  bool get baseUrlWasNormalized {
    final raw = baseUrl.trim();
    return raw.isNotEmpty &&
        baseUrlIssue == MessagingBaseUrlIssue.none &&
        normalizedBaseUrl != raw;
  }

  /// A gateway with no per-minute ceiling. Legal, and how the backend reads 0 —
  /// but it removes the pacing that keeps a consumer SIM from being flagged as
  /// a spam sender, so the page says so out loud.
  bool get isUnpaced => maxMessagesPerMinute <= 0;

  bool get hasStoredPassword => _gateway?.hasPassword ?? false;

  bool get canSave =>
      !isBusy &&
      isDirty &&
      baseUrlIssue == MessagingBaseUrlIssue.none &&
      (hasStoredPassword || password.isNotEmpty);

  /// Can Test-send: a saved, configured gateway with no unsaved edits — the
  /// Test-send runs on the server against the *persisted* config, so testing a
  /// dirty form would report on settings the user is no longer looking at.
  bool get canTest => _gateway != null && isConfigured && !isDirty && !isBusy;

  /// Can register the device webhooks on their own (no pending edits to save
  /// first). While dirty, the page offers save-then-activate instead.
  bool get canActivate =>
      _gateway != null && isConfigured && !isDirty && !isBusy;

  /// The one primary action: save whatever is pending, then activate. Available
  /// as soon as the form is valid, or whenever an already-saved gateway can be
  /// (re-)activated.
  bool get canConnect => canSave || canActivate;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadGateways();
    switch (result) {
      case Ok<List<MessagingGateway>>(value: final gateways):
        _applyGateway(_pickDefault(gateways));
      case Error<List<MessagingGateway>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// The page's primary action: persist any pending edits, then run zero-touch
  /// activation so the phone posts inbound messages and delivery receipts back
  /// to us. Reports the two failures apart — could not save, versus saved but
  /// could not reach the device.
  Future<MessagingConnectOutcome> connect() async {
    _connectOutcome = MessagingConnectOutcome.running;
    _connectDetail = '';
    _registeredWebhooks = 0;
    notifyListeners();

    if (isDirty || _gateway == null) {
      final saved = await _save();
      if (!saved) {
        _connectOutcome = MessagingConnectOutcome.failed;
        notifyListeners();
        return _connectOutcome;
      }
    }

    final activation = await _activate();
    _connectOutcome = activation != null && activation.ok
        ? MessagingConnectOutcome.connected
        : MessagingConnectOutcome.savedNotActivated;
    _registeredWebhooks = activation?.registered ?? 0;
    notifyListeners();
    return _connectOutcome;
  }

  Future<GatewayActivation?> _activate() async {
    final gateway = _gateway;
    if (gateway == null) return null;
    _isActivating = true;
    notifyListeners();

    final result = await _repository.activate(gateway.id);
    GatewayActivation? activation;
    switch (result) {
      case Ok<GatewayActivation>(value: final value):
        activation = value;
      case Error<GatewayActivation>(exception: final exception):
        _connectDetail = backendDetailFor(exception) ?? '';
    }

    _isActivating = false;
    notifyListeners();
    if (activation != null) {
      // Re-read so the page reflects the server's view of activation rather
      // than assuming it from a 200.
      await load();
    }
    return activation;
  }

  MessagingGateway? _pickDefault(List<MessagingGateway> gateways) {
    if (gateways.isEmpty) return null;
    return gateways.firstWhere(
      (gateway) => gateway.isDefault,
      orElse: () => gateways.first,
    );
  }

  void _applyGateway(MessagingGateway? gateway) {
    _gateway = gateway;
    baseUrl = gateway?.baseUrl ?? '';
    username = gateway?.username ?? '';
    password = '';
    maxMessagesPerMinute = gateway?.maxMessagesPerMinute ?? 6;
    dailyCap = gateway?.dailyCap ?? 0;
    _savedBaseUrl = baseUrl;
    _savedUsername = username;
    _savedMaxPerMinute = maxMessagesPerMinute;
    _savedDailyCap = dailyCap;
    _testOutcome = MessagingTestOutcome.none;
    _testMessage = '';
    _revision++;
  }

  /// Any edit invalidates the previous outcome banners — they describe a state
  /// the form has moved on from.
  void _onEdited() {
    if (_connectOutcome != MessagingConnectOutcome.none) {
      _connectOutcome = MessagingConnectOutcome.none;
      _connectDetail = '';
    }
    if (_testOutcome != MessagingTestOutcome.none) {
      _testOutcome = MessagingTestOutcome.none;
      _testMessage = '';
    }
    notifyListeners();
  }

  void setBaseUrl(String value) {
    baseUrl = value.trim();
    _onEdited();
  }

  void setUsername(String value) {
    username = value;
    _onEdited();
  }

  void setPassword(String value) {
    password = value;
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

  Future<bool> _save() async {
    if (!canSave) return false;
    _isSaving = true;
    notifyListeners();

    final existing = _gateway;
    final draft = MessagingGatewayDraft(
      name: (existing != null && existing.name.isNotEmpty)
          ? existing.name
          : 'هاتف الرسائل',
      provider: existing?.provider ?? MessagingProvider.smsGate,
      // Normalized, not raw: the driver appends its own path, so a missing
      // scheme or a pasted "/message" suffix would fail at send time as an
      // unreachable device — a network symptom for what is really a typo.
      baseUrl: normalizeGatewayBaseUrl(baseUrl),
      username: username.trim(),
      password: password.isEmpty ? null : password,
      isDefault: true,
      isActive: true,
      maxMessagesPerMinute: maxMessagesPerMinute,
      dailyCap: dailyCap,
    );

    final Result<MessagingGateway> result = existing == null
        ? await _repository.createGateway(draft)
        : await _repository.updateGateway(existing.id, draft);

    var ok = false;
    switch (result) {
      case Ok<MessagingGateway>(value: final saved):
        _applyGateway(saved);
        ok = true;
      case Error<MessagingGateway>(exception: final exception):
        _connectDetail = backendDetailFor(exception) ?? '';
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  Future<void> sendTest(String phone) async {
    final gateway = _gateway;
    if (gateway == null || phone.trim().isEmpty) return;
    _testOutcome = MessagingTestOutcome.sending;
    _testMessage = '';
    notifyListeners();

    final result = await _repository.testSend(id: gateway.id, to: phone.trim());
    switch (result) {
      case Ok<MessagingSendResult>(value: final sendResult):
        if (sendResult.ok) {
          _testOutcome = MessagingTestOutcome.success;
          _testMessage = '';
        } else {
          _testOutcome = MessagingTestOutcome.failure;
          _testMessage = sendResult.errorDetail.isNotEmpty
              ? sendResult.errorDetail
              : sendResult.errorCode;
        }
      case Error<MessagingSendResult>(exception: final exception):
        _testOutcome = MessagingTestOutcome.failure;
        _testMessage = backendDetailFor(exception) ?? '';
    }
    notifyListeners();

    // A send is also the truest health probe we have, so refresh to pick up the
    // gateway's cleared (or newly set) last_error. Reloading resets the test
    // banner along with the rest of the form, so the outcome the user just
    // asked for is carried across and restored.
    final outcome = _testOutcome;
    final message = _testMessage;
    await load();
    _testOutcome = outcome;
    _testMessage = message;
    notifyListeners();
  }
}

const _defaultGatewayPort = 8080;

/// Paths people paste from the SMS Gate docs, whose example endpoint URL is
/// `http://<ip>:8080/message`. The driver appends its own path, so leaving one
/// on the base URL produces `/message/messages` and a 404 at send time.
const _redundantPaths = {'/message', '/messages'};

/// Turns whatever the user typed into the base URL the driver can actually use:
/// adds the `http://` scheme and the default `:8080` port, and drops a trailing
/// slash or a pasted endpoint path.
///
/// Kept pure and top-level so it can be tested directly — this is the single
/// highest-traffic source of "the phone is unreachable" reports that are really
/// a mistyped address.
String normalizeGatewayBaseUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (!text.contains('://')) {
    text = 'http://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return text;

  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (_redundantPaths.contains(path.toLowerCase())) {
    path = '';
  }

  final port = uri.hasPort ? uri.port : _defaultGatewayPort;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  return '$scheme://$host:$port$path';
}

/// A LAN host: an IPv4/IPv6 address or a hostname. Anything else — spaces,
/// Arabic text, a stray sentence — arrives percent-encoded in [Uri.host] rather
/// than failing to parse, so checking the parse alone would call it valid.
final _hostPattern = RegExp(r'^[A-Za-z0-9.\-:]+$');

/// Whether [raw] resolves to something the driver can POST to.
bool isValidGatewayBaseUrl(String raw) {
  if (raw.trim().isEmpty) return false;
  final uri = Uri.tryParse(normalizeGatewayBaseUrl(raw));
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return _hostPattern.hasMatch(uri.host);
}
