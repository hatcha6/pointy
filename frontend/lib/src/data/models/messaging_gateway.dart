import 'clock_time.dart';

/// Client-side mirror of the backend `MessagingGateway` (apps.messaging).
///
/// SMS goes through Daftar's relay to the provider, on the company's account —
/// the same arrangement as the AI assistant — so a gateway carries no address
/// and no credentials any more. What is left is the shop's own dials: the
/// on/off switch, pacing, a daily cap and quiet hours for promotions, plus the
/// last error its sends reported.
enum MessagingProvider { relay, fake, unknown }

MessagingProvider messagingProviderFromJson(Object? value) {
  return switch (value?.toString()) {
    'relay' => MessagingProvider.relay,
    'fake' => MessagingProvider.fake,
    _ => MessagingProvider.unknown,
  };
}

class MessagingGateway {
  const MessagingGateway({
    required this.id,
    required this.name,
    this.provider = MessagingProvider.relay,
    this.isDefault = false,
    this.isActive = true,
    this.maxMessagesPerMinute = 30,
    this.dailyCap = 0,
    this.quietHoursStart,
    this.quietHoursEnd,
    this.sendTimeoutSeconds = 20,
    this.lastError = '',
    this.lastErrorAt,
    this.lastSeenAt,
    this.autoMessages = const {},
  });

  final int id;
  final String name;
  final MessagingProvider provider;
  final bool isDefault;

  /// The shop's own switch. Off means nothing leaves this shop — no invoice,
  /// no reminder, no campaign — whatever the subscription includes.
  final bool isActive;

  /// Send pacing; 0 = no ceiling.
  final int maxMessagesPerMinute;

  /// Messages per shop-local day; 0 = no cap.
  final int dailyCap;

  /// Promotions are held while the shop's clock is inside this window;
  /// invoices and reminders ignore it. See [hasQuietHours].
  final ClockTime? quietHoursStart;
  final ClockTime? quietHoursEnd;
  final int sendTimeoutSeconds;

  /// The backend writes this as "code: detail" — see [lastErrorCode].
  final String lastError;
  final DateTime? lastErrorAt;

  /// Last send the relay accepted. Null means nothing has gone out yet.
  final DateTime? lastSeenAt;

  /// Which texts go out by themselves, by template kind.
  final Map<String, bool> autoMessages;

  factory MessagingGateway.fromJson(Map<String, Object?> json) {
    return MessagingGateway(
      id: _int(json['id']),
      name: json['name']?.toString() ?? '',
      provider: messagingProviderFromJson(json['provider']),
      isDefault: _bool(json['is_default']),
      isActive: _bool(json['is_active'], fallback: true),
      maxMessagesPerMinute: _int(json['max_messages_per_minute'], fallback: 30),
      dailyCap: _int(json['daily_cap']),
      quietHoursStart: ClockTime.tryParse(json['quiet_hours_start']),
      quietHoursEnd: ClockTime.tryParse(json['quiet_hours_end']),
      sendTimeoutSeconds: _int(json['send_timeout_seconds'], fallback: 20),
      lastError: json['last_error']?.toString() ?? '',
      lastErrorAt: _dateOrNull(json['last_error_at']),
      lastSeenAt: _dateOrNull(json['last_seen_at']),
      autoMessages: _autoMessages(json['auto_messages']),
    );
  }

  bool get hasError => lastError.trim().isNotEmpty;

  /// The window the backend actually applies: both ends set, and different.
  bool get hasQuietHours =>
      quietHoursStart != null &&
      quietHoursEnd != null &&
      quietHoursStart != quietHoursEnd;

  /// The machine code heading [lastError] (`provider_credit`, …), or empty
  /// when the text does not start with one.
  String get lastErrorCode =>
      _lastErrorPattern.firstMatch(lastError.trim())?.group(1) ?? '';

  /// [lastError] without its code — the provider's own words, if any.
  String get lastErrorDetail {
    final match = _lastErrorPattern.firstMatch(lastError.trim());
    return match == null ? lastError.trim() : match.group(2)!.trim();
  }
}

final _lastErrorPattern = RegExp(r'^([a-z][a-z_]*):\s*(.*)$', dotAll: true);

Map<String, bool> _autoMessages(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.value is bool) entry.key.toString(): entry.value as bool,
  };
}

/// The editable half of a gateway, as `PATCH /api/messaging/gateways/{id}/`
/// takes it. Everything else — provider, name, the error fields — is the
/// server's.
class MessagingGatewayUpdate {
  const MessagingGatewayUpdate({
    required this.isActive,
    required this.maxMessagesPerMinute,
    required this.dailyCap,
    this.quietHoursStart,
    this.quietHoursEnd,
  });

  final bool isActive;
  final int maxMessagesPerMinute;
  final int dailyCap;
  final ClockTime? quietHoursStart;
  final ClockTime? quietHoursEnd;

  /// Quiet hours always travel, nulls included: clearing the window is an edit
  /// the server has to hear about, not an omission.
  Map<String, Object?> toJson() {
    return {
      'is_active': isActive,
      'max_messages_per_minute': maxMessagesPerMinute,
      'daily_cap': dailyCap,
      'quiet_hours_start': quietHoursStart?.toJson(),
      'quiet_hours_end': quietHoursEnd?.toJson(),
    };
  }
}

/// One message as the backend reports it (a serialized `OutboundMessage`) —
/// what a test send or an invoice send returns: its status, any error, and the
/// exact text that went out.
class MessagingSendResult {
  const MessagingSendResult({
    required this.status,
    this.errorCode = '',
    this.errorDetail = '',
    this.body = '',
  });

  final String status;
  final String errorCode;
  final String errorDetail;

  /// The text sent — always an approved template with the shop's name in it,
  /// which is worth showing: it is what the customer reads.
  final String body;

  bool get ok => status == 'sent' || status == 'delivered';

  /// Refused or given up on. Anything else short of [ok] — queued behind the
  /// pacing, a promotion held for quiet hours — is still on its way.
  bool get isFailure => const {
    'failed',
    'cancelled',
    'expired',
    'blocked_consent',
  }.contains(status);

  factory MessagingSendResult.fromJson(Map<String, Object?> json) {
    return MessagingSendResult(
      status: json['status']?.toString() ?? '',
      errorCode: json['error_code']?.toString() ?? '',
      errorDetail: json['error_detail']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
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
