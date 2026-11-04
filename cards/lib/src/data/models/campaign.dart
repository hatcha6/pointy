import '../../core/money.dart';

/// A campaign as the app sees it: the code a customer typed, scanned or
/// followed, and what signing in with it gives them now.
class CampaignOffer {
  const CampaignOffer({
    required this.code,
    this.kind = 'other',
    this.displayName = '',
    this.landing = '/',
    this.reward = Money.zero,
  });

  factory CampaignOffer.fromJson(Map<String, dynamic> json) => CampaignOffer(
    code: json['code'] as String? ?? '',
    kind: json['kind'] as String? ?? 'other',
    displayName: json['display_name'] as String? ?? '',
    landing: json['landing'] as String? ?? '/',
    reward: Money.parse(json['reward'] as String?),
  );

  final String code;

  /// ad, creator, billboard, flyer, referral or other.
  final String kind;

  /// Who or what the customer reads («أحمد», «ملصق الجامعة»); may be empty.
  final String displayName;

  /// The app page the campaign's link opens.
  final String landing;

  /// Zero when the campaign gives nothing (any more).
  final Money reward;
}

/// Credit a campaign just put in the customer's balance, and why.
class CampaignReward {
  const CampaignReward({
    required this.amount,
    required this.code,
    required this.kind,
    this.displayName = '',
    this.via = 'code',
  });

  factory CampaignReward.fromJson(Map<String, dynamic> json) => CampaignReward(
    amount: Money.parse(json['amount'] as String?),
    code: json['code'] as String? ?? '',
    kind: json['kind'] as String? ?? 'other',
    displayName: json['display_name'] as String? ?? '',
    via: json['via'] as String? ?? 'code',
  );

  final Money amount;
  final String code;
  final String kind;
  final String displayName;

  /// How the code came: link (the app opened the campaign's link), referrer
  /// (installed from it on Google Play), web (the website's link) or code
  /// (typed).
  final String via;

  /// Scanned or tapped, as opposed to typed.
  bool get followed => via != 'code';
}

/// Where a customer came from, as the app holds it until the relay has it:
/// the campaign code and how it came, and the answer to «من أين سمعت عنا؟».
class PendingAttribution {
  const PendingAttribution({
    this.code = '',
    this.via = '',
    this.heardFrom = '',
  });

  factory PendingAttribution.fromJson(Map<String, dynamic> json) =>
      PendingAttribution(
        code: json['code'] as String? ?? '',
        via: json['via'] as String? ?? '',
        heardFrom: json['heard_from'] as String? ?? '',
      );

  static const empty = PendingAttribution();

  final String code;
  final String via;
  final String heardFrom;

  bool get isEmpty => code.isEmpty && heardFrom.isEmpty;

  PendingAttribution copyWith({String? code, String? via, String? heardFrom}) =>
      PendingAttribution(
        code: code ?? this.code,
        via: via ?? this.via,
        heardFrom: heardFrom ?? this.heardFrom,
      );

  Map<String, String> toJson() => {
    if (code.isNotEmpty) 'code': code,
    if (code.isNotEmpty) 'via': via.isEmpty ? 'code' : via,
    if (heardFrom.isNotEmpty) 'heard_from': heardFrom,
  };
}

/// The answers the app offers, in the order it shows them; the relay keeps
/// the same list.
const heardFromAnswers = [
  'facebook',
  'instagram',
  'tiktok',
  'whatsapp',
  'friend',
  'shop',
  'billboard',
  'store_search',
  'other',
];

/// A code as it can be: Latin capitals, digits, - and _ (the relay's rule).
String normalizeCampaignCode(String typed) =>
    typed.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_-]'), '');

bool isCampaignCode(String code) =>
    RegExp(r'^[A-Z0-9_-]{3,24}$').hasMatch(code);
