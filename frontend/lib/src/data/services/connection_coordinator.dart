import 'dart:async';

import '../models/connection_profile.dart';
import '../models/relay_pairing.dart';
import 'api_session.dart';
import 'backend_discovery_service.dart';
import 'connection_profile_storage.dart';
import 'pos_api_service.dart';
import 'relay_endpoints.dart';
import 'relay_ticket_refresh_client.dart';

class ConnectionCoordinator {
  ConnectionCoordinator({
    required PosApiService service,
    required BackendDiscoveryService discovery,
    required ConnectionProfileStorage storage,
    RelayTicketRefreshClient? relayTicketRefreshClient,
  }) : _service = service,
       _discovery = discovery,
       _storage = storage,
       _relayTicketRefreshClient =
           relayTicketRefreshClient ?? RelayTicketRefreshClient();

  final PosApiService _service;
  final BackendDiscoveryService _discovery;
  final ConnectionProfileStorage _storage;
  final RelayTicketRefreshClient _relayTicketRefreshClient;
  bool _isPairing = false;
  Timer? _refreshTimer;

  static const _refreshSkew = Duration(minutes: 5);

  Future<void> bootstrap() async {
    final profile = await _storage.loadProfile();
    final preferred = [
      if (profile?.localApiBaseUrl.trim().isNotEmpty ?? false)
        profile!.localApiBaseUrl,
    ];
    final endpoint = await _discovery.discover(preferredApiBaseUrls: preferred);
    if (endpoint != null) {
      var localProfile = (profile ?? ConnectionProfile.empty()).copyWith(
        localApiBaseUrl: endpoint.apiBaseUrl,
        installationId: endpoint.installationId,
        shopName: endpoint.shopName,
      );
      if (!localProfile.hasUsableRelayTarget) {
        localProfile = localProfile.withoutRelayTicket();
      }
      await _storage.saveProfile(localProfile);
      _configureLocal(localProfile);
      _scheduleRefresh(localProfile);
      return;
    }

    if (profile != null && profile.hasUsableRelayTarget) {
      _configureRelay(profile);
      _scheduleRefresh(profile);
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
      await _refreshRelayTicketRemotely(relayProfile, activateRelay: true);
    }
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
