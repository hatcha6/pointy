/// The bank account a money row landed in, as a document surface names it.
///
/// A sale's payment, a supplier payment and a card terminal all answer the same
/// question — *which of the shop's banks was this?* — and all three answer it
/// with the same three fields the server sends beside the id. Parsing them in
/// one place is what stops an invoice and a purchase order describing the same
/// account differently, and it is why `money_account_bank_slug` is read rather
/// than guessed from the account's name.
///
/// Absent is the ordinary case and must render as nothing at all: a shop with
/// one bank account (or none) names no account on anything, and a row saying
/// "الحساب الافتراضي" on every payment would be noise on every invoice in the
/// country.
class BankAccountRef {
  const BankAccountRef({
    this.id,
    this.name = '',
    this.bankSlug = '',
    this.bankName = '',
  });

  final int? id;

  /// What the shop calls this account ("حساب الجمهورية").
  final String name;

  /// The Central Bank's slug, used to find the mark. May name a bank this
  /// build's register does not carry — then [bankName] is shown alone.
  final String bankSlug;

  /// The bank's name as the shop typed it. The fallback whenever the slug
  /// resolves to nothing.
  final String bankName;

  bool get isEmpty => name.isEmpty && bankName.isEmpty;

  /// The label to put on a row: the account's own name, or the bank's when the
  /// shop never named the account.
  String get displayName => name.isNotEmpty ? name : bankName;

  /// Reads the `money_account*` group out of a payment payload.
  ///
  /// Returns null — never an empty instance — when the row names no account,
  /// so a caller cannot accidentally render a blank bank row by forgetting to
  /// check [isEmpty].
  static BankAccountRef? fromPaymentJson(
    Map<String, Object?> json, {
    String prefix = 'money_account',
  }) {
    final name = json['${prefix}_name']?.toString() ?? '';
    final bankName = json['${prefix}_bank_name']?.toString() ?? '';
    final bankSlug = json['${prefix}_bank_slug']?.toString() ?? '';
    final rawId = json[prefix];
    final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
    if (id == null && name.isEmpty && bankName.isEmpty) {
      return null;
    }
    return BankAccountRef(
      id: id,
      name: name,
      bankSlug: bankSlug,
      bankName: bankName,
    );
  }
}
