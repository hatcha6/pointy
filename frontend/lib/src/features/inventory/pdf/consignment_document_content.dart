import '../../../data/models/consignment.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/formatters.dart';

/// What the two consignment documents actually *say*, decided here and rendered
/// somewhere else.
///
/// Separated from the PDF widgets on purpose, and the reason is Phase B's:
/// identifiers were added to the order serializer, the receipt printed from a
/// different payload, and the one test passed by handing its key straight to
/// the encoder — so nothing ever reached paper and nothing failed. Rendering
/// cannot be asserted (an embedded Arabic font writes glyph indices, not text),
/// but the content can be, and the renderer has no second source for it.
class ConsignmentDocumentContent {
  const ConsignmentDocumentContent({
    required this.badge,
    required this.number,
    this.fields = const [],
    this.termFields = const [],
    this.clause = '',
    this.tableColumns = const [],
    this.tableRows = const [],
    this.total,
    this.notes = '',
    this.tableTitle,
    this.termsTitle = 'شروط التسوية',
    this.tableFlex = const [3, 2.4, 2.2, 1.6],
  });

  final String badge;
  final String number;
  final List<ConsignmentDocumentField> fields;
  final List<ConsignmentDocumentField> termFields;

  /// The liability sentence **as it was printed and signed**. Empty on a payout
  /// receipt, which carries no clause of its own.
  final String clause;

  final List<String> tableColumns;
  final List<List<String>> tableRows;
  final ConsignmentDocumentField? total;
  final String notes;

  /// The heading over the table. Null keeps the two vouchers' own: what was
  /// taken in, or what the money was for.
  final String? tableTitle;

  /// The heading over [termFields].
  final String termsTitle;

  /// Relative column widths, in the same order as [tableColumns]. The table
  /// reverses widths, alignments and cells together for RTL, so they are
  /// written here in reading order.
  final List<double> tableFlex;

  /// Every string this document will put on paper, which is what a test asks
  /// about when it wants to know whether something reached the page.
  List<String> get allText => [
    badge,
    number,
    for (final field in fields) ...[field.label, field.value],
    for (final field in termFields) ...[field.label, field.value],
    if (clause.isNotEmpty) clause,
    ...tableColumns,
    for (final row in tableRows) ...row,
    if (total != null) ...[total!.label, total!.value],
    if (notes.isNotEmpty) notes,
  ];
}

class ConsignmentDocumentField {
  const ConsignmentDocumentField(this.label, this.value);

  final String label;
  final String value;
}

/// *سند استلام أمانة* — the page both parties sign when the goods come in.
ConsignmentDocumentContent buildConsignmentVoucherContent({
  required ConsignmentAgreement agreement,
  List<StockUnit> units = const [],
}) {
  return ConsignmentDocumentContent(
    badge: 'سند استلام أمانة',
    number: agreement.number,
    fields: [
      ConsignmentDocumentField('رقم السند', agreement.number),
      ConsignmentDocumentField('صاحب الأمانة', agreement.consignorName),
      if (agreement.consignorPhone.trim().isNotEmpty)
        ConsignmentDocumentField('الهاتف', agreement.consignorPhone.trim()),
      if (agreement.signedAt != null)
        ConsignmentDocumentField(
          'تاريخ الاستلام',
          _dateTime(agreement.signedAt!),
        ),
      if (agreement.expiresOn != null)
        ConsignmentDocumentField('يُستلم قبل', _date(agreement.expiresOn!)),
    ],
    termFields: [
      ConsignmentDocumentField(
        'طريقة التسوية',
        agreement.isFixed ? 'مبلغ ثابت' : 'نسبة عمولة',
      ),
      if (agreement.isFixed && agreement.payoutRate != null)
        ConsignmentDocumentField(
          'المبلغ المستحق لصاحب الأمانة',
          formatMoney(agreement.payoutRate!),
        ),
      if (!agreement.isFixed && agreement.commissionPct != null)
        ConsignmentDocumentField(
          'عمولة المحل',
          ltrIsolated('${trimPercent(agreement.commissionPct!)}%'),
        ),
      if (agreement.reservePrice != null)
        ConsignmentDocumentField(
          'أقل سعر بيع',
          formatMoney(agreement.reservePrice!),
        ),
      if (agreement.liabilityCap != null)
        ConsignmentDocumentField(
          'حد التعويض',
          formatMoney(agreement.liabilityCap!),
        ),
    ],
    // Verbatim, from the agreement rather than from the shop's live template: a
    // shop that rewords its voucher next year has not reworded this page, and
    // that difference is the whole reason the column exists.
    clause: agreement.liabilityClause.trim(),
    tableColumns: const ['الصنف', 'المعرّف', 'الحالة', 'القيمة المقدّرة'],
    tableRows: [
      for (final unit in units)
        [
          unit.variantName.isNotEmpty ? unit.variantName : unit.productName,
          unit.code,
          describeUnitCondition(unit),
          unit.declaredValue == null ? '—' : formatMoney(unit.declaredValue!),
        ],
    ],
    notes: agreement.notes.trim(),
  );
}

/// *سند صرف أمانة* — the receipt for money handed across the counter.
ConsignmentDocumentContent buildConsignorPayoutContent({
  required ConsignorPayout payout,
}) {
  return ConsignmentDocumentContent(
    badge: 'سند صرف أمانة',
    number: payout.number,
    fields: [
      ConsignmentDocumentField('رقم السند', payout.number),
      ConsignmentDocumentField('صاحب الأمانة', payout.consignorName),
      if (payout.consignorPhone.trim().isNotEmpty)
        ConsignmentDocumentField('الهاتف', payout.consignorPhone.trim()),
      if (payout.paidAt != null)
        ConsignmentDocumentField('تاريخ الصرف', _dateTime(payout.paidAt!)),
      ConsignmentDocumentField(
        'طريقة الصرف',
        payout.isCash ? 'نقدًا من الصندوق' : 'حوالة مصرفية',
      ),
      if (payout.reference.trim().isNotEmpty)
        ConsignmentDocumentField('المرجع', payout.reference.trim()),
    ],
    tableColumns: const ['الصنف', 'المعرّف', 'تاريخ البيع', 'المستحق'],
    tableRows: [
      for (final line in payout.lines)
        [
          line.productName,
          line.code,
          line.soldAt == null ? '—' : _date(line.soldAt!),
          formatMoney(line.payoutDue),
        ],
    ],
    total: ConsignmentDocumentField(
      'إجمالي المبلغ المستلم',
      formatMoney(payout.amount),
    ),
    notes: payout.notes.trim(),
  );
}

/// *كشف حساب أمانات* — the page handed to a consignor who asks what the shop
/// holds and owes them.
///
/// The shop's commission and the sale prices stay off it: this is the
/// consignor's copy, and under a fixed payout the sale price is the shop's
/// margin.
ConsignmentDocumentContent buildConsignorStatementContent({
  required ConsignorStatement statement,
  required List<ConsignorStatementLine> lines,
  required DateTime printedAt,
  DateTime? start,
  DateTime? end,
}) {
  final figures = statement.figures;
  final period = switch ((start, end)) {
    (final from?, final to?) => '${_date(from)} — ${_date(to)}',
    (final from?, null) => 'من ${_date(from)}',
    (null, final to?) => 'حتى ${_date(to)}',
    _ => '',
  };
  return ConsignmentDocumentContent(
    badge: 'كشف حساب أمانات',
    number: _date(printedAt),
    fields: [
      ConsignmentDocumentField('صاحب الأمانة', statement.consignorName),
      if (statement.consignorPhone.trim().isNotEmpty)
        ConsignmentDocumentField('الهاتف', statement.consignorPhone.trim()),
      if (period.isNotEmpty) ConsignmentDocumentField('الفترة', period),
      ConsignmentDocumentField('تاريخ الكشف', _dateTime(printedAt)),
    ],
    tableTitle: 'الأمانات',
    tableColumns: const ['الصنف', 'المعرّف', 'الحالة', 'التاريخ', 'المستحق'],
    tableFlex: const [3, 2.2, 1.7, 1.6, 1.8],
    tableRows: [
      for (final line in lines)
        [
          line.productName,
          line.code,
          _stateLabel(line.state),
          line.activityAt == null ? '—' : _date(line.activityAt!),
          switch (line.state) {
            ConsignorLineState.awaiting => formatMoney(line.netDue),
            ConsignorLineState.paid => formatMoney(line.payoutDue),
            _ => '—',
          },
        ],
    ],
    termsTitle: 'الملخص',
    termFields: [
      ConsignmentDocumentField(
        'في العهدة',
        '${figures.heldCount} — ${formatMoney(figures.heldDeclaredValue)}',
      ),
      ConsignmentDocumentField(
        'مباعة بانتظار الاستلام',
        '${figures.awaitingCount}',
      ),
      ConsignmentDocumentField(
        period.isEmpty ? 'إجمالي ما صُرف' : 'ما صُرف خلال الفترة',
        formatMoney(figures.periodPaidTotal),
      ),
      if (figures.receivable > 0)
        ConsignmentDocumentField(
          'مبالغ سبق صرفها عن أمانات أُعيدت',
          formatMoney(figures.receivable),
        ),
    ],
    total: ConsignmentDocumentField(
      'المستحق لكم حاليًا',
      formatMoney(figures.payable),
    ),
  );
}

String _stateLabel(String state) => switch (state) {
  ConsignorLineState.awaiting => 'بانتظار الاستلام',
  ConsignorLineState.held => 'في العهدة',
  ConsignorLineState.paid => 'مصروفة',
  ConsignorLineState.returned => 'أُعيدت',
  _ => 'تلف أو فقدان',
};

/// The condition checklist as it was agreed, printed on the page both parties
/// keep. A dispute three months later is about what the watch looked like on
/// the day, and this is the only record made at the time.
String describeUnitCondition(StockUnit unit) {
  final parts = <String>[
    for (final entry in unit.attributes.entries)
      if (entry.value != null && '${entry.value}'.trim().isNotEmpty)
        '${entry.key}: ${entry.value}',
  ];
  if (unit.notes.trim().isNotEmpty) {
    parts.add(unit.notes.trim());
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
}

/// "15%" rather than "15.00%".
String trimPercent(double value) {
  final text = value.toStringAsFixed(2);
  return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/'
      '${local.day.toString().padLeft(2, '0')}';
}

String _dateTime(DateTime value) {
  final local = value.toLocal();
  return '${_date(local)} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
