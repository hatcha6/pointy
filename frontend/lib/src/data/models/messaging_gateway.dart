/// Client-side mirror of the backend `MessagingGateway` (apps.messaging).
///
/// The send credential (`password`) and webhook signing key are write-only on
/// the server — never returned by GET — so this model only carries `hasPassword`
/// / `hasWebhookSigningKey` flags, while [MessagingGatewayDraft] carries the new
/// secret when the user sets one.
enum MessagingProvider { smsGate, fake, unknown }

MessagingProvider messagingProviderFromJson(Object? value) {
  return switch (value?.toString()) {
    'sms_gate' => MessagingProvider.smsGate,
    'fake' => MessagingProvider.fake,
    _ => MessagingProvider.unknown,
  };
}

String messagingProviderToJson(MessagingProvider provider) {
  return switch (provider) {
    MessagingProvider.fake => 'fake',
    // Unknown falls back to the only real provider so a round-trip never posts
    // an empty provider the backend would reject.
    MessagingProvider.smsGate || MessagingProvider.unknown => 'sms_gate',
  };
}

class MessagingGateway {
  const MessagingGateway({
    required this.id,
    required this.name,
    required this.provider,
    this.baseUrl = '',
    this.username = '',
    this.isDefault = false,
    this.isActive = true,
    this.maxMessagesPerMinute = 6,
    this.dailyCap = 0,
    this.sendTimeoutSeconds = 15,
    this.hasPassword = false,
    this.hasWebhookSigningKey = false,
    this.isActivated = false,
    this.lastError = '',
    this.lastErrorAt,
    this.lastSeenAt,
  });

  final int id;
  final String name;
  final MessagingProvider provider;
  final String baseUrl;
  final String username;
  final bool isDefault;
  final bool isActive;
  final int maxMessagesPerMinute;
  final int dailyCap;
  final int sendTimeoutSeconds;
  final bool hasPassword;
  final bool hasWebhookSigningKey;

  /// Whether the device webhooks were registered (zero-touch activation ran).
  /// Sending works without it, but nothing comes *back* — no inbound SMS and no
  /// delivery receipts — so the settings page surfaces this as its own step.
  final bool isActivated;
  final String lastError;
  final DateTime? lastErrorAt;

  /// Last successful round-trip to the device (a send that the phone accepted,
  /// or an activation). Null means Pointy has never reached it.
  final DateTime? lastSeenAt;

  factory MessagingGateway.fromJson(Map<String, Object?> json) {
    final config =
        (json['config'] as Map?)?.cast<String, Object?>() ?? const {};
    return MessagingGateway(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      provider: messagingProviderFromJson(json['provider']),
      baseUrl: config['base_url']?.toString() ?? '',
      username: config['username']?.toString() ?? '',
      isDefault: _bool(json['is_default']),
      isActive: _bool(json['is_active'], fallback: true),
      maxMessagesPerMinute: _int(json['max_messages_per_minute'], fallback: 6),
      dailyCap: _int(json['daily_cap']),
      sendTimeoutSeconds: _int(json['send_timeout_seconds'], fallback: 15),
      hasPassword: _bool(json['has_password']),
      hasWebhookSigningKey: _bool(json['has_webhook_signing_key']),
      isActivated: _bool(json['is_activated']),
      lastError: json['last_error']?.toString() ?? '',
      lastErrorAt: _dateOrNull(json['last_error_at']),
      lastSeenAt: _dateOrNull(json['last_seen_at']),
    );
  }

  /// Has everything needed to *send*. Two-way messaging additionally requires
  /// [isActivated].
  bool get isConfigured => baseUrl.trim().isNotEmpty && hasPassword;

  /// Fully wired: can send, and the device posts inbound messages and delivery
  /// receipts back to us.
  bool get isReady => isConfigured && isActivated;

  bool get hasError => lastError.trim().isNotEmpty;
}

/// The mutable form payload for creating/updating a gateway. A null [password]
/// means "leave the stored secret unchanged" (write-only field).
class MessagingGatewayDraft {
  const MessagingGatewayDraft({
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.username,
    this.password,
    this.isDefault = true,
    this.isActive = true,
    this.maxMessagesPerMinute = 6,
    this.dailyCap = 0,
    this.sendTimeoutSeconds = 15,
  });

  final String name;
  final MessagingProvider provider;
  final String baseUrl;
  final String username;
  final String? password;
  final bool isDefault;
  final bool isActive;
  final int maxMessagesPerMinute;
  final int dailyCap;
  final int sendTimeoutSeconds;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'provider': messagingProviderToJson(provider),
      'config': {'base_url': baseUrl, 'username': username},
      'is_default': isDefault,
      'is_active': isActive,
      'max_messages_per_minute': maxMessagesPerMinute,
      'daily_cap': dailyCap,
      'send_timeout_seconds': sendTimeoutSeconds,
      if (password != null && password!.isNotEmpty) 'password': password,
    };
  }
}

/// The outcome of a Test-send (a serialized `OutboundMessage`): its final status
/// plus any error, so the panel can show success or the exact failure reason.
class MessagingSendResult {
  const MessagingSendResult({
    required this.status,
    this.errorCode = '',
    this.errorDetail = '',
  });

  final String status;
  final String errorCode;
  final String errorDetail;

  bool get ok => status == 'sent' || status == 'delivered';

  factory MessagingSendResult.fromJson(Map<String, Object?> json) {
    return MessagingSendResult(
      status: json['status']?.toString() ?? '',
      errorCode: json['error_code']?.toString() ?? '',
      errorDetail: json['error_detail']?.toString() ?? '',
    );
  }
}

/// The result of zero-touch activation: whether it succeeded and how many of the
/// device webhooks were registered.
class GatewayActivation {
  const GatewayActivation({
    required this.ok,
    required this.registered,
    required this.total,
  });

  final bool ok;
  final int registered;
  final int total;

  factory GatewayActivation.fromJson(Map<String, Object?> json) {
    final hooks =
        (json['webhooks'] as List?)?.whereType<Map>().toList() ?? const [];
    return GatewayActivation(
      ok: json['ok'] == true,
      registered: hooks.where((hook) => hook['ok'] == true).length,
      total: hooks.length,
    );
  }
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _bool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  return value == null ? fallback : value.toString() == 'true';
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}
