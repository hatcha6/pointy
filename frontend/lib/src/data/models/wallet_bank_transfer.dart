/// Filling the wallet by bank transfer: the shop sends money to the company's
/// own account with LYPay (to its IBAN) or OnePay (to its bank and account
/// number), then sends the receipt. The company's team finds the money on its
/// statement and credits it, or rejects it with a reason the owner reads.
library;

/// The app the payer sent the money with.
enum WalletTransferChannel {
  /// LYPay: the payer types our IBAN, and the app shows our name to check.
  lyPay('lypay'),

  /// OnePay: the payer picks our bank and types our account number.
  onePay('onepay');

  const WalletTransferChannel(this.key);

  final String key;

  static WalletTransferChannel parse(Object? raw) =>
      raw == 'onepay' ? onePay : lyPay;
}

/// One of the company's accounts a shop may transfer to.
class WalletBankAccount {
  const WalletBankAccount({
    required this.id,
    required this.bank,
    required this.bankName,
    required this.holder,
    required this.accountNumber,
    required this.iban,
  });

  factory WalletBankAccount.fromJson(Map<String, Object?> json) {
    return WalletBankAccount(
      id: _string(json['id']),
      bank: _string(json['bank']),
      bankName: _string(json['bank_name']),
      holder: _string(json['holder']),
      accountNumber: _string(json['account_number']),
      iban: _string(json['iban']),
    );
  }

  final String id;

  /// The Central Bank's slug ("nab"), which picks the bank's mark.
  final String bank;
  final String bankName;

  /// The name the payer's app shows once the account is typed: what they
  /// check before sending.
  final String holder;
  final String accountNumber;
  final String iban;
}

/// An account the shop paid from before, offered so the next top-up from it
/// is one tap.
class WalletPayerAccount {
  const WalletPayerAccount({
    required this.bank,
    required this.accountNumber,
    required this.iban,
    this.channel = WalletTransferChannel.lyPay,
  });

  factory WalletPayerAccount.fromJson(Map<String, Object?> json) {
    return WalletPayerAccount(
      channel: WalletTransferChannel.parse(json['channel']),
      bank: _string(json['payer_bank']),
      accountNumber: _string(json['payer_account']),
      iban: _string(json['payer_iban']),
    );
  }

  final WalletTransferChannel channel;
  final String bank;
  final String accountNumber;
  final String iban;
}

/// The bank-transfer half of the top-up options.
class WalletBankTransferOffer {
  const WalletBankTransferOffer({
    required this.accounts,
    this.savedPayers = const [],
    this.maxReceiptBytes = 10 * 1024 * 1024,
  });

  /// Null when the relay offers no transfer (no account set up, or a relay
  /// from before transfers).
  static WalletBankTransferOffer? fromJson(Object? raw) {
    if (raw is! Map<String, Object?> || raw['available'] != true) {
      return null;
    }
    final accounts = _maps(
      raw['accounts'],
    ).map(WalletBankAccount.fromJson).where((a) => a.iban.isNotEmpty).toList();
    if (accounts.isEmpty) {
      return null;
    }
    final max = raw['max_receipt_bytes'];
    return WalletBankTransferOffer(
      accounts: accounts,
      savedPayers: _maps(raw['saved_payers'])
          .map(WalletPayerAccount.fromJson)
          .where((p) => p.iban.isNotEmpty)
          .toList(),
      maxReceiptBytes: max is num && max > 0 ? max.toInt() : 10 * 1024 * 1024,
    );
  }

  final List<WalletBankAccount> accounts;
  final List<WalletPayerAccount> savedPayers;
  final int maxReceiptBytes;
}

/// What a bank-transfer top-up says about its transfer.
class WalletTransferDetails {
  const WalletTransferDetails({
    required this.channel,
    required this.payerBank,
    required this.payerAccount,
    required this.payerIban,
    this.declaredAmount,
    this.receiptName = '',
    this.receiptType = '',
  });

  static WalletTransferDetails? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return null;
    }
    final declared = double.tryParse(_string(raw['declared_amount']));
    return WalletTransferDetails(
      channel: WalletTransferChannel.parse(raw['channel']),
      payerBank: _string(raw['payer_bank']),
      payerAccount: _string(raw['payer_account']),
      payerIban: _string(raw['payer_iban']),
      declaredAmount: declared,
      receiptName: _string(raw['receipt_name']),
      receiptType: _string(raw['receipt_type']),
    );
  }

  final WalletTransferChannel channel;
  final String payerBank;
  final String payerAccount;
  final String payerIban;

  /// What the shop said it sent; the top-up's amount is what was credited.
  final double? declaredAmount;
  final String receiptName;
  final String receiptType;
}

/// The receipt the owner attached: a file from this device, or what the
/// paired phone sent (already on the shop's server, by its attachment id).
class WalletTransferReceipt {
  const WalletTransferReceipt.file({
    required List<int> this.bytes,
    required this.name,
    required this.contentType,
  }) : attachmentId = null,
       previewBytes = null;

  /// [previewBytes] is the phone's file read back to show it here; it is sent
  /// by [attachmentId], never uploaded a second time.
  const WalletTransferReceipt.fromPhone({
    required int this.attachmentId,
    this.name = '',
    this.contentType = '',
    this.previewBytes,
  }) : bytes = null;

  final List<int>? bytes;
  final int? attachmentId;
  final List<int>? previewBytes;

  /// What to draw: the file itself, or the phone's copy of it.
  List<int>? get shownBytes => bytes ?? previewBytes;
  final String name;
  final String contentType;

  bool get isPdf =>
      contentType == 'application/pdf' || name.toLowerCase().endsWith('.pdf');
  bool get fromPhone => attachmentId != null;
  int get size => bytes?.length ?? 0;
}

/// Libyan IBANs as the relay reads them: LY, two check digits, then the bank
/// (3), the branch (3) and the account (15).
abstract final class LibyanIban {
  /// The IBAN without the spaces it is copied with, upper-cased, with Arabic
  /// digits read as Latin ones.
  static String normalize(String raw) {
    final buffer = StringBuffer();
    for (final unit in raw.trim().toUpperCase().runes) {
      if (unit >= 0x0660 && unit <= 0x0669) {
        buffer.writeCharCode(0x30 + unit - 0x0660);
      } else if (unit >= 0x06F0 && unit <= 0x06F9) {
        buffer.writeCharCode(0x30 + unit - 0x06F0);
      } else if (unit != 0x20 && unit != 0x2D) {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }

  /// ISO 13616 check digits: the relay refuses anything else.
  static bool isValid(String raw) {
    final iban = normalize(raw);
    if (!RegExp(r'^LY\d{23}$').hasMatch(iban)) {
      return false;
    }
    final rearranged = iban.substring(4) + iban.substring(0, 4);
    var remainder = 0;
    for (final unit in rearranged.codeUnits) {
      final value = unit >= 0x41 ? unit - 0x41 + 10 : unit - 0x30;
      for (final digit in value.toString().codeUnits) {
        remainder = (remainder * 10 + digit - 0x30) % 97;
      }
    }
    return remainder == 1;
  }

  /// The account number a valid IBAN carries: its last fifteen digits.
  static String? accountNumber(String raw) {
    final iban = normalize(raw);
    return isValid(iban) ? iban.substring(iban.length - 15) : null;
  }

  /// The last four, for a row that names the account without showing it.
  static String masked(String raw) {
    final iban = normalize(raw);
    return iban.length < 8 ? iban : 'LY•••${iban.substring(iban.length - 4)}';
  }
}

/// An account number: digits only.
String normalizeBankAccountNumber(String raw) =>
    LibyanIban.normalize(raw).replaceAll(RegExp(r'[^0-9]'), '');

bool isBankAccountNumber(String raw) =>
    RegExp(r'^\d{6,20}$').hasMatch(normalizeBankAccountNumber(raw));

String _string(Object? value) => value == null ? '' : value.toString().trim();

Iterable<Map<String, Object?>> _maps(Object? raw) =>
    raw is List ? raw.whereType<Map<String, Object?>>() : const [];
