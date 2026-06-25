/// Snapshot of the shop's relay installation as reported by
/// `GET /api/relay/installation/` — the installation ID the owner sends to
/// support plus the entitlement flags (remote access + AI) and the shared
/// subscription expiry. Read-only: the relay control server owns this state and
/// the backend mirrors it.
class RelayInstallationStatus {
  const RelayInstallationStatus({
    required this.configured,
    required this.remoteAccessSupported,
    required this.installationId,
    required this.shopName,
    required this.relayPublicApiUrl,
    required this.relayConnectorAddress,
    required this.relayEnabled,
    required this.subscriptionActive,
    required this.aiEnabled,
    this.subscriptionEndsAt,
    this.lastSyncedAt,
    this.connectorLastSeenAt,
    this.connectorVersion = '',
  });

  /// Whether a relay installation has been provisioned at all. When false the
  /// shop has never been linked to the relay and there is no installation ID.
  final bool configured;

  /// Backend-computed: relay enabled + active, unexpired subscription.
  final bool remoteAccessSupported;

  /// The stable identifier the owner sends to support to activate or renew.
  final String installationId;
  final String shopName;
  final String relayPublicApiUrl;
  final String relayConnectorAddress;

  /// Remote-access feature flag on the installation.
  final bool relayEnabled;

  /// Whether the (shared) subscription is currently marked active.
  final bool subscriptionActive;

  /// AI-assistant feature flag on the installation.
  final bool aiEnabled;

  /// When the shared subscription lapses. Null means no expiry (perpetual).
  final DateTime? subscriptionEndsAt;

  /// When the backend last refreshed this snapshot from the relay.
  final DateTime? lastSyncedAt;

  /// When the remote-access connector last checked in. Null if it never has.
  final DateTime? connectorLastSeenAt;
  final String connectorVersion;

  bool get hasInstallationId => installationId.trim().isNotEmpty;

  /// True once a subscription end date is in the past.
  bool get subscriptionExpired =>
      subscriptionEndsAt != null &&
      !subscriptionEndsAt!.isAfter(DateTime.now());

  /// Mirrors the backend's `relay_ai_available`: AI flag + active, unexpired
  /// subscription. The 5h/weekly usage call is only meaningful when this holds.
  bool get aiAvailable =>
      aiEnabled && subscriptionActive && !subscriptionExpired;

  /// Whole days until the subscription lapses (negative once expired). Null when
  /// there is no end date.
  int? get daysUntilExpiry {
    final endsAt = subscriptionEndsAt;
    if (endsAt == null) {
      return null;
    }
    final now = DateTime.now();
    return endsAt.difference(now).inDays;
  }

  factory RelayInstallationStatus.fromJson(Map<String, Object?> json) {
    return RelayInstallationStatus(
      configured: _bool(json['configured']),
      remoteAccessSupported: _bool(json['remote_access_supported']),
      installationId: json['installation_id']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      relayPublicApiUrl: json['relay_public_api_url']?.toString() ?? '',
      relayConnectorAddress: json['relay_connector_address']?.toString() ?? '',
      relayEnabled: _bool(json['relay_enabled']),
      subscriptionActive: _bool(json['subscription_active']),
      aiEnabled: _bool(json['ai_enabled']),
      subscriptionEndsAt: _dateTime(json['subscription_ends_at']),
      lastSyncedAt: _dateTime(json['last_synced_at']),
      connectorLastSeenAt: _dateTime(json['connector_last_seen_at']),
      connectorVersion: json['connector_version']?.toString() ?? '',
    );
  }
}

bool _bool(Object? value) {
  if (value is bool) {
    return value;
  }
  return value?.toString() == 'true';
}

DateTime? _dateTime(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw)?.toLocal();
}
