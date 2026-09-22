import 'bank_account_ref.dart';

/// One card machine on the counter, and the bank account it settles into.
///
/// The shop already listed its terminals — that list is what stops a slip from
/// somebody else's machine proving a payment here. This adds the half that
/// list could never carry: *which of our accounts does this machine feed*, so
/// a scanned receipt routes its own money and the cashier never picks a bank.
class CardTerminal {
  const CardTerminal({
    required this.id,
    required this.terminalId,
    this.label = '',
    this.moneyAccountId,
    this.bankAccount,
    this.isActive = true,
    this.displayOrder = 0,
  });

  final int id;

  /// As printed on the machine and on every slip it produces.
  final String terminalId;

  /// What the staff call it — "الماكينة الأمامية". Blank is normal.
  final String label;

  final int? moneyAccountId;

  /// The account, spelled out, so a settings row can draw the bank's mark
  /// without a lookup per terminal.
  final BankAccountRef? bankAccount;
  final bool isActive;
  final int displayOrder;

  String get displayName => label.isNotEmpty ? label : terminalId;

  /// True when this terminal knows where its money goes. A terminal without an
  /// account is not broken — its payments simply route to the default, the way
  /// every payment did before accounts could be named — but the settings screen
  /// says so, because an owner who mapped one terminal and not the other is
  /// usually halfway through a job.
  bool get isMapped => moneyAccountId != null;

  factory CardTerminal.fromJson(Map<String, Object?> json) {
    final rawAccount = json['money_account'];
    return CardTerminal(
      id: _asInt(json['id']) ?? 0,
      terminalId: json['terminal_id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      moneyAccountId: _asInt(rawAccount),
      bankAccount: BankAccountRef.fromPaymentJson(json),
      isActive: json['is_active'] != false,
      displayOrder: _asInt(json['display_order']) ?? 0,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'terminal_id': terminalId,
      'label': label,
      'money_account': moneyAccountId,
      'is_active': isActive,
      'display_order': displayOrder,
    };
  }

  CardTerminal copyWith({
    String? terminalId,
    String? label,
    int? moneyAccountId,
    bool clearMoneyAccount = false,
    bool? isActive,
    int? displayOrder,
  }) {
    return CardTerminal(
      id: id,
      terminalId: terminalId ?? this.terminalId,
      label: label ?? this.label,
      moneyAccountId: clearMoneyAccount
          ? null
          : (moneyAccountId ?? this.moneyAccountId),
      bankAccount: clearMoneyAccount ? null : bankAccount,
      isActive: isActive ?? this.isActive,
      displayOrder: displayOrder ?? this.displayOrder,
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
}
