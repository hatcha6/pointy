/// A redacted payment card captured from a terminal receipt, attached to a
/// customer. Mirrors the backend `PaymentCard` (apps/customers).
class PaymentCard {
  const PaymentCard({
    required this.id,
    required this.customer,
    required this.customerName,
    required this.maskedPan,
    required this.cardScheme,
    required this.aid,
    required this.label,
    required this.displayName,
    required this.isActive,
    this.firstSeenAt,
    this.lastSeenAt,
  });

  final int id;
  final int customer;
  final String customerName;
  final String maskedPan;
  final String cardScheme;
  final String aid;
  final String label;
  final String displayName;
  final bool isActive;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;

  factory PaymentCard.fromJson(Map<String, Object?> json) {
    return PaymentCard(
      id: _intFromJson(json['id']),
      customer: _intFromJson(json['customer']),
      customerName: json['customer_name']?.toString() ?? '',
      maskedPan: json['masked_pan']?.toString() ?? '',
      cardScheme: json['card_scheme']?.toString() ?? '',
      aid: json['aid']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      isActive: json['is_active'] != false,
      firstSeenAt: _dateTimeFromJson(json['first_seen_at']),
      lastSeenAt: _dateTimeFromJson(json['last_seen_at']),
    );
  }
}

class PaymentCardPage {
  const PaymentCardPage({required this.cards, required this.hasMore});

  final List<PaymentCard> cards;
  final bool hasMore;

  factory PaymentCardPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(PaymentCard.fromJson)
        .toList(growable: false);
    return PaymentCardPage(cards: results, hasMore: json['next'] != null);
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
