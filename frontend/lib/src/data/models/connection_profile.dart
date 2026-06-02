class ConnectionProfile {
  const ConnectionProfile({
    required this.localApiBaseUrl,
    required this.relayApiBaseUrl,
    required this.relayToken,
    required this.installationId,
    required this.shopName,
    this.relayRefreshToken = '',
    this.relayTokenExpiresAt,
    this.relayRefreshExpiresAt,
  });

  final String localApiBaseUrl;
  final String relayApiBaseUrl;
  final String relayToken;
  final String installationId;
  final String shopName;
  final String relayRefreshToken;
  final DateTime? relayTokenExpiresAt;
  final DateTime? relayRefreshExpiresAt;

  bool get hasLocalTarget => localApiBaseUrl.trim().isNotEmpty;

  bool get hasUsableRelayTarget {
    return hasUsableRelayTargetAt(DateTime.now().toUtc());
  }

  bool hasUsableRelayTargetAt(DateTime now) {
    if (relayApiBaseUrl.trim().isEmpty || relayToken.trim().isEmpty) {
      return false;
    }
    final expiresAt = relayTokenExpiresAt;
    if (expiresAt == null) {
      return true;
    }
    return now.toUtc().isBefore(expiresAt.toUtc());
  }

  bool shouldRefreshRelayTicketAt(DateTime now, Duration refreshSkew) {
    if (relayApiBaseUrl.trim().isEmpty) {
      return false;
    }
    if (relayToken.trim().isEmpty || relayTokenExpiresAt == null) {
      return true;
    }
    return now.toUtc().add(refreshSkew).isAfter(relayTokenExpiresAt!.toUtc());
  }

  bool hasUsableRelayRefreshAt(DateTime now) {
    if (relayApiBaseUrl.trim().isEmpty || relayRefreshToken.trim().isEmpty) {
      return false;
    }
    final expiresAt = relayRefreshExpiresAt;
    if (expiresAt == null) {
      return true;
    }
    return now.toUtc().isBefore(expiresAt.toUtc());
  }

  ConnectionProfile withoutRelayTicket() {
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl,
      relayToken: '',
      installationId: installationId,
      shopName: shopName,
      relayRefreshToken: relayRefreshToken,
      relayRefreshExpiresAt: relayRefreshExpiresAt,
    );
  }

  ConnectionProfile withoutRelayCredentials() {
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl,
      relayToken: '',
      installationId: installationId,
      shopName: shopName,
    );
  }

  ConnectionProfile copyWith({
    String? localApiBaseUrl,
    String? relayApiBaseUrl,
    String? relayToken,
    String? installationId,
    String? shopName,
    String? relayRefreshToken,
    DateTime? relayTokenExpiresAt,
    DateTime? relayRefreshExpiresAt,
  }) {
    return ConnectionProfile(
      localApiBaseUrl: localApiBaseUrl ?? this.localApiBaseUrl,
      relayApiBaseUrl: relayApiBaseUrl ?? this.relayApiBaseUrl,
      relayToken: relayToken ?? this.relayToken,
      installationId: installationId ?? this.installationId,
      shopName: shopName ?? this.shopName,
      relayRefreshToken: relayRefreshToken ?? this.relayRefreshToken,
      relayTokenExpiresAt: relayTokenExpiresAt ?? this.relayTokenExpiresAt,
      relayRefreshExpiresAt:
          relayRefreshExpiresAt ?? this.relayRefreshExpiresAt,
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
      relayRefreshToken: json['relay_refresh_token']?.toString() ?? '',
      relayTokenExpiresAt: _dateTimeFromJson(json['relay_token_expires_at']),
      relayRefreshExpiresAt: _dateTimeFromJson(
        json['relay_refresh_expires_at'],
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'local_api_base_url': localApiBaseUrl,
      'relay_api_base_url': relayApiBaseUrl,
      'relay_token': relayToken,
      'installation_id': installationId,
      'shop_name': shopName,
      'relay_refresh_token': relayRefreshToken,
      'relay_token_expires_at': relayTokenExpiresAt?.toUtc().toIso8601String(),
      'relay_refresh_expires_at': relayRefreshExpiresAt
          ?.toUtc()
          .toIso8601String(),
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
