/// The two direct services «كروت دفتر» sells besides its cards: credit sent to
/// a phone number abroad (airtime) and bills paid abroad (electricity, water,
/// television, internet).
///
/// The code calls them `airtime` and `bill`: "top-up" already means a wallet or
/// float top-up everywhere else in this app.
library;

enum ServiceKind { airtime, bill }

String serviceKindToJson(ServiceKind kind) => switch (kind) {
  ServiceKind.airtime => 'airtime',
  ServiceKind.bill => 'bill',
};

ServiceKind? serviceKindFromJson(Object? raw) =>
    switch (raw?.toString().trim().toLowerCase()) {
      'airtime' => ServiceKind.airtime,
      'bill' || 'bills' => ServiceKind.bill,
      _ => null,
    };

/// What a bill is for. A bill is sold by type, never as one list: the till has
/// one card per type that has at least one provider.
enum BillType { electricity, water, tv, internet, toll, other }

BillType billTypeFromJson(Object? raw) =>
    switch (raw?.toString().trim().toLowerCase()) {
      'electricity' => BillType.electricity,
      'water' => BillType.water,
      'tv' || 'television' => BillType.tv,
      'internet' => BillType.internet,
      'toll' => BillType.toll,
      _ => BillType.other,
    };

String billTypeToJson(BillType type) => switch (type) {
  BillType.electricity => 'electricity',
  BillType.water => 'water',
  BillType.tv => 'tv',
  BillType.internet => 'internet',
  BillType.toll => 'toll',
  BillType.other => 'other',
};

extension BillTypeX on BillType {
  /// The types the till offers. `toll` and `other` are not sold in v1.
  bool get isOffered => switch (this) {
    BillType.electricity ||
    BillType.water ||
    BillType.tv ||
    BillType.internet => true,
    BillType.toll || BillType.other => false,
  };

  /// The order the cards are laid out in whatever order the server listed them.
  int get displayOrder => switch (this) {
    BillType.electricity => 0,
    BillType.water => 1,
    BillType.tv => 2,
    BillType.internet => 3,
    BillType.toll => 4,
    BillType.other => 5,
  };
}

/// Prepaid electricity hands the customer a token to key into the meter;
/// a postpaid bill is settled against an invoice.
enum BillService { prepaid, postpaid, unknown }

BillService billServiceFromJson(Object? raw) =>
    switch (raw?.toString().trim().toLowerCase()) {
      'prepaid' => BillService.prepaid,
      'postpaid' => BillService.postpaid,
      _ => BillService.unknown,
    };

/// How an operator or biller takes amounts: any amount between a minimum and
/// a maximum, or only the listed ones.
enum ServiceAmountMode { range, fixed }

ServiceAmountMode serviceAmountModeFromJson(Object? raw) =>
    raw?.toString().trim().toLowerCase() == 'fixed'
    ? ServiceAmountMode.fixed
    : ServiceAmountMode.range;

/// What a cashier reads for a network, a provider, a plan or a country: its
/// Arabic [name]. Nothing Latin is ever shown by choice — [nameEn] only feeds
/// the search box — but a name the table lacks arrives as Latin text, and that
/// is held left to right so it keeps its order inside an Arabic line.
String serviceDisplayName(String name, {String fallback = ''}) {
  final text = name.trim();
  if (text.isEmpty) {
    return fallback;
  }
  return _arabicLetter.hasMatch(text) ? text : '\u{2066}$text\u{2069}';
}

final RegExp _arabicLetter = RegExp(
  '[\u{0600}-\u{06FF}\u{0750}-\u{077F}\u{08A0}-\u{08FF}]',
);
