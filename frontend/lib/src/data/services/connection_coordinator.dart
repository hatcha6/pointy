import 'dart:async';

import '../models/connection_profile.dart';
import 'api_session.dart';
import 'backend_discovery_service.dart';
import 'connection_profile_storage.dart';
import 'pos_api_service.dart';

class ConnectionCoordinator {
  ConnectionCoordinator({
    required PosApiService service,
    required BackendDiscoveryService discovery,
    required ConnectionProfileStorage storage,
  }) : _service = service,
       _discovery = discovery,
       _storage = storage;

  final PosApiService _service;
  final BackendDiscoveryService _discovery;
  final ConnectionProfileStorage _storage;
  bool _isPairing = false;

  Future<void> bootstrap() async {
    final profile = await _storage.loadProfile();
    final preferred = [
      if (profile?.localApiBaseUrl.trim().isNotEmpty ?? false)
        profile!.localApiBaseUrl,
    ];
    final endpoint = await _discovery.discover(preferredApiBaseUrls: preferred);
    if (endpoint != null) {
      final localProfile = (profile ?? ConnectionProfile.empty()).copyWith(
        localApiBaseUrl: endpoint.apiBaseUrl,
        installationId: endpoint.installationId,
        shopName: endpoint.shopName,
      );
      await _storage.saveProfile(localProfile);
      _configureLocal(localProfile);
      return;
    }

    if (profile != null && profile.hasUsableRelayTarget) {
      _configureRelay(profile);
    }
  }

  Future<void> pairAuthenticatedDevice() async {
    if (_isPairing || _service.usesRelay) {
      return;
    }
    _isPairing = true;
    try {
      final deviceId = await _storage.loadOrCreateDeviceId();
      final pairing = await _service.requestRelayPairing(deviceId: deviceId);
      final currentProfile = await _storage.loadProfile();
      final profile = ConnectionProfile(
        localApiBaseUrl: _service.baseUrl,
        relayApiBaseUrl: _relayApiBaseUrl(pairing.relayPublicApiUrl),
        relayToken: pairing.hasTicket ? pairing.relayToken : '',
        installationId: pairing.installationId,
        shopName: pairing.shopName,
        relayTokenExpiresAt: pairing.expiresAt,
      );
      await _storage.saveProfile(
        profile.copyWith(
          localApiBaseUrl: profile.localApiBaseUrl.isEmpty
              ? currentProfile?.localApiBaseUrl
              : profile.localApiBaseUrl,
        ),
      );
      _configureLocal(profile);
    } on Object {
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
