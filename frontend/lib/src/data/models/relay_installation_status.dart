/// Snapshot of the shop's relay installation as reported by
/// `GET /api/relay/installation/` — the installation ID the owner sends to
/// support plus where each service stands: remote access and the assistant
/// (granted by the company's subscription or paid from the Daftar wallet) and
/// SMS (paid per message from the SMS balance). Read-only: the relay control
/// server owns this state and the backend mirrors it.
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
    this.smsEnabled = false,
    this.subscriptionEndsAt,
    this.remoteAccessUntil,
    this.aiUntil,
    bool? aiAvailable,
    bool? smsAvailable,
    this.lastSyncedAt,
    this.connectorLastSeenAt,
    this.connectorVersion = '',
  }) : _aiAvailable = aiAvailable,
       _smsAvailable = smsAvailable;

  /// Whether a relay installation has been provisioned at all. When false the
  /// shop has never been linked to the relay and there is no installation ID.
  final bool configured;

  /// Backend-computed: the subscription includes remote access, or the shop
  /// paid for it from the wallet.
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

  /// SMS feature flag on the installation (messages go out through the relay
  /// on the company's provider account, so the subscription carries them).
  final bool smsEnabled;

  /// When the shared subscription lapses. Null means no expiry (perpetual).
  final DateTime? subscriptionEndsAt;

  /// When remote access stops, whoever pays for it — null while it is not
  /// running, or when it runs with no end.
  final DateTime? remoteAccessUntil;

  /// The same for the assistant.
  final DateTime? aiUntil;

  final bool? _aiAvailable;
  final bool? _smsAvailable;

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

  /// The backend's `relay_ai_available`: the subscription includes the
  /// assistant or the shop paid for it from the wallet. A backend from before
  /// the wallet sends nothing, and the old rule is read off the flags. The
  /// 5h/weekly usage call is only meaningful when this holds.
  bool get aiAvailable =>
      _aiAvailable ?? (aiEnabled && subscriptionActive && !subscriptionExpired);

  /// Whether SMS can be sent: the SMS balance pays for a message (or, from a
  /// backend before the SMS balance, the subscription includes SMS). The shop
  /// can still have switched SMS off.
  bool get smsAvailable =>
      _smsAvailable ??
      (smsEnabled && subscriptionActive && !subscriptionExpired);

  /// Remote access or the assistant runs right now, whoever pays for it.
  bool get anyPlanActive => remoteAccessSupported || aiAvailable;

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
      smsEnabled: _bool(json['sms_enabled']),
      subscriptionEndsAt: _dateTime(json['subscription_ends_at']),
      remoteAccessUntil: _dateTime(json['remote_access_until']),
      aiUntil: _dateTime(json['ai_until']),
      aiAvailable: json.containsKey('ai_available')
          ? _bool(json['ai_available'])
          : null,
      smsAvailable: json.containsKey('sms_available')
          ? _bool(json['sms_available'])
          : null,
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
