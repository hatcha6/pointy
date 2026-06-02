import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backend_discovery_udp_stub.dart'
    if (dart.library.io) 'backend_discovery_udp_io.dart';

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
    this.timeout = const Duration(seconds: 2),
  }) : _client = client,
       _defaultApiBaseUrl = defaultApiBaseUrl;

  final http.Client _client;
  final String _defaultApiBaseUrl;
  final Duration timeout;

  Future<PointyBackendEndpoint?> discover({
    List<String> preferredApiBaseUrls = const [],
  }) async {
    final candidates = <String>[
      ...preferredApiBaseUrls,
      _defaultApiBaseUrl,
      'http://127.0.0.1:8000/api',
      'http://localhost:8000/api',
    ];

    for (final candidate in _dedupe(candidates)) {
      final endpoint = await _probe(candidate);
      if (endpoint != null) {
        return endpoint;
      }
    }

    final udpCandidates = await _discoverUDP();
    for (final candidate in udpCandidates) {
      final endpoint = await _probe(candidate.toString());
      if (endpoint != null) {
        return endpoint;
      }
    }
    return null;
  }

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
      final response = await _client.get(uri).timeout(timeout);
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
      return await discoverBackendApiBaseUrls(timeout: timeout);
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

String _normalizeApiBaseUrl(String value) {
  final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return '';
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
