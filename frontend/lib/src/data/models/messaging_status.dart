import 'messaging_gateway.dart';

/// What `GET /api/messaging/status/` reports, in one read: whether the shop's
/// subscription includes SMS, the shop's gateway, this month's usage against
/// the relay's cap, and the catalogue of texts Daftar sends to customers.
class MessagingServiceStatus {
  const MessagingServiceStatus({
    required this.entitled,
    required this.available,
    this.testMode = false,
    this.gateway,
    this.usage,
    this.usageError = '',
    this.templates = const [],
  });

  /// The relay says SMS is in this shop's subscription.
  final bool entitled;

  /// [entitled] and the shop's gateway is switched on — what the auth
  /// payload's `sms_available` mirrors.
  final bool available;

  /// The relay processes sends without delivering them: nothing reaches a
  /// phone and nothing is charged.
  final bool testMode;
  final MessagingGateway? gateway;

  /// Null when the relay could not say; [usageError] names why.
  final MessagingUsage? usage;

  /// `not_entitled`, `relay_unreachable` or `not_configured` when [usage] is
  /// null; empty otherwise.
  final String usageError;
  final List<MessagingTemplateInfo> templates;

  bool get isRelayUnreachable => usageError == 'relay_unreachable';
  bool get isNotConfigured => usageError == 'not_configured';

  /// The relay itself refused this shop, whatever the local mirror of the
  /// subscription says — it has not caught up yet, and sends will be refused
  /// the same way.
  bool get isRefusedByRelay => usageError == 'not_entitled';

  /// This status after the shop saved its gateway: [available] follows the
  /// shop's switch, everything the relay said stays as it was.
  MessagingServiceStatus withGateway(MessagingGateway gateway) {
    return MessagingServiceStatus(
      entitled: entitled,
      available: entitled && gateway.isActive,
      testMode: testMode,
      gateway: gateway,
      usage: usage,
      usageError: usageError,
      templates: templates,
    );
  }

  factory MessagingServiceStatus.fromJson(Map<String, Object?> json) {
    final gateway = json['gateway'];
    final usage = json['usage'];
    final templates = json['templates'];
    return MessagingServiceStatus(
      entitled: json['entitled'] == true,
      available: json['available'] == true,
      testMode: json['test_mode'] == true,
      gateway: gateway is Map<String, Object?>
          ? MessagingGateway.fromJson(gateway)
          : null,
      usage: usage is Map<String, Object?>
          ? MessagingUsage.fromJson(usage)
          : null,
      usageError: json['usage_error']?.toString() ?? '',
      templates: templates is List
          ? templates
                .whereType<Map<String, Object?>>()
                .map(MessagingTemplateInfo.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// This calendar month's sends against the shop's monthly cap (the month is
/// Libya's, and so is the reset).
class MessagingUsage {
  const MessagingUsage({
    required this.used,
    required this.limit,
    required this.remaining,
    this.periodStart,
    this.resetsAt,
  });

  final int used;

  /// 0 = unlimited.
  final int limit;

  /// -1 when unlimited.
  final int remaining;
  final DateTime? periodStart;
  final DateTime? resetsAt;

  bool get isUnlimited => limit <= 0;
  bool get isExhausted => !isUnlimited && used >= limit;

  /// Share of the cap used, 0..1; always 0 when unlimited.
  double get fraction =>
      isUnlimited ? 0 : (used / limit).clamp(0.0, 1.0).toDouble();

  factory MessagingUsage.fromJson(Map<String, Object?> json) {
    final limit = _int(json['limit']);
    final used = _int(json['used']);
    final left = limit - used;
    return MessagingUsage(
      used: used,
      limit: limit,
      remaining: _int(
        json['remaining'],
        fallback: limit <= 0 ? -1 : (left < 0 ? 0 : left),
      ),
      periodStart: _dateOrNull(json['period_start']),
      resetsAt: _dateOrNull(json['resets_at']),
    );
  }
}

/// One text Daftar sends, as the settings page lists it: what it is for, the
/// approved wording, and an example rendered with the shop's own name.
class MessagingTemplateInfo {
  const MessagingTemplateInfo({
    required this.kind,
    required this.title,
    this.description = '',
    this.text = '',
    this.variables = const [],
    this.example = '',
    this.consentClass = 'transactional',
    this.configured,
  });

  final String kind;
  final String title;
  final String description;

  /// The approved wording with its `$1`, `$2`… slots.
  final String text;

  /// What fills each slot, in order.
  final List<String> variables;
  final String example;
  final String consentClass;

  /// Whether the provider has this template approved and wired. Null when the
  /// relay could not be asked.
  final bool? configured;

  bool get isMarketing => consentClass == 'marketing';

  factory MessagingTemplateInfo.fromJson(Map<String, Object?> json) {
    final variables = json['variables'];
    final configured = json['configured'];
    return MessagingTemplateInfo(
      kind: json['kind']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      variables: variables is List
          ? [for (final item in variables) item.toString()]
          : const [],
      example: json['example']?.toString() ?? '',
      consentClass: json['consent_class']?.toString() ?? 'transactional',
      configured: configured is bool ? configured : null,
    );
  }
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}
