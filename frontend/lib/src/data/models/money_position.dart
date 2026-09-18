/// A place the shop's money sits: the cash box, or a bank account.
enum MoneyAccountKind {
  cash('cash'),
  bank('bank');

  const MoneyAccountKind(this.apiValue);

  final String apiValue;

  static MoneyAccountKind fromApiValue(Object? value) {
    final raw = value?.toString();
    return MoneyAccountKind.values.firstWhere(
      (kind) => kind.apiValue == raw,
      orElse: () => MoneyAccountKind.cash,
    );
  }
}

class MoneyAccount {
  const MoneyAccount({
    required this.id,
    required this.name,
    required this.kind,
    this.bankName = '',
    this.accountNumber = '',
    this.openingBalance = 0,
    this.openingAt,
    this.isDefault = false,
    this.isActive = true,
    this.isRouted = false,
    this.displayOrder = 0,
    this.notes = '',
  });

  final int id;
  final String name;
  final MoneyAccountKind kind;
  final String bankName;
  final String accountNumber;
  final double openingBalance;
  final DateTime? openingAt;
  final bool isDefault;
  final bool isActive;

  /// True when this account receives the money events of its kind. Only one
  /// account per kind does, so the UI can say where an untagged payment lands.
  final bool isRouted;
  final int displayOrder;
  final String notes;

  bool get isCash => kind == MoneyAccountKind.cash;

  factory MoneyAccount.fromJson(Map<String, Object?> json) {
    return MoneyAccount(
      id: _intFromJson(json['id']),
      name: json['name']?.toString() ?? '',
      kind: MoneyAccountKind.fromApiValue(json['kind']),
      bankName: json['bank_name']?.toString() ?? '',
      accountNumber: json['account_number']?.toString() ?? '',
      openingBalance: _moneyFromJson(json['opening_balance']),
      openingAt: _dateTimeFromJson(json['opening_at']),
      isDefault: json['is_default'] == true,
      isActive: json['is_active'] != false,
      isRouted: json['is_routed'] == true,
      displayOrder: _intFromJson(json['display_order']),
      notes: json['notes']?.toString() ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'kind': kind.apiValue,
      'bank_name': bankName,
      'account_number': accountNumber,
      'opening_balance': openingBalance.toStringAsFixed(2),
      if (openingAt != null)
        'opening_at': openingAt!.toIso8601String().split('T').first,
      'is_default': isDefault,
      'is_active': isActive,
      'display_order': displayOrder,
      'notes': notes,
    };
  }

  MoneyAccount copyWith({
    String? name,
    MoneyAccountKind? kind,
    String? bankName,
    String? accountNumber,
    double? openingBalance,
    DateTime? openingAt,
    bool? isDefault,
    bool? isActive,
  }) {
    return MoneyAccount(
      id: id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      bankName: bankName ?? this.bankName,
      accountNumber: accountNumber ?? this.accountNumber,
      openingBalance: openingBalance ?? this.openingBalance,
      openingAt: openingAt ?? this.openingAt,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      isRouted: isRouted,
      displayOrder: displayOrder,
      notes: notes,
    );
  }
}

/// One named line of the arithmetic behind a balance. The codes are a backend
/// contract; the UI maps them to Arabic labels.
class MoneyPositionComponent {
  const MoneyPositionComponent({
    required this.code,
    required this.amount,
    required this.isInflow,
  });

  final String code;
  final double amount;
  final bool isInflow;

  factory MoneyPositionComponent.fromJson(Map<String, Object?> json) {
    return MoneyPositionComponent(
      code: json['code']?.toString() ?? '',
      amount: _moneyFromJson(json['amount']),
      isInflow: json['direction']?.toString() == 'in',
    );
  }
}

/// What was actually found in an account when somebody looked.
class MoneyCount {
  const MoneyCount({
    required this.id,
    required this.accountId,
    required this.countedAmount,
    required this.expectedAmount,
    required this.variance,
    this.accountName = '',
    this.countedAt,
    this.note = '',
    this.createdByName = '',
  });

  final int id;
  final int accountId;
  final String accountName;
  final double countedAmount;
  final double expectedAmount;
  final double variance;
  final DateTime? countedAt;
  final String note;
  final String createdByName;

  bool get hasVariance => variance != 0;
  bool get isShort => variance < 0;

  factory MoneyCount.fromJson(Map<String, Object?> json) {
    return MoneyCount(
      id: _intFromJson(json['id']),
      accountId: _intFromJson(json['account']),
      accountName: json['account_name']?.toString() ?? '',
      countedAmount: _moneyFromJson(json['counted_amount']),
      expectedAmount: _moneyFromJson(json['expected_amount']),
      variance: _moneyFromJson(json['variance']),
      countedAt: _dateTimeFromJson(json['counted_at']),
      note: json['note']?.toString() ?? '',
      createdByName: json['created_by_name']?.toString() ?? '',
    );
  }
}

/// One account card: what it should hold, and why.
class MoneyAccountPosition {
  const MoneyAccountPosition({
    required this.account,
    required this.expectedBalance,
    this.components = const [],
    this.lastCount,
  });

  final MoneyAccount account;
  final double expectedBalance;
  final List<MoneyPositionComponent> components;
  final MoneyCount? lastCount;

  bool get hasBeenCounted => lastCount != null;

  /// True when the last count disagreed with what Pointy expected. The count is
  /// a snapshot, so this stays true until somebody counts again.
  bool get hasVariance => lastCount?.hasVariance ?? false;

  factory MoneyAccountPosition.fromJson(Map<String, Object?> json) {
    final rawComponents = json['components'];
    final rawCount = json['last_count'];
    return MoneyAccountPosition(
      account: MoneyAccount.fromJson(
        (json['account'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      expectedBalance: _moneyFromJson(json['expected_balance']),
      components: rawComponents is List
          ? rawComponents
                .whereType<Map>()
                .map(
                  (item) => MoneyPositionComponent.fromJson(
                    item.cast<String, Object?>(),
                  ),
                )
                .toList()
          : const [],
      lastCount: rawCount is Map
          ? MoneyCount.fromJson(rawCount.cast<String, Object?>())
          : null,
    );
  }
}

/// The shop-wide totals across every account.
class MoneyPositionTotals {
  const MoneyPositionTotals({
    this.cash = 0,
    this.bank = 0,
    this.total = 0,
    this.accountsCounted = 0,
    this.accountsTotal = 0,
    this.accountsWithVariance = 0,
  });

  final double cash;
  final double bank;
  final double total;
  final int accountsCounted;
  final int accountsTotal;
  final int accountsWithVariance;

  bool get hasVariance => accountsWithVariance > 0;
  bool get hasUncountedAccounts => accountsCounted < accountsTotal;

  factory MoneyPositionTotals.fromJson(Map<String, Object?> json) {
    return MoneyPositionTotals(
      cash: _moneyFromJson(json['cash']),
      bank: _moneyFromJson(json['bank']),
      total: _moneyFromJson(json['total']),
      accountsCounted: _intFromJson(json['accounts_counted']),
      accountsTotal: _intFromJson(json['accounts_total']),
      accountsWithVariance: _intFromJson(json['accounts_with_variance']),
    );
  }
}

/// What the shop is holding that belongs to somebody else.
///
/// An **overlay**, never a component. The cash in the drawer really is there;
/// what is untrue is that all of it is the shop's — so this renders beneath the
/// total as *منها مستحقات أمانات* and is never subtracted from it. Subtracting
/// it would double-count the money the moment the payout is actually made.
class MoneyObligations {
  const MoneyObligations({
    this.consignorPayable = 0,
    this.claimsOpen = 0,
    this.custodyUnitCount = 0,
    this.custodyDeclaredValue = 0,
  });

  final double consignorPayable;
  final double claimsOpen;
  final int custodyUnitCount;
  final double custodyDeclaredValue;

  bool get isEmpty =>
      consignorPayable == 0 && claimsOpen == 0 && custodyUnitCount == 0;

  factory MoneyObligations.fromJson(Map<String, Object?> json) {
    final custody = json['custody'];
    final custodyMap = custody is Map
        ? custody.cast<String, Object?>()
        : const <String, Object?>{};
    return MoneyObligations(
      consignorPayable: _moneyFromJson(json['consignor_payable']),
      claimsOpen: _moneyFromJson(json['consignor_claims_open']),
      custodyUnitCount: _intFromJson(custodyMap['unit_count']),
      custodyDeclaredValue: _moneyFromJson(custodyMap['declared_value']),
    );
  }
}

class MoneyPosition {
  const MoneyPosition({
    required this.accounts,
    required this.totals,
    this.asOf,
    this.obligations = const MoneyObligations(),
  });

  final List<MoneyAccountPosition> accounts;
  final MoneyPositionTotals totals;
  final DateTime? asOf;
  final MoneyObligations obligations;

  bool get isEmpty => accounts.isEmpty;

  List<MoneyAccountPosition> get cashAccounts =>
      accounts.where((entry) => entry.account.isCash).toList();
  List<MoneyAccountPosition> get bankAccounts =>
      accounts.where((entry) => !entry.account.isCash).toList();

  factory MoneyPosition.fromJson(Map<String, Object?> json) {
    final rawAccounts = json['accounts'];
    return MoneyPosition(
      accounts: rawAccounts is List
          ? rawAccounts
                .whereType<Map>()
                .map(
                  (item) => MoneyAccountPosition.fromJson(
                    item.cast<String, Object?>(),
                  ),
                )
                .toList()
          : const [],
      totals: MoneyPositionTotals.fromJson(
        (json['totals'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      asOf: _dateTimeFromJson(json['as_of']),
      obligations: MoneyObligations.fromJson(
        (json['obligations'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
    );
  }
}

/// One money event behind an account's balance.
class MoneyMovement {
  const MoneyMovement({
    required this.source,
    required this.amount,
    required this.isInflow,
    this.date,
    this.description = '',
    this.reference = '',
    this.relatedId,
  });

  final String source;
  final double amount;
  final bool isInflow;
  final DateTime? date;
  final String description;
  final String reference;
  final int? relatedId;

  factory MoneyMovement.fromJson(Map<String, Object?> json) {
    return MoneyMovement(
      source: json['source']?.toString() ?? '',
      amount: _moneyFromJson(json['amount']),
      isInflow: json['direction']?.toString() == 'in',
      date: _dateTimeFromJson(json['date']),
      description: json['description']?.toString() ?? '',
      reference: json['reference']?.toString() ?? '',
      relatedId: json['related_id'] == null
          ? null
          : _intFromJson(json['related_id']),
    );
  }
}

class MoneyMovementPage {
  const MoneyMovementPage({
    required this.rows,
    this.truncated = false,
    this.start,
    this.end,
  });

  final List<MoneyMovement> rows;
  final bool truncated;
  final DateTime? start;
  final DateTime? end;

  factory MoneyMovementPage.fromJson(Map<String, Object?> json) {
    final rawRows = json['rows'];
    return MoneyMovementPage(
      rows: rawRows is List
          ? rawRows
                .whereType<Map>()
                .map(
                  (item) =>
                      MoneyMovement.fromJson(item.cast<String, Object?>()),
                )
                .toList()
          : const [],
      truncated: json['truncated'] == true,
      start: _dateTimeFromJson(json['start']),
      end: _dateTimeFromJson(json['end']),
    );
  }
}

/// A move of the shop's own money: a bank deposit, an owner's draw, capital in.
class MoneyTransferDraft {
  const MoneyTransferDraft({
    required this.amount,
    this.fromAccountId,
    this.toAccountId,
    this.movedAt,
    this.reason = '',
    this.reference = '',
  });

  final double amount;
  final int? fromAccountId;
  final int? toAccountId;
  final DateTime? movedAt;
  final String reason;
  final String reference;

  Map<String, Object?> toJson() {
    return {
      'amount': amount.toStringAsFixed(2),
      if (fromAccountId != null) 'from_account': fromAccountId,
      if (toAccountId != null) 'to_account': toAccountId,
      if (movedAt != null)
        'moved_at': movedAt!.toIso8601String().split('T').first,
      'reason': reason,
      'reference': reference,
    };
  }
}

// Local JSON helpers, matching the convention every other model file in this
// directory follows.

DateTime? _dateTimeFromJson(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '');
}

int _intFromJson(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
