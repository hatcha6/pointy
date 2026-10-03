import 'messaging_gateway.dart';
import 'wallet.dart';

/// What `GET /api/messaging/status/` reports, in one read: whether the shop
/// can send (its SMS balance pays for a message), the shop's gateway, the SMS
/// balance and this month's sends, and the catalogue of texts Daftar sends to
/// customers.
class MessagingServiceStatus {
  const MessagingServiceStatus({
    required this.entitled,
    required this.available,
    this.testMode = false,
    this.gateway,
    this.smsWallet,
    this.usage,
    this.usageError = '',
    this.templates = const [],
    this.templateGroups = const [],
  });

  /// The shop can send: its SMS balance pays for a message (from a backend
  /// before the SMS balance: the subscription includes SMS).
  final bool entitled;

  /// [entitled] and the shop's gateway is switched on — what the auth
  /// payload's `sms_available` mirrors.
  final bool available;

  /// The relay processes sends without delivering them: nothing reaches a
  /// phone and nothing is charged.
  final bool testMode;
  final MessagingGateway? gateway;

  /// The SMS balance each message is paid from; null from a backend that does
  /// not sell SMS by the message.
  final SmsWallet? smsWallet;

  /// Null when the relay could not say; [usageError] names why.
  final MessagingUsage? usage;

  /// `not_entitled`, `relay_unreachable` or `not_configured` when [usage] is
  /// null; empty otherwise.
  final String usageError;
  final List<MessagingTemplateInfo> templates;

  /// The families the templates are listed under, in order.
  final List<MessagingTemplateGroup> templateGroups;

  bool get isPrepaid => smsWallet != null;
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
      smsWallet: smsWallet,
      usage: usage,
      usageError: usageError,
      templates: templates,
      templateGroups: templateGroups,
    );
  }

  /// This status with one template replaced (matched by kind).
  MessagingServiceStatus withTemplate(MessagingTemplateInfo template) {
    return MessagingServiceStatus(
      entitled: entitled,
      available: available,
      testMode: testMode,
      gateway: gateway,
      smsWallet: smsWallet,
      usage: usage,
      usageError: usageError,
      templates: [
        for (final current in templates)
          current.kind == template.kind ? template : current,
      ],
      templateGroups: templateGroups,
    );
  }

  factory MessagingServiceStatus.fromJson(Map<String, Object?> json) {
    final gateway = json['gateway'];
    final smsWallet = json['sms_wallet'];
    final usage = json['usage'];
    final templates = json['templates'];
    final groups = json['template_groups'];
    return MessagingServiceStatus(
      entitled: json['entitled'] == true,
      available: json['available'] == true,
      testMode: json['test_mode'] == true,
      gateway: gateway is Map<String, Object?>
          ? MessagingGateway.fromJson(gateway)
          : null,
      smsWallet: smsWallet is Map<String, Object?>
          ? SmsWallet.fromJson(smsWallet)
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
      templateGroups: groups is List
          ? groups
                .whereType<Map<String, Object?>>()
                .map(MessagingTemplateGroup.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// A family of texts on the settings page — the invoices, the repair jobs.
class MessagingTemplateGroup {
  const MessagingTemplateGroup({required this.key, required this.title});

  final String key;
  final String title;

  factory MessagingTemplateGroup.fromJson(Map<String, Object?> json) {
    return MessagingTemplateGroup(
      key: json['key']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
    );
  }
}

/// This calendar month's sends, and the company's monthly brake on them when
/// it set one for this shop (the month is Libya's, and so is the reset).
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
    this.group = 'other',
    this.automatic = false,
    this.autoEnabled,
    this.autoLabel = '',
    this.exampleParts = 1,
    this.examplePrice,
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

  /// The family it is listed under ([MessagingTemplateGroup.key]).
  final String group;

  /// It goes out by itself when its event happens, under the switch
  /// [autoEnabled]; [autoLabel] says when.
  final bool automatic;
  final bool? autoEnabled;
  final String autoLabel;

  /// How many SMS the example goes out as, and what that costs from the SMS
  /// balance (null when SMS is not sold from a balance).
  final int exampleParts;
  final double? examplePrice;

  bool get isMarketing => consentClass == 'marketing';

  MessagingTemplateInfo withAutoEnabled(bool enabled) {
    return MessagingTemplateInfo(
      kind: kind,
      title: title,
      description: description,
      text: text,
      variables: variables,
      example: example,
      consentClass: consentClass,
      configured: configured,
      group: group,
      automatic: automatic,
      autoEnabled: enabled,
      autoLabel: autoLabel,
      exampleParts: exampleParts,
      examplePrice: examplePrice,
    );
  }

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
      group: json['group']?.toString() ?? 'other',
      automatic: json['automatic'] == true,
      autoEnabled: json['auto_enabled'] is bool
          ? json['auto_enabled'] as bool
          : null,
      autoLabel: json['auto_label']?.toString() ?? '',
      exampleParts: _int(json['example_parts'], fallback: 1),
      examplePrice: double.tryParse(json['example_price']?.toString() ?? ''),
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
