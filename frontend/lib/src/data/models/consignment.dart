/// الأمانات — goods the shop holds, sells and owes for, without ever owning.
///
/// Three documents' worth of shapes, and one derived position. Nothing here
/// stores a payable: every money figure arrives computed, because a payable the
/// client cached is a payable that can disagree with the ledger.
library;

import 'stock_unit.dart';

/// How a consignor is paid when their goods sell.
class ConsignmentPayoutMode {
  const ConsignmentPayoutMode._();

  /// The shop keeps whatever it sells above an agreed number.
  static const fixed = 'fixed';

  /// The consignor keeps a percentage of whatever it actually fetched.
  static const commission = 'commission';
}

/// Who carries the risk while the goods sit on the shop's shelf.
///
/// Ordered by ascending shop exposure. The default is the first, which is what
/// Libyan consignment vouchers already print.
class ConsignmentLiability {
  const ConsignmentLiability._();

  static const ownerRisk = 'owner_risk';
  static const shopLiableExceptForceMajeure = 'shop_liable_except_fm';
  static const shopLiable = 'shop_liable';
}

/// The signed سند استلام أمانة: one page, one consignor, one or many articles.
class ConsignmentAgreement {
  const ConsignmentAgreement({
    required this.id,
    this.number = '',
    required this.consignorId,
    this.consignorName = '',
    this.consignorPhone = '',
    this.signedAt,
    this.expiresOn,
    this.notes = '',
    this.payoutMode = ConsignmentPayoutMode.fixed,
    this.payoutRate,
    this.commissionPct,
    this.reservePrice,
    this.liabilityPolicy = ConsignmentLiability.ownerRisk,
    this.liabilityCap,
    this.liabilityClause = '',
    this.docStatus = 'draft',
    this.unitCount = 0,
    this.units = const [],
  });

  final int id;
  final String number;
  final int consignorId;
  final String consignorName;
  final String consignorPhone;
  final DateTime? signedAt;
  final DateTime? expiresOn;
  final String notes;
  final String payoutMode;
  final double? payoutRate;
  final double? commissionPct;
  final double? reservePrice;
  final String liabilityPolicy;
  final double? liabilityCap;

  /// The clause **as it was printed and signed**, not as the shop words it
  /// today. Re-wording the template next year has not re-worded this page.
  final String liabilityClause;
  final String docStatus;
  final int unitCount;

  /// The articles this page covers. Empty on a list row — a list row is not a
  /// document — and filled on the detail, which is what the printed voucher is
  /// built from: a signed page has to name the watch it is about.
  final List<StockUnit> units;

  bool get isFixed => payoutMode == ConsignmentPayoutMode.fixed;
  bool get isSubmitted => docStatus == 'submitted';

  /// The price below which this agreement's goods may not be sold. Under a
  /// fixed payout the shop would be paying out of its own pocket, which is why
  /// it is a wall rather than a warning.
  double? get hardFloor {
    if (!isFixed) {
      return null;
    }
    final reserve = reservePrice ?? 0;
    final payout = payoutRate ?? 0;
    return reserve > payout ? reserve : payout;
  }

  factory ConsignmentAgreement.fromJson(Map<String, Object?> json) {
    return ConsignmentAgreement(
      id: _intOf(json['id']),
      number: json['number']?.toString() ?? '',
      consignorId: _intOf(json['consignor']),
      consignorName: json['consignor_name']?.toString() ?? '',
      consignorPhone: json['consignor_phone']?.toString() ?? '',
      signedAt: _dateOrNull(json['signed_at']),
      expiresOn: _dateOrNull(json['expires_on']),
      notes: json['notes']?.toString() ?? '',
      payoutMode:
          json['payout_mode']?.toString() ?? ConsignmentPayoutMode.fixed,
      payoutRate: _doubleOrNull(json['payout_rate']),
      commissionPct: _doubleOrNull(json['commission_pct']),
      reservePrice: _doubleOrNull(json['reserve_price']),
      liabilityPolicy:
          json['liability_policy']?.toString() ??
          ConsignmentLiability.ownerRisk,
      liabilityCap: _doubleOrNull(json['liability_cap']),
      liabilityClause: json['liability_clause']?.toString() ?? '',
      docStatus: json['doc_status']?.toString() ?? 'draft',
      unitCount: _intOf(json['unit_count']),
      units: [
        for (final row in (json['units'] as List<Object?>? ?? const []))
          if (row is Map<String, Object?>) StockUnit.fromJson(row),
      ],
    );
  }
}

/// One line of *«مستحقات الأمانات»*: what is owed, to whom, for what.
class ConsignmentPayable {
  const ConsignmentPayable({
    required this.unitId,
    required this.code,
    this.productName = '',
    this.consignorId,
    this.consignorName = '',
    this.consignorPhone = '',
    this.agreementId,
    this.soldAt,
    this.soldPrice,
    this.payoutDue = 0,
    this.invoiceNumber = '',
    this.invoiceBalanceDue,
    this.soldOnCredit = false,
    this.daysWaiting,
  });

  final int unitId;
  final String code;
  final String productName;
  final int? consignorId;
  final String consignorName;
  final String consignorPhone;
  final int? agreementId;
  final DateTime? soldAt;
  final double? soldPrice;
  final double payoutDue;
  final String invoiceNumber;

  /// What the shop's own customer still owes on the invoice this sold under.
  ///
  /// The point of showing it: a consignment sold on آجل owes the consignor cash
  /// before the shop has collected any, and the person about to open the drawer
  /// should be told that in the row rather than discover it when it is short.
  final double? invoiceBalanceDue;
  final bool soldOnCredit;

  /// How long this money has been sitting here uncollected — the consignor who
  /// never came back is the other half of this screen.
  final int? daysWaiting;

  bool get isOverdue => (daysWaiting ?? 0) >= 30;

  factory ConsignmentPayable.fromJson(Map<String, Object?> json) {
    return ConsignmentPayable(
      unitId: _intOf(json['id']),
      code: json['code']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      consignorId: _intOrNull(json['consignor']),
      consignorName: json['consignor_name']?.toString() ?? '',
      consignorPhone: json['consignor_phone']?.toString() ?? '',
      agreementId: _intOrNull(json['agreement']),
      soldAt: _dateOrNull(json['sold_at']),
      soldPrice: _doubleOrNull(json['sold_price']),
      payoutDue: _doubleOrNull(json['payout_due']) ?? 0,
      invoiceNumber: json['invoice_number']?.toString() ?? '',
      invoiceBalanceDue: _doubleOrNull(json['invoice_balance_due']),
      soldOnCredit: json['sold_on_credit'] == true,
      daysWaiting: _intOrNull(json['days_waiting']),
    );
  }
}

/// A page of payables, with the total the shop actually owes underneath it.
///
/// [totalDue] is the whole liability and not this page's share of it: the
/// headline figure is about the shop, not about what happens to be on screen.
class ConsignmentPayablePage {
  const ConsignmentPayablePage({
    this.rows = const [],
    this.totalDue = 0,
    this.count = 0,
    this.hasNext = false,
  });

  final List<ConsignmentPayable> rows;
  final double totalDue;
  final int count;
  final bool hasNext;

  bool get isEmpty => rows.isEmpty;

  factory ConsignmentPayablePage.fromJson(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return const ConsignmentPayablePage();
    }
    final results = decoded['results'];
    final rows = results is List<Object?>
        ? results
              .whereType<Map<String, Object?>>()
              .map(ConsignmentPayable.fromJson)
              .toList(growable: false)
        : const <ConsignmentPayable>[];
    return ConsignmentPayablePage(
      rows: rows,
      totalDue: _doubleOrNull(decoded['total_due']) ?? 0,
      count: _intOrNull(decoded['count']) ?? rows.length,
      hasNext: decoded['next'] != null,
    );
  }
}

/// The four figures a consignment page leads with, and what is held in custody.
///
/// [stockValue] is always zero and is printed anyway: a page that did not say
/// *"the goods are worth nothing to this shop"* would be read as having
/// forgotten to.
class ConsignmentPosition {
  const ConsignmentPosition({
    this.stockValue = 0,
    this.payable = 0,
    this.receivable = 0,
    this.claimsOpen = 0,
    this.shopCommission = 0,
    this.custodyUnitCount = 0,
    this.custodyDeclaredValue = 0,
  });

  final double stockValue;
  final double payable;

  /// The debt running the other way: a consignment that came back after its
  /// owner had already collected. Shown beside the payable and never netted
  /// into it — a shop that owes one consignor 10,000 and is owed 3,000 by
  /// another owes 10,000.
  final double receivable;
  final double claimsOpen;
  final double shopCommission;
  final int custodyUnitCount;
  final double custodyDeclaredValue;

  factory ConsignmentPosition.fromJson(Map<String, Object?> json) {
    final custody = json['custody'];
    final custodyMap = custody is Map<String, Object?>
        ? custody
        : const <String, Object?>{};
    return ConsignmentPosition(
      stockValue: _doubleOrNull(json['stock_value']) ?? 0,
      payable: _doubleOrNull(json['consignor_payable']) ?? 0,
      receivable: _doubleOrNull(json['consignor_receivable']) ?? 0,
      claimsOpen: _doubleOrNull(json['consignor_claims_open']) ?? 0,
      shopCommission: _doubleOrNull(json['shop_commission']) ?? 0,
      custodyUnitCount: _intOf(custodyMap['unit_count']),
      custodyDeclaredValue: _doubleOrNull(custodyMap['declared_value']) ?? 0,
    );
  }
}

/// One article being taken in on consignment, as the intake sheet sends it.
class ConsignmentIntakeItem {
  const ConsignmentIntakeItem({
    required this.variantId,
    this.code = '',
    this.declaredValue,
    this.listPrice,
    this.payoutRate,
    this.commissionPct,
    this.reservePrice,
    this.notes = '',
  });

  final int variantId;
  final String code;
  final double? declaredValue;
  final double? listPrice;

  /// Per-unit overrides of the agreement's terms. Null inherits, which is the
  /// ordinary case: one consignor signs one page for eight handbags and then
  /// names a different reserve on the one that is nearly new.
  final double? payoutRate;
  final double? commissionPct;
  final double? reservePrice;
  final String notes;

  ConsignmentIntakeItem copyWith({
    int? variantId,
    String? code,
    Object? declaredValue = _unset,
    Object? listPrice = _unset,
    Object? payoutRate = _unset,
    Object? commissionPct = _unset,
    Object? reservePrice = _unset,
    String? notes,
  }) {
    return ConsignmentIntakeItem(
      variantId: variantId ?? this.variantId,
      code: code ?? this.code,
      declaredValue: declaredValue == _unset
          ? this.declaredValue
          : declaredValue as double?,
      listPrice: listPrice == _unset ? this.listPrice : listPrice as double?,
      payoutRate: payoutRate == _unset
          ? this.payoutRate
          : payoutRate as double?,
      commissionPct: commissionPct == _unset
          ? this.commissionPct
          : commissionPct as double?,
      reservePrice: reservePrice == _unset
          ? this.reservePrice
          : reservePrice as double?,
      notes: notes ?? this.notes,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      'code': code,
      if (declaredValue != null) 'declared_value': declaredValue,
      if (listPrice != null) 'list_price': listPrice,
      if (payoutRate != null) 'consignor_payout_rate': payoutRate,
      if (commissionPct != null) 'consignor_commission_pct': commissionPct,
      if (reservePrice != null) 'consignor_reserve_price': reservePrice,
      if (notes.isNotEmpty) 'notes': notes,
    };
  }
}

const Object _unset = Object();

/// The voucher a consignor signs for their money.
class ConsignorPayout {
  const ConsignorPayout({
    required this.id,
    this.number = '',
    this.consignorName = '',
    this.consignorPhone = '',
    this.amount = 0,
    this.method = 'cash',
    this.paidAt,
    this.reference = '',
    this.notes = '',
    this.lines = const [],
  });

  final int id;
  final String number;
  final String consignorName;
  final String consignorPhone;
  final double amount;
  final String method;
  final DateTime? paidAt;
  final String reference;
  final String notes;

  /// What the money was for. A voucher that says «10,000 د.ل» and does not say
  /// which watch is a receipt for nothing, so the articles travel on the row
  /// rather than behind a second call.
  final List<ConsignorPayoutLine> lines;

  bool get isCash => method == 'cash';

  factory ConsignorPayout.fromJson(Map<String, Object?> json) {
    return ConsignorPayout(
      id: _intOf(json['id']),
      number: json['number']?.toString() ?? '',
      consignorName: json['consignor_name']?.toString() ?? '',
      consignorPhone: json['consignor_phone']?.toString() ?? '',
      amount: _doubleOrNull(json['amount']) ?? 0,
      method: json['method']?.toString() ?? 'cash',
      paidAt: _dateOrNull(json['paid_at']),
      reference: json['reference']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      lines: [
        for (final row in (json['lines'] as List<Object?>? ?? const []))
          if (row is Map<String, Object?>) ConsignorPayoutLine.fromJson(row),
      ],
    );
  }
}

/// One article a payout settled.
class ConsignorPayoutLine {
  const ConsignorPayoutLine({
    required this.unitId,
    this.code = '',
    this.productName = '',
    this.soldAt,
    this.soldPrice,
    this.payoutDue = 0,
  });

  final int unitId;
  final String code;
  final String productName;
  final DateTime? soldAt;
  final double? soldPrice;
  final double payoutDue;

  factory ConsignorPayoutLine.fromJson(Map<String, Object?> json) {
    return ConsignorPayoutLine(
      unitId: _intOf(json['unit']),
      code: json['code']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      soldAt: _dateOrNull(json['sold_at']),
      soldPrice: _doubleOrNull(json['sold_price']),
      payoutDue: _doubleOrNull(json['payout_due']) ?? 0,
    );
  }
}

int _intOf(Object? value) => _intOrNull(value) ?? 0;

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

double? _doubleOrNull(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

DateTime? _dateOrNull(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}
