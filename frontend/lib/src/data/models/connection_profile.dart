class ConnectionProfile {
  const ConnectionProfile({
    required this.localApiBaseUrl,
    required this.relayApiBaseUrl,
    required this.relayToken,
    required this.installationId,
    required this.shopName,
    this.relayTokenExpiresAt,
  });

  final String localApiBaseUrl;
  final String relayApiBaseUrl;
  final String relayToken;
  final String installationId;
  final String shopName;
  final DateTime? relayTokenExpiresAt;

  bool get hasLocalTarget => localApiBaseUrl.trim().isNotEmpty;

  bool get hasUsableRelayTarget {
    if (relayApiBaseUrl.trim().isEmpty || relayToken.trim().isEmpty) {
      return false;
    }
    final expiresAt = relayTokenExpiresAt;
    if (expiresAt == null) {
      return true;
    }
    return DateTime.now().toUtc().isBefore(expiresAt.toUtc());
  }

  ConnectionProfile copyWith({
    String? localApiBaseUrl,
    String? relayApiBaseUrl,
    String? relayToken,
    String? installationId,
    String? shopName,
    DateTime? relayTokenExpiresAt,
  }) {
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl ?? this.localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl ?? this.relayApiBaseUrl,
      relayToken: relayToken ?? this.relayToken,
      installationId: installationId ?? this.installationId,
      shopName: shopName ?? this.shopName,
      relayTokenExpiresAt: relayTokenExpiresAt ?? this.relayTokenExpiresAt,
    );
  }

  factory ConnectionProfile.empty() {
    return const ConnectionProfile(
      localApiBaseUrl: '',
      relayApiBaseUrl: '',
      relayToken: '',
      installationId: '',
      shopName: '',
    );
  }

  factory ConnectionProfile.fromJson(Map<String, Object?> json) {
    return ConnectionProfile(
      localApiBaseUrl: json['local_api_base_url']?.toString() ?? '',
      relayApiBaseUrl: json['relay_api_base_url']?.toString() ?? '',
      relayToken: json['relay_token']?.toString() ?? '',
      installationId: json['installation_id']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      relayTokenExpiresAt: _dateTimeFromJson(json['relay_token_expires_at']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'local_api_base_url': localApiBaseUrl,
      'relay_api_base_url': relayApiBaseUrl,
      'relay_token': relayToken,
      'installation_id': installationId,
      'shop_name': shopName,
      'relay_token_expires_at': relayTokenExpiresAt?.toUtc().toIso8601String(),
    };
  }
}

DateTime? _dateTimeFromJson(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}
