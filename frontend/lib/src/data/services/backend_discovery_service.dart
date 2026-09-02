import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'backend_discovery_udp_stub.dart'
    if (dart.library.io) 'backend_discovery_udp_io.dart';
import 'subnet_sweep_stub.dart' if (dart.library.io) 'subnet_sweep_io.dart';

/// The loopback fallbacks, ordered so a **web** build never adopts a backend on
/// a different host than the page it was served from.
///
/// `127.0.0.1` and `localhost` are the same machine, but to a browser they are
/// different *sites*. A page on one that adopts an API on the other is handed a
/// `SameSite=Lax` session cookie it will never send back: the login POST
/// succeeds and every request after it comes back 401, which reads exactly like
/// a wrong password. Both used to be raced, so which one won — and therefore
/// whether the web build worked at all — was down to whichever probe answered
/// first.
///
/// So on web the candidate is derived from the page's own host, which keeps the
/// session same-site whatever the app is served from (127.0.0.1, localhost, or
/// a LAN address in front of a separate backend port). Native builds have no
/// such constraint and keep both.
List<String> loopbackApiBaseUrls({
  required bool isWeb,
  required String pageHost,
}) {
  const both = ['http://127.0.0.1:8000/api', 'http://localhost:8000/api'];
  if (!isWeb) {
    return both;
  }
  if (pageHost.isEmpty) {
    return const [];
  }
  return ['http://$pageHost:8000/api'];
}

/// Takes [isWeb] and [pageHost] as arguments rather than reading `kIsWeb` and
/// `Uri.base` inside, so the web rule above can actually be tested — `kIsWeb` is
/// a compile-time false on the VM the tests run on, which would otherwise make
/// the branch that matters unreachable.
List<String> _loopbackCandidates() =>
    loopbackApiBaseUrls(isWeb: kIsWeb, pageHost: Uri.base.host);

/// UDP broadcast discovery, injectable so tests stay hermetic (no real sockets).
typedef UdpDiscovery = Future<List<Uri>> Function({Duration timeout});

/// /24 subnet sweep, injectable for the same reason.
typedef SubnetSweep =
    Future<List<String>> Function({String? expectedInstallationId});

class PointyBackendEndpoint {
  const PointyBackendEndpoint({
    required this.apiBaseUrl,
    required this.backendUrl,
    required this.shopName,
    required this.installationId,
    required this.remoteAccessSupported,
    required this.relayPublicApiUrl,
  });

  final String apiBaseUrl;
  final String backendUrl;
  final String shopName;
  final String installationId;
  final bool remoteAccessSupported;
  final String relayPublicApiUrl;

  factory PointyBackendEndpoint.fromJson(Map<String, Object?> json) {
    return PointyBackendEndpoint(
      apiBaseUrl: json['api_base_url']?.toString() ?? '',
      backendUrl: json['backend_url']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      installationId: json['installation_id']?.toString() ?? '',
      remoteAccessSupported: _boolFromJson(json['remote_access_supported']),
      relayPublicApiUrl: json['relay_public_api_url']?.toString() ?? '',
    );
  }
}

class BackendDiscoveryService {
  BackendDiscoveryService({
    required http.Client client,
    required String defaultApiBaseUrl,
    this.udpTimeout = const Duration(seconds: 2),
    this.probeTimeout = const Duration(milliseconds: 900),
    UdpDiscovery? udpDiscovery,
    SubnetSweep? subnetSweep,
  }) : _client = client,
       _defaultApiBaseUrl = defaultApiBaseUrl,
       _udpDiscovery = udpDiscovery ?? discoverBackendApiBaseUrls,
       _subnetSweep = subnetSweep ?? sweepSubnetForBackends;

  final http.Client _client;
  final String _defaultApiBaseUrl;

  /// How long the UDP broadcast listens before giving up.
  final Duration udpTimeout;

  /// Per-HTTP-probe timeout. Kept short so a dead stored IP can't stall the
  /// race — it loses to UDP/other candidates instead of gating discovery.
  final Duration probeTimeout;

  final UdpDiscovery _udpDiscovery;
  final SubnetSweep _subnetSweep;

  /// Finds the LAN backend.
  ///
  /// The stored/preferred URLs, the loopback defaults, and UDP broadcast all
  /// race concurrently: the first endpoint that is reachable **and** belongs to
  /// [expectedInstallationId] (the shop we last talked to) wins. This is the
  /// core fix for the "stale IP" problem — a stored IP that has since been
  /// reassigned is just one losing runner in the race, not a gate, and a
  /// different shop's server squatting the old IP is rejected on identity.
  ///
  /// When [includeSweep] is set and the fast path finds nothing, the local /24
  /// is swept in a background isolate — the escape hatch for networks that drop
  /// broadcast entirely.
  Future<PointyBackendEndpoint?> discover({
    List<String> preferredApiBaseUrls = const [],
    String? expectedInstallationId,
    bool includeSweep = false,
  }) async {
    final candidates = _dedupe([
      ...preferredApiBaseUrls,
      _defaultApiBaseUrl,
      ..._loopbackCandidates(),
    ]);

    final fast = await _race([
      for (final candidate in candidates) () => _probe(candidate),
      () => _discoverViaUdp(expectedInstallationId),
    ], expectedInstallationId);
    if (fast != null) {
      return fast;
    }

    if (!includeSweep) {
      return null;
    }

    final sweepUrls = await _sweep(expectedInstallationId);
    return _race([
      for (final url in sweepUrls) () => _probe(url),
    ], expectedInstallationId);
  }

  Future<PointyBackendEndpoint?> _discoverViaUdp(
    String? expectedInstallationId,
  ) async {
    final uris = await _discoverUDP();
    return _race([
      for (final uri in uris) () => _probe(uri.toString()),
    ], expectedInstallationId);
  }

  /// Resolves with the first thunk result that is a non-null, accepted
  /// endpoint, or null once every thunk has finished without one. All thunks
  /// run concurrently.
  Future<PointyBackendEndpoint?> _race(
    List<Future<PointyBackendEndpoint?> Function()> thunks,
    String? expectedInstallationId,
  ) {
    if (thunks.isEmpty) {
      return Future.value(null);
    }
    final completer = Completer<PointyBackendEndpoint?>();
    var remaining = thunks.length;
    for (final thunk in thunks) {
      unawaited(
        Future<void>(() async {
          PointyBackendEndpoint? endpoint;
          try {
            endpoint = await thunk();
          } on Object {
            endpoint = null;
          }
          if (!completer.isCompleted &&
              endpoint != null &&
              _accepts(endpoint, expectedInstallationId)) {
            completer.complete(endpoint);
          }
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }),
      );
    }
    return completer.future;
  }

  /// Whether a reachable endpoint belongs to the shop we expect. A blank
  /// expectation (fresh install) accepts any Pointy backend; a backend that
  /// does not report its installation id (older build) is also accepted so we
  /// never reject a real LAN server on a technicality. Only a *different*
  /// installation id — another shop's server holding the old IP — is rejected.
  bool _accepts(
    PointyBackendEndpoint endpoint,
    String? expectedInstallationId,
  ) {
    if (endpoint.apiBaseUrl.trim().isEmpty) {
      return false;
    }
    final expected = expectedInstallationId?.trim() ?? '';
    if (expected.isEmpty) {
      return true;
    }
    final actual = endpoint.installationId.trim();
    if (actual.isEmpty) {
      return true;
    }
    return actual == expected;
  }

  /// Probes a single URL, whether given by the user or discovered. Exposed for
  /// the manual-connection flow.
  Future<PointyBackendEndpoint?> probe(String rawApiBaseUrl) =>
      _probe(rawApiBaseUrl);

  Future<PointyBackendEndpoint?> _probe(String rawApiBaseUrl) async {
    final apiBaseUrl = _normalizeApiBaseUrl(rawApiBaseUrl);
    if (apiBaseUrl.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse('$apiBaseUrl/discovery/service/');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    try {
      final response = await _client.get(uri).timeout(probeTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        return null;
      }
      final endpoint = PointyBackendEndpoint.fromJson(
        decoded.cast<String, Object?>(),
      );
      if (endpoint.apiBaseUrl.trim().isEmpty) {
        return null;
      }
      return endpoint;
    } on Object {
      return null;
    }
  }

  Future<List<Uri>> _discoverUDP() async {
    try {
      return await _udpDiscovery(timeout: udpTimeout);
    } on Object {
      return const [];
    }
  }

  Future<List<String>> _sweep(String? expectedInstallationId) async {
    try {
      return await _subnetSweep(expectedInstallationId: expectedInstallationId);
    } on Object {
      return const [];
    }
  }

  List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.trim().isNotEmpty && seen.add(_normalizeApiBaseUrl(value)))
          _normalizeApiBaseUrl(value),
    ];
  }
}

/// Normalizes an arbitrary user/stored value into an `.../api` base URL. Adds a
/// missing scheme (`192.168.1.10` → `http://192.168.1.10`), a default backend
/// port when the host has none, and the `/api` suffix. Exposed for the manual
/// connection flow.
String normalizeApiBaseUrl(String value) => _normalizeApiBaseUrl(value);

String _normalizeApiBaseUrl(String value) {
  var trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return '';
  }
  if (!trimmed.contains('://')) {
    trimmed = 'http://$trimmed';
  }
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty && !uri.hasPort && uri.path.isEmpty) {
    // Bare host/IP with no port and no path — default to the backend port.
    trimmed = uri
        .replace(port: 8000)
        .toString()
        .replaceFirst(RegExp(r'/+$'), '');
  }
  if (trimmed.endsWith('/api')) {
    return trimmed;
  }
  return '$trimmed/api';
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}
