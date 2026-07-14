import 'dart:async';

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
  }) : _service = service,
       _discovery = discovery,
       _storage = storage,
       _status = status,
       _relayTicketRefreshClient =
           relayTicketRefreshClient ?? RelayTicketRefreshClient();

  final PosApiService _service;
  final BackendDiscoveryService _discovery;
  final ConnectionProfileStorage _storage;
  final ConnectionStatusController? _status;
  final RelayTicketRefreshClient _relayTicketRefreshClient;
  bool _isPairing = false;
  bool _isDiscovering = false;
  bool _disposed = false;
  DateTime? _lastFailureRecoveryAt;
  Timer? _refreshTimer;

  static const _refreshSkew = Duration(minutes: 5);

  /// How long to ignore repeated "local target unreachable" signals after
  /// kicking a recovery, so a burst of failing requests triggers one sweep, not
  /// dozens.
  static const _failureRecoveryDebounce = Duration(seconds: 8);

  /// Backoff schedule for the background recovery that runs after the fast
  /// startup path misses. Bounded — resume/failure triggers cover the long tail
  /// so we never spin forever draining battery.
  static const _recoveryBackoffs = <Duration>[
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 6),
  ];

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

    // Fast path missed. Fall back to the relay if we can, and keep hunting for
    // the LAN backend in the background regardless (sweep + retries).
    if (profile != null && profile.hasUsableRelayTarget) {
      _configureRelay(profile);
      _scheduleRefresh(profile);
      _status?.update(
        ConnectionPhase.connectedRelay,
        shopName: profile.shopName,
      );
      _startBackgroundRecovery();
      return;
    }

    if (profile != null) {
      // No LAN backend found: fall back to the relay. When the stored profile
      // never learned a relay URL (e.g. it paired before the backend reported
      // one), default to the production relay endpoint. The refresh below still
      // requires a stored relay refresh token, so unpaired devices are no-ops.
      final relayProfile = profile.relayApiBaseUrl.trim().isEmpty
          ? profile.copyWith(relayApiBaseUrl: kDefaultRelayApiBaseUrl)
          : profile;
      final activated = await _refreshRelayTicketRemotely(
        relayProfile,
        activateRelay: true,
      );
      if (activated != null && _service.usesRelay) {
        _status?.update(
          ConnectionPhase.connectedRelay,
          shopName: activated.shopName,
        );
      } else {
        _status?.update(
          ConnectionPhase.needsManual,
          shopName: profile.shopName,
        );
      }
      _startBackgroundRecovery();
      return;
    }

    // Fresh install with no LAN backend and no relay: let the user connect
    // manually while the background sweep keeps looking.
    _status?.update(ConnectionPhase.needsManual);
    _startBackgroundRecovery();
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

  /// Debounced hook for [PosApiService.onLocalTargetUnreachable]: a failing LAN
  /// request kicks one background re-discovery, not one per failed request.
  void notifyLocalTargetUnreachable() {
    if (_isDiscovering) {
      return;
    }
    final now = DateTime.now();
    final last = _lastFailureRecoveryAt;
    if (last != null && now.difference(last) < _failureRecoveryDebounce) {
      return;
    }
    _lastFailureRecoveryAt = now;
    unawaited(rediscover());
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

  void _startBackgroundRecovery() {
    unawaited(_backgroundRecovery());
  }

  Future<void> _backgroundRecovery() async {
    for (final backoff in _recoveryBackoffs) {
      if (_disposed) {
        return;
      }
      if (backoff > Duration.zero) {
        await Future<void>.delayed(backoff);
        if (_disposed) {
          return;
        }
      }
      if (await rediscover(includeSweep: true)) {
        return;
      }
    }
  }

  Future<void> _applyLocalEndpoint(
    PointyBackendEndpoint endpoint,
    ConnectionProfile? profile,
  ) async {
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
