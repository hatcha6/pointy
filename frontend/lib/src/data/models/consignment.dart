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
    this.advance = 0,
    this.netDue = 0,
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

  /// Money already handed to this consignor **for this article** — because a
  /// paid-out consignment came back and was reopened rather than bought in.
  /// Shown beside the payout rather than instead of it: a row that showed
  /// only [netDue] would read as though the watch had earned 1,600 (§15.3).
  final double advance;

  /// What the counter actually hands over: [payoutDue] less [advance],
  /// floored at zero. Negative would mean the consignor owes the shop, which
  /// is a receivable and never a negative payable.
  final double netDue;
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
      advance: _doubleOrNull(json['advance']) ?? 0,
      netDue:
          _doubleOrNull(json['net_due']) ??
          _doubleOrNull(json['payout_due']) ??
          0,
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
    this.claimsUnassessed = 0,
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

  /// Incidents nobody has put a figure on. A **count**, never folded into
  /// [claimsOpen]: an undetermined incident carries a zero nobody chose, and
  /// adding it to a money total would say the shop had accepted a liability
  /// it has not (§6.2.2).
  final int claimsUnassessed;
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
      claimsUnassessed: _intOf(json['consignor_claims_unassessed']),
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
    this.advanceOffset = 0,
    this.paidHere = 0,
  });

  final int unitId;
  final String code;
  final String productName;
  final DateTime? soldAt;
  final double? soldPrice;

  /// What this article earned its owner — the gross.
  final double payoutDue;

  /// How much of that this voucher settled against money already handed
  /// over. Without it a voucher for 1,600 lists a line claiming a payout of
  /// 9,600 and no explanation of the difference: a document that does not
  /// foot.
  final double advanceOffset;

  /// What this voucher actually paid for this line.
  final double paidHere;

  factory ConsignorPayoutLine.fromJson(Map<String, Object?> json) {
    final due = _doubleOrNull(json['payout_due']) ?? 0;
    return ConsignorPayoutLine(
      unitId: _intOf(json['unit']),
      code: json['code']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      soldAt: _dateOrNull(json['sold_at']),
      soldPrice: _doubleOrNull(json['sold_price']),
      payoutDue: due,
      advanceOffset: _doubleOrNull(json['advance_offset']) ?? 0,
      paidHere: _doubleOrNull(json['paid_here']) ?? due,
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

/// محضر حادث أمانة — something happened to goods the shop was holding.
///
/// §6.2.2. The record is made the moment somebody notices, in their own
/// words, before anybody has decided who is responsible: *undetermined* is the
/// honest state on day one and nothing downstream may require it to be
/// resolved before the row can exist.
class ConsignmentIncident {
  const ConsignmentIncident({
    required this.id,
    required this.number,
    required this.unitId,
    required this.kind,
    required this.discoveredAt,
    this.unitCode = '',
    this.productName = '',
    this.consignorId,
    this.consignorName = '',
    this.consignorPhone = '',
    this.agreementId,
    this.agreementNumber = '',
    this.liabilityPolicy = ConsignmentLiability.ownerRisk,
    this.liabilityCap = 0,
    this.declaredValue = 0,
    this.occurredOn,
    this.reportedByName = '',
    this.narrative = '',
    this.responsibility = ConsignmentResponsibility.undetermined,
    this.assessedValue = 0,
    this.isAssessed = false,
    this.suggestedValue = 0,
    this.resolution = ConsignmentResolution.pending,
    this.resolvedAt,
    this.settlementRef = '',
    this.isOpen = true,
    this.daysOpen = 0,
  });

  final int id;
  final String number;
  final int unitId;
  final String unitCode;
  final String productName;
  final int? consignorId;
  final String consignorName;
  final String consignorPhone;
  final int? agreementId;
  final String agreementNumber;

  /// The policy the consignor actually signed — read from the agreement, not
  /// from the shop's current default. Changing the setting changes the next
  /// voucher, never a claim on a page already in force.
  final String liabilityPolicy;
  final double liabilityCap;
  final double declaredValue;
  final String kind;
  final DateTime? occurredOn;
  final DateTime discoveredAt;
  final String reportedByName;
  final String narrative;
  final String responsibility;
  final double assessedValue;

  /// Whether anybody has actually decided. An unassessed incident's zero is
  /// not the same zero as an assessed nothing.
  final bool isAssessed;

  /// What the liability matrix says, shown beside the typed assessment rather
  /// than instead of it: the matrix is a default the shop can argue away
  /// from, and showing both is what makes the argument visible.
  final double suggestedValue;
  final String resolution;
  final DateTime? resolvedAt;
  final String settlementRef;
  final bool isOpen;
  final int daysOpen;

  factory ConsignmentIncident.fromJson(Map<String, Object?> json) {
    DateTime? when(Object? value) =>
        value == null ? null : DateTime.tryParse('$value');
    return ConsignmentIncident(
      id: _intOf(json['id']),
      number: json['number']?.toString() ?? '',
      unitId: _intOf(json['unit']),
      unitCode: json['unit_code']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      consignorId: (json['consignor'] as num?)?.toInt(),
      consignorName: json['consignor_name']?.toString() ?? '',
      consignorPhone: json['consignor_phone']?.toString() ?? '',
      agreementId: (json['agreement'] as num?)?.toInt(),
      agreementNumber: json['agreement_number']?.toString() ?? '',
      liabilityPolicy:
          json['liability_policy']?.toString() ??
          ConsignmentLiability.ownerRisk,
      liabilityCap: _doubleOrNull(json['liability_cap']) ?? 0,
      declaredValue: _doubleOrNull(json['declared_value']) ?? 0,
      kind: json['kind']?.toString() ?? '',
      occurredOn: when(json['occurred_on']),
      discoveredAt: when(json['discovered_at']) ?? DateTime.now(),
      reportedByName: json['reported_by_name']?.toString() ?? '',
      narrative: json['narrative']?.toString() ?? '',
      responsibility:
          json['responsibility']?.toString() ??
          ConsignmentResponsibility.undetermined,
      assessedValue: _doubleOrNull(json['assessed_value']) ?? 0,
      isAssessed: json['is_assessed'] == true,
      suggestedValue: _doubleOrNull(json['suggested_value']) ?? 0,
      resolution:
          json['resolution']?.toString() ?? ConsignmentResolution.pending,
      resolvedAt: when(json['resolved_at']),
      settlementRef: json['settlement_ref']?.toString() ?? '',
      isOpen: json['is_open'] == true,
      daysOpen: _intOf(json['days_open']),
    );
  }
}

/// What happened. Five answers, because a dispute is not a loss.
class ConsignmentIncidentKind {
  const ConsignmentIncidentKind._();

  static const damaged = 'damaged';
  static const lost = 'lost';
  static const stolen = 'stolen';
  static const destroyed = 'destroyed';
  static const dispute = 'dispute';

  static const all = [damaged, lost, stolen, destroyed, dispute];
}

/// Who is responsible. Five answers including *undetermined*, which is the
/// honest one on day one and must be representable.
class ConsignmentResponsibility {
  const ConsignmentResponsibility._();

  static const shop = 'shop';
  static const consignor = 'consignor';
  static const thirdParty = 'third_party';
  static const forceMajeure = 'force_majeure';
  static const undetermined = 'undetermined';

  static const all = [undetermined, shop, thirdParty, forceMajeure, consignor];
}

/// How a claim was closed. ``pending`` is the only one that leaves money
/// outstanding.
class ConsignmentResolution {
  const ConsignmentResolution._();

  static const pending = 'pending';
  static const paid = 'paid';
  static const replaced = 'replaced';
  static const waived = 'waived';
  static const insured = 'insured';
  static const noClaim = 'no_claim';

  static const closing = [paid, replaced, waived, insured, noClaim];
}

/// What one draft incident says before it is written.
class ConsignmentIncidentDraft {
  const ConsignmentIncidentDraft({
    required this.kind,
    required this.narrative,
    this.occurredOn,
    this.responsibility,
    this.cameraId,
  });

  final String kind;
  final String narrative;
  final DateTime? occurredOn;
  final String? responsibility;
  final int? cameraId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind,
      'narrative': narrative,
      if (occurredOn != null)
        'occurred_on': occurredOn!.toIso8601String().split('T').first,
      'responsibility': ?responsibility,
      'camera': ?cameraId,
    };
  }
}

/// Money in the drawer that belongs to somebody who never came back.
///
/// The normal case, not the edge. What it is **not** is income: nothing in
/// this system ever converts an unclaimed payout into the shop's money on a
/// timer.
class UnclaimedPayoutAging {
  const UnclaimedPayoutAging({required this.buckets, required this.lines});

  final Map<String, UnclaimedPayoutBucket> buckets;
  final List<ConsignmentPayable> lines;

  factory UnclaimedPayoutAging.fromJson(Map<String, Object?> json) {
    final raw = json['buckets'];
    final buckets = <String, UnclaimedPayoutBucket>{};
    if (raw is Map<String, Object?>) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map<String, Object?>) {
          buckets[entry.key] = UnclaimedPayoutBucket.fromJson(value);
        }
      }
    }
    final lines = json['lines'];
    return UnclaimedPayoutAging(
      buckets: buckets,
      lines: lines is List
          ? lines
                .whereType<Map<String, Object?>>()
                .map(ConsignmentPayable.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class UnclaimedPayoutBucket {
  const UnclaimedPayoutBucket({required this.count, required this.value});

  final int count;
  final double value;

  factory UnclaimedPayoutBucket.fromJson(Map<String, Object?> json) {
    return UnclaimedPayoutBucket(
      count: _intOf(json['count']),
      value: _doubleOrNull(json['value']) ?? 0,
    );
  }
}
