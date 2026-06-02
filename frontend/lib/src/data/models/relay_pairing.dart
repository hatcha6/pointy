class RelayPairing {
  const RelayPairing({
    required this.remoteAccessSupported,
    required this.installationId,
    required this.shopName,
    required this.relayPublicApiUrl,
    required this.relayToken,
    required this.reason,
    this.expiresAt,
  });

  final bool remoteAccessSupported;
  final String installationId;
  final String shopName;
  final String relayPublicApiUrl;
  final String relayToken;
  final String reason;
  final DateTime? expiresAt;

  bool get hasTicket => remoteAccessSupported && relayToken.trim().isNotEmpty;

  factory RelayPairing.fromJson(Map<String, Object?> json) {
    return RelayPairing(
      remoteAccessSupported: _boolFromJson(json['remote_access_supported']),
      installationId: json['installation_id']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      relayPublicApiUrl: json['relay_public_api_url']?.toString() ?? '',
      relayToken: json['relay_token']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      expiresAt: _dateTimeFromJson(json['expires_at']),
    );
  }
}

class RelayPairingRequest {
  const RelayPairingRequest({this.deviceId = '', this.deviceName = ''});

  final String deviceId;
  final String deviceName;

  Map<String, Object?> toJson() {
    return {
      if (deviceId.trim().isNotEmpty) 'device_id': deviceId.trim(),
      if (deviceName.trim().isNotEmpty) 'device_name': deviceName.trim(),
    };
  }
}

bool _boolFromJson(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

DateTime? _dateTimeFromJson(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}
