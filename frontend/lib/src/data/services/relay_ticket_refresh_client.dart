import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/relay_pairing.dart';
import 'pos_http_client.dart';

class RelayTicketRefreshException implements Exception {
  const RelayTicketRefreshException({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;

  /// The relay does not know this token — spent, expired, or never issued.
  /// Nothing minted from it will be accepted again.
  bool get isCredentialRejected => statusCode == 401;

  /// The token is fine; the shop's remote-access subscription is not. The
  /// relay answers this before spending the token, so the device keeps its
  /// way back in for when the subscription is restored.
  bool get isSubscriptionInactive => statusCode == 402;

  @override
  String toString() => 'Relay ticket refresh failed with status $statusCode';
}

class RelayTicketRefreshClient {
  RelayTicketRefreshClient({http.Client? client, Duration? timeout})
    : _client = client ?? createPosHttpClient(),
      _timeout = timeout ?? defaultTimeout;

  /// How long one refresh may wait for the relay. The relay answers this
  /// itself, without the shop's uplink, so a long silence is the phone's own
  /// connection — and nothing here set a deadline, so a refresh that hung
  /// held every other pairing attempt behind it until the socket died.
  static const Duration defaultTimeout = Duration(seconds: 15);

  final http.Client _client;
  final Duration _timeout;

  Future<RelayPairing> refreshTicket({
    required String relayApiBaseUrl,
    required String refreshToken,
    RelayPairingRequest request = const RelayPairingRequest(),
  }) async {
    final uri = Uri.parse(
      '${_relayPublicApiUrl(relayApiBaseUrl)}/v1/relay-ticket-refresh',
    );
    final response = await _client
        .post(
          uri,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Pointy-Relay-Refresh-Token': refreshToken.trim(),
          },
          body: jsonEncode(request.toJson()),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RelayTicketRefreshException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body);
    final payload = decoded is Map<String, Object?>
        ? decoded
        : (decoded as Map).cast<String, Object?>();
    return RelayPairing.fromJson({
      'remote_access_supported': true,
      'installation_id': payload['installation_id'],
      'shop_name': '',
      'relay_public_api_url': _relayPublicApiUrl(relayApiBaseUrl),
      'relay_token': payload['token'],
      'issued_at': payload['issued_at'],
      'expires_at': payload['expires_at'],
      'relay_refresh_token': payload['refresh_token'],
      'refresh_expires_at': payload['refresh_expires_at'],
      'reason': '',
    });
  }
}

String _relayPublicApiUrl(String relayApiBaseUrl) {
  var trimmed = relayApiBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.endsWith('/api')) {
    trimmed = trimmed.substring(0, trimmed.length - 4);
  }
  return trimmed;
}
