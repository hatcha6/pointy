import 'dart:async';
import 'dart:math' as math;

import '../models/connection_profile.dart';
import '../models/relay_pairing.dart';
import 'api_session.dart';
import 'backend_discovery_service.dart';
import 'connection_profile_storage.dart';
import 'connection_status_controller.dart';
import 'pos_api_service.dart';
import 'relay_endpoints.dart';
import 'relay_ticket_refresh_client.dart';

class ConnectionCoordinator {
  ConnectionCoordinator({
    required PosApiService service,
    required BackendDiscoveryService discovery,
    required ConnectionProfileStorage storage,
    ConnectionStatusController? status,
    RelayTicketRefreshClient? relayTicketRefreshClient,
    List<Duration> startupRecoveryBackoffs = defaultStartupRecoveryBackoffs,
    List<Duration> localReturnBackoffs = defaultLocalReturnBackoffs,
  }) : _service = service,
       _discovery = discovery,
       _storage = storage,
       _status = status,
       _relayTicketRefreshClient =
           relayTicketRefreshClient ?? RelayTicketRefreshClient(),
       _startupRecoveryBackoffs = startupRecoveryBackoffs,
       _localReturnBackoffs = localReturnBackoffs;

  final PosApiService _service;
  final BackendDiscoveryService _discovery;
  final ConnectionProfileStorage _storage;
  final ConnectionStatusController? _status;
  final RelayTicketRefreshClient _relayTicketRefreshClient;
  final List<Duration> _startupRecoveryBackoffs;
  final List<Duration> _localReturnBackoffs;
  bool _isPairing = false;
  bool _isDiscovering = false;
  bool _disposed = false;
  DateTime? _lastFailureRecoveryAt;
  Timer? _refreshTimer;

  /// Whether the session is on a LAN endpoint this coordinator applied. False
  /// from startup until one is found, and from the moment the session leaves
  /// the LAN — for the relay, or for the manual-address screen.
  bool _onLocal = false;

  /// The hunt for the LAN while [_onLocal] is false: see [_startHunt].
  Timer? _huntTimer;
  List<Duration> _huntSchedule = const [];
  int _huntAttempt = 0;

  static const _refreshSkew = Duration(minutes: 5);

  /// How long to ignore repeated "local target unreachable" signals after
  /// kicking a recovery, so a burst of failing requests triggers one sweep, not
  /// dozens.
  static const _failureRecoveryDebounce = Duration(seconds: 8);

  /// The first looks after a startup that found no LAN backend. Close
  /// together, because the usual reason is a till that booted before the
  /// server's containers did — seconds, not minutes, from answering.
  static const defaultStartupRecoveryBackoffs = <Duration>[
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 6),
  ];

  /// How often to look for the LAN after that, for as long as the session is
  /// off it; the last value repeats. This used to stop after the startup
  /// looks, and a desktop till seldom sees the app-resume signal that was
  /// meant to cover the rest — so a till that booted before the server, or
  /// fell back once, stayed on the internet path all day.
  static const defaultLocalReturnBackoffs = <Duration>[
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(seconds: 300),
  ];

  /// Every Nth look also sweeps the /24, for a server that changed address.
  /// The rest are the cheap race of the stored address, loopback and UDP.
  static const _sweepEveryNthLook = 4;

  Future<void> bootstrap() async {
    _status?.update(ConnectionPhase.connecting);
    final profile = await _storage.loadProfile();

    // Fast path: race the stored IP, the loopback defaults and UDP broadcast.
    // The stored IP is only a hint here — a stale one loses instead of gating.
    final endpoint = await _discover(profile, includeSweep: false);
    if (endpoint != null) {
      await _applyLocalEndpoint(endpoint, profile);
      return;
    }

    // Fast path missed. Use the relay if this device has a way in, otherwise
    // let the user type an address — and either way keep hunting for the LAN
    // backend, quickly at first and then for as long as it takes.
    final startupHunt = [..._startupRecoveryBackoffs, ..._localReturnBackoffs];
    final relayProfile = profile == null ? null : await _moveToRelay(profile);
    if (relayProfile != null) {
      _leaveLocal(
        ConnectionPhase.connectedRelay,
        shopName: relayProfile.shopName,
        hunt: startupHunt,
      );
      return;
    }
    // Fresh install, or no relay credentials: the manual-address screen, with
    // the hunt still running behind it.
    _leaveLocal(
      ConnectionPhase.needsManual,
      shopName: profile?.shopName,
      hunt: startupHunt,
    );
  }

  /// Re-runs discovery (single-flight). On success it swaps the app onto the
  /// freshly found LAN target. Safe to call from anywhere — overlapping
  /// triggers coalesce into the in-flight run. Returns whether a LAN backend
  /// was (re)acquired.
  Future<bool> rediscover({bool includeSweep = true}) async {
    if (_disposed || _isDiscovering) {
      return false;
    }
    _isDiscovering = true;
    _status?.setSearching(true);
    try {
      final profile = await _storage.loadProfile();
      final endpoint = await _discovery.discover(
        preferredApiBaseUrls: _preferredUrls(profile),
        expectedInstallationId: _expectedInstallation(profile),
        includeSweep: includeSweep,
      );
      if (_disposed || endpoint == null) {
        return false;
      }
      await _applyLocalEndpoint(endpoint, profile);
      return true;
    } finally {
      _isDiscovering = false;
      _status?.setSearching(false);
    }
  }

  /// User-supplied escape hatch: connect to an explicitly typed IP or URL. No
  /// identity check — the operator is deliberately overriding, possibly to a
  /// new server. Returns whether the address answered as a Pointy backend.
  Future<bool> connectManually(String urlOrIp) async {
    final normalized = normalizeApiBaseUrl(urlOrIp);
    if (normalized.isEmpty) {
      return false;
    }
    _status?.setSearching(true);
    try {
      final endpoint = await _discovery.probe(normalized);
      if (endpoint == null) {
        return false;
      }
      final profile = await _storage.loadProfile();
      await _applyLocalEndpoint(endpoint, profile);
      return true;
    } finally {
      _status?.setSearching(false);
    }
  }

  /// Hook for [PosApiService.onLocalTargetUnreachable]: a request to the LAN
  /// failed at the transport level, whether or not the relay then answered it.
  ///
  /// The session may already have moved itself onto the relay to answer that
  /// request; the phase says so at once rather than after a rediscovery that
  /// can take seconds, and the hunt for the way back starts. Then one
  /// re-discovery runs — debounced, so a burst of failing requests is one
  /// sweep, not dozens — which either re-finds the LAN or, if the address has
  /// stopped answering and this device has relay credentials, moves the session
  /// to the relay (a phone that walked out of the shop's Wi-Fi).
  void notifyLocalTargetUnreachable() {
    if (_disposed) {
      return;
    }
    if (_onLocal && _service.usesRelay) {
      _leaveLocal(ConnectionPhase.connectedRelay, hunt: _localReturnBackoffs);
    }
    if (_isDiscovering) {
      return;
    }
    final now = DateTime.now();
    final last = _lastFailureRecoveryAt;
    if (last != null && now.difference(last) < _failureRecoveryDebounce) {
      return;
    }
    _lastFailureRecoveryAt = now;
    unawaited(_recoverFromLocalFailure());
  }

  Future<void> _recoverFromLocalFailure() async {
    if (await rediscover()) {
      return;
    }
    // Already on the relay (the session fell back for a request, or an
    // earlier recovery moved it): the hunt is running; nothing to decide.
    if (_disposed || _service.usesRelay) {
      return;
    }
    // Still pointed at a LAN address that does not answer. A timeout never
    // moves the session by itself — a slow LAN backend is the same backend the
    // relay would reach — so the move happens here, once the LAN has also
    // failed to answer discovery.
    final profile = await _storage.loadProfile();
    if (_disposed || profile == null) {
      return;
    }
    final relayProfile = await _moveToRelay(profile);
    if (relayProfile != null) {
      _leaveLocal(
        ConnectionPhase.connectedRelay,
        shopName: relayProfile.shopName,
        hunt: _localReturnBackoffs,
      );
    }
  }

  /// Points the session at the relay if this device has a way in: a ticket
  /// that is still valid, or a refresh token to mint one. Returns the profile
  /// the session is now using, or null when the relay is not an option.
  Future<ConnectionProfile?> _moveToRelay(ConnectionProfile profile) async {
    if (profile.hasUsableRelayTarget) {
      _configureRelay(profile);
      _scheduleRefresh(profile);
      return profile;
    }
    // When the stored profile never learned a relay URL (e.g. it paired before
    // the backend reported one), default to the production relay endpoint. The
    // refresh still requires a stored relay refresh token, so unpaired devices
    // are no-ops.
    final relayProfile = profile.relayApiBaseUrl.trim().isEmpty
        ? profile.copyWith(relayApiBaseUrl: kDefaultRelayApiBaseUrl)
        : profile;
    final activated = await _refreshRelayTicketRemotely(
      relayProfile,
      activateRelay: true,
    );
    return activated != null && _service.usesRelay ? activated : null;
  }

  /// The session is off the LAN — on the relay, or on the manual-address
  /// screen. Say so, and hunt for the LAN on [hunt]'s schedule.
  void _leaveLocal(
    ConnectionPhase phase, {
    String? shopName,
    required List<Duration> hunt,
  }) {
    _onLocal = false;
    _status?.update(phase, shopName: shopName);
    _startHunt(hunt);
  }

  /// Looks for the LAN backend on [schedule] (its last delay repeats) until
  /// one answers, the coordinator is disposed, or something else puts the
  /// session back on the LAN. Every [_sweepEveryNthLook]th look sweeps the /24.
  void _startHunt(List<Duration> schedule) {
    _stopHunt();
    if (_disposed || schedule.isEmpty) {
      return;
    }
    _huntSchedule = schedule;
    _scheduleNextLook();
  }

  void _scheduleNextLook() {
    final delay =
        _huntSchedule[math.min(_huntAttempt, _huntSchedule.length - 1)];
    _huntTimer = Timer(delay, () => unawaited(_look()));
  }

  Future<void> _look() async {
    _huntTimer = null;
    if (_disposed || _onLocal) {
      return;
    }
    final attempt = _huntAttempt++;
    final found = await rediscover(
      includeSweep: attempt % _sweepEveryNthLook == 0,
    );
    // Found, finished, or restarted while this look was in flight.
    if (found || _disposed || _onLocal || _huntTimer != null) {
      return;
    }
    _scheduleNextLook();
  }

  void _stopHunt() {
    _huntTimer?.cancel();
    _huntTimer = null;
    _huntAttempt = 0;
  }

  Future<PointyBackendEndpoint?> _discover(
    ConnectionProfile? profile, {
    required bool includeSweep,
  }) {
    return _discovery.discover(
      preferredApiBaseUrls: _preferredUrls(profile),
      expectedInstallationId: _expectedInstallation(profile),
      includeSweep: includeSweep,
    );
  }

  List<String> _preferredUrls(ConnectionProfile? profile) => [
    if (profile?.localApiBaseUrl.trim().isNotEmpty ?? false)
      profile!.localApiBaseUrl,
  ];

  String? _expectedInstallation(ConnectionProfile? profile) {
    final id = profile?.installationId.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  Future<void> _applyLocalEndpoint(
    PointyBackendEndpoint endpoint,
    ConnectionProfile? profile,
  ) async {
    // A different installation answering where the session already points — a
    // server rebuilt on the same IP and reached through [connectManually]. The
    // session keeps its caches when re-pointed at the same address, so say
    // outright that this is not the backend they came from.
    final knownInstallation = profile?.installationId.trim() ?? '';
    final answeringInstallation = endpoint.installationId.trim();
    if (knownInstallation.isNotEmpty &&
        answeringInstallation.isNotEmpty &&
        knownInstallation != answeringInstallation) {
      _service.forgetBackendState();
    }
    // Preserve stored identity/name if a (possibly older) backend omits them,
    // so the installation id stays stable for the next boot's identity check.
    final installationId = endpoint.installationId.trim().isNotEmpty
        ? endpoint.installationId
        : (profile?.installationId ?? '');
    final shopName = endpoint.shopName.trim().isNotEmpty
        ? endpoint.shopName
        : (profile?.shopName ?? '');
    var localProfile = (profile ?? ConnectionProfile.empty()).copyWith(
      localApiBaseUrl: endpoint.apiBaseUrl,
      installationId: installationId,
      shopName: shopName,
    );
    if (!localProfile.hasUsableRelayTarget) {
      localProfile = localProfile.withoutRelayTicket();
    }
    await _storage.saveProfile(localProfile);
    _onLocal = true;
    _stopHunt();
    _configureLocal(localProfile);
    _scheduleRefresh(localProfile);
    _status?.update(
      ConnectionPhase.connectedLocal,
      shopName: localProfile.shopName,
    );
  }

  Future<void> pairAuthenticatedDevice() async {
    await refreshRelayTicketIfNeeded(force: true);
  }

  Future<void> refreshRelayTicketIfNeeded({bool force = false}) async {
    if (_isPairing) {
      return;
    }
    final currentProfile = await _storage.loadProfile();
    if (!force &&
        currentProfile != null &&
        !currentProfile.shouldRefreshRelayTicketAt(
          DateTime.now().toUtc(),
          _refreshSkew,
        )) {
      _scheduleRefresh(currentProfile);
      return;
    }
    if (_service.usesRelay) {
      _isPairing = true;
      try {
        if (currentProfile != null) {
          await _refreshRelayTicketRemotely(
            currentProfile,
            activateRelay: true,
          );
        }
      } finally {
        _isPairing = false;
      }
      return;
    }
    _isPairing = true;
    try {
      final deviceId = await _storage.loadOrCreateDeviceId();
      final pairing = await _service.requestRelayPairing(deviceId: deviceId);
      final storedProfile = await _storage.loadProfile();
      final profile = _profileFromPairing(
        pairing,
        localApiBaseUrl: _service.baseUrl,
        existingProfile: storedProfile,
      );
      final savedProfile = profile.copyWith(
        localApiBaseUrl: profile.localApiBaseUrl.isEmpty
            ? storedProfile?.localApiBaseUrl
            : profile.localApiBaseUrl,
      );
      await _storage.saveProfile(savedProfile);
      _configureLocal(savedProfile);
      _scheduleRefresh(savedProfile);
    } on Object {
      if (currentProfile != null) {
        await _refreshRelayTicketRemotely(
          currentProfile,
          activateRelay: _service.usesRelay,
        );
      }
      // Discovery and pairing are opportunistic. Normal LAN-only operation
      // should continue when the relay is unavailable or unsubscribed.
    } finally {
      _isPairing = false;
    }
  }

  void _configureLocal(ConnectionProfile profile) {
    _service.configureConnectionTarget(
      baseUrl: profile.localApiBaseUrl,
      fallbackTarget: profile.hasUsableRelayTarget
          ? ApiConnectionTarget(
              baseUrl: profile.relayApiBaseUrl,
              relayToken: profile.relayToken,
              relayTokenExpiresAt: profile.relayTokenExpiresAt,
            )
          : null,
    );
  }

  void _configureRelay(ConnectionProfile profile) {
    _service.configureConnectionTarget(
      baseUrl: profile.relayApiBaseUrl,
      relayToken: profile.relayToken,
    );
  }

  Future<ConnectionProfile?> _refreshRelayTicketRemotely(
    ConnectionProfile profile, {
    required bool activateRelay,
  }) async {
    if (!profile.hasUsableRelayRefreshAt(DateTime.now().toUtc())) {
      final cleared = profile.withoutRelayCredentials();
      await _storage.saveProfile(cleared);
      return null;
    }

    try {
      final deviceId = await _storage.loadOrCreateDeviceId();
      final pairing = await _relayTicketRefreshClient.refreshTicket(
        relayApiBaseUrl: profile.relayApiBaseUrl,
        refreshToken: profile.relayRefreshToken,
        request: RelayPairingRequest(deviceId: deviceId),
      );
      if (!pairing.hasTicket) {
        return null;
      }
      final refreshed = _profileFromPairing(
        pairing,
        localApiBaseUrl: profile.localApiBaseUrl,
        existingProfile: profile,
      );
      await _storage.saveProfile(refreshed);
      if (activateRelay) {
        _configureRelay(refreshed);
      } else {
        _configureLocal(refreshed);
      }
      _scheduleRefresh(refreshed);
      return refreshed;
    } on RelayTicketRefreshException catch (exception) {
      if (exception.isCredentialRejected) {
        await _storage.saveProfile(profile.withoutRelayCredentials());
      }
      return null;
    } on Object {
      return null;
    }
  }

  void _scheduleRefresh(ConnectionProfile profile) {
    _refreshTimer?.cancel();
    final expiresAt = profile.relayTokenExpiresAt;
    if (expiresAt == null || profile.relayToken.trim().isEmpty) {
      return;
    }
    final refreshAt = expiresAt.toUtc().subtract(_refreshSkew);
    final delay = refreshAt.difference(DateTime.now().toUtc());
    _refreshTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(refreshRelayTicketIfNeeded()),
    );
  }

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _stopHunt();
  }
}

ConnectionProfile _profileFromPairing(
  RelayPairing pairing, {
  required String localApiBaseUrl,
  ConnectionProfile? existingProfile,
}) {
  final relayApiBaseUrl = pairing.relayPublicApiUrl.trim().isNotEmpty
      ? _relayApiBaseUrl(pairing.relayPublicApiUrl)
      : (existingProfile?.relayApiBaseUrl.trim().isNotEmpty ?? false)
      ? existingProfile!.relayApiBaseUrl
      : kDefaultRelayApiBaseUrl;
  if (!pairing.hasTicket) {
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl,
      relayToken: '',
      installationId: pairing.installationId.isNotEmpty
          ? pairing.installationId
          : (existingProfile?.installationId ?? ''),
      shopName: pairing.shopName.isNotEmpty
          ? pairing.shopName
          : (existingProfile?.shopName ?? ''),
    );
  }
  return ConnectionProfile(
    localApiBaseUrl: localApiBaseUrl,
    relayApiBaseUrl: relayApiBaseUrl,
    relayToken: pairing.relayToken,
    relayRefreshToken: pairing.hasRefreshToken ? pairing.relayRefreshToken : '',
    installationId: pairing.installationId.isNotEmpty
        ? pairing.installationId
        : (existingProfile?.installationId ?? ''),
    shopName: pairing.shopName.isNotEmpty
        ? pairing.shopName
        : (existingProfile?.shopName ?? ''),
    relayTokenExpiresAt: pairing.expiresAt,
    relayRefreshExpiresAt: pairing.refreshExpiresAt,
  );
}

String _relayApiBaseUrl(String relayPublicApiUrl) {
  final trimmed = relayPublicApiUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return '';
  }
  if (trimmed.endsWith('/api')) {
    return trimmed;
  }
  return '$trimmed/api';
}
