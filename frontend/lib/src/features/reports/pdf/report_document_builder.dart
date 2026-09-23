/// Turns a report payload into the printable document.
///
/// Four things the printed version used to leave out, all of them defects an
/// accountant found before a developer did:
///
/// * **Truncation.** Sections carry a row cap and the payload has always said
///   how many rows were left out; the builder read the columns and the rows and
///   threw the metadata away. A month of stock movements printed 120 lines out
///   of thousands, under a header badged "archive" and a checksum reference.
///
/// * **Totals.** A schedule that supports a stated figure has to foot to it.
///   Sections now carry their own totals and the table prints them, including
///   the distinction between "what the printed rows add up to" and "what every
///   row adds up to" when rows were omitted.
///
/// * **Which figures lead.** The header grid took the first eight entries of
///   the summary map, so a report with ten lost two at random. The report now
///   names its own headline figures and they go first.
///
/// * **Definitions.** Nothing on the page said what "gross sales" included,
///   which basis the profit was on, or whether the period could still change.
///   The payload's notes become a closing block.
library;

import 'dart:typed_data';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/pos_user.dart';
import '../../../data/models/report_run.dart';
import '../../../data/models/shop_settings.dart';
import '../../../shared/formatters.dart';
import '../report_labels.dart';
import '../report_titles.dart';
import 'report_pdf.dart';

/// How many summary figures the header grid shows. The report's own headline
/// list always comes first and is never trimmed away.
const _metricGridLimit = 8;

BusinessReportPdfDocument buildBusinessReportPdfDocument({
  required ReportRun run,
  required AppLocalizations l10n,
  required PosUser currentUser,
  required bool includeAuditTrail,
  required bool includePreparedBy,
  ShopSettings? shopSettings,
  Uint8List? shopLogoBytes,
}) {
  final payload = run.payload;
  final period = _periodFromPayload(payload);
  final summary = _mapFromPayload(payload['summary']);
  final headline = _stringList(payload['headline']);

  final sections = <ReportPdfSection>[
    ..._sectionsFromPayload(payload),
    ...?_notesSection(payload, l10n),
  ];

  return BusinessReportPdfDocument(
    type: _businessReportType(run.reportType),
    title: reportTitle(l10n, run.reportType),
    businessName: shopSettings?.shopName.trim().isNotEmpty == true
        ? shopSettings!.shopName.trim()
        : l10n.appTitle,
    generatedAt: run.completedAt ?? run.createdAt,
    businessLogoBytes: shopLogoBytes,
    businessHeader: _trimmedOrNull(shopSettings?.receiptHeader),
    businessFooter: _trimmedOrNull(shopSettings?.receiptFooter),
    generatedBy: includePreparedBy ? currentUser.label : null,
    reference: _referenceFor(run),
    period: period,
    shopSettingFields: _shopSettingFieldsForReport(
      run.reportType,
      shopSettings,
    ),
    metrics: _metricsFromSummary(summary, headline, payload),
    sections: sections,
    auditTrail: includeAuditTrail
        ? [
            ReportPdfAuditEntry(
              occurredAt: run.createdAt,
              action: 'إنشاء التقرير',
              actor: run.requestedByUsername ?? currentUser.label,
              note: 'رقم التشغيل ${run.id}، عدد الصفوف ${run.rowCount}',
            ),
          ]
        : const [],
  );
}

/// The figures reference. Prefers the *figures* checksum, because that is the
/// one two runs of an unchanged period share — quoting the run checksum on a
/// printed page invites a reader to compare two references that were designed
/// to differ.
String _referenceFor(ReportRun run) {
  final figures = run.figuresChecksum;
  if (figures.isNotEmpty) {
    return figures.substring(0, figures.length < 12 ? figures.length : 12);
  }
  if (run.checksum.isNotEmpty) {
    return run.checksum.substring(0, 12);
  }
  return 'تقرير-${run.id}';
}

BusinessReportType _businessReportType(ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary ||
    ReportRunType.productMargin ||
    ReportRunType.salesByStaff ||
    ReportRunType.unitMargin => BusinessReportType.salesSummary,
    ReportRunType.paymentMethods ||
    ReportRunType.cashPosition => BusinessReportType.paymentSummary,
    ReportRunType.registerClosure => BusinessReportType.registerSessionArchive,
    ReportRunType.inventoryStatus ||
    ReportRunType.unitAging => BusinessReportType.inventorySnapshot,
    ReportRunType.stockMovements ||
    ReportRunType.unitLedger => BusinessReportType.stockMovementArchive,
    ReportRunType.purchasingSummary ||
    ReportRunType.payablesAging => BusinessReportType.purchasingSummary,
    ReportRunType.reorderItems => BusinessReportType.reorderPlan,
    ReportRunType.payrollSummary => BusinessReportType.payrollSummary,
    ReportRunType.profitCosts ||
    ReportRunType.expenseBreakdown ||
    ReportRunType.monthEndPack => BusinessReportType.profitAndCosts,
    ReportRunType.receivablesAging ||
    ReportRunType.customerStatement => BusinessReportType.customerStatement,
    ReportRunType.supplierStatement => BusinessReportType.supplierStatement,
    ReportRunType.discountAudit => BusinessReportType.discountAudit,
    ReportRunType.balanceSheet => BusinessReportType.balanceSheet,
    ReportRunType.consignmentLedger => BusinessReportType.consignmentLedger,
  };
}

ReportPdfPeriod? _periodFromPayload(Map<String, Object?> payload) {
  final period = _mapFromPayload(payload['period']);
  final start = _dateOrNull(period['start_date']);
  final end = _dateOrNull(period['end_date']);
  if (start == null && end == null) {
    return null;
  }
  return ReportPdfPeriod(start: start, end: end);
}

/// The header grid: the report's own headline figures first, then whatever
/// else fits — never "the first eight keys that happened to come out of a map".
List<ReportPdfMetric> _metricsFromSummary(
  Map<String, Object?> summary,
  List<String> headline,
  Map<String, Object?> payload,
) {
  final previous = _mapFromPayload(payload['previous_summary']);
  final ordered = <String>[
    ...headline.where(summary.containsKey),
    ...summary.keys.where((key) => !headline.contains(key)),
  ];
  return [
    for (final key in ordered.take(_metricGridLimit))
      ReportPdfMetric(
        label: reportLabel(key),
        value: reportValue(key, summary[key]),
        note: previous.isEmpty ? null : _comparisonNote(key, previous[key]),
      ),
  ];
}

String? _comparisonNote(String key, Object? previousValue) {
  if (previousValue == null) {
    return null;
  }
  return 'السابق: ${reportValue(key, previousValue)}';
}

List<ReportPdfSection> _sectionsFromPayload(Map<String, Object?> payload) {
  final sections = payload['sections'];
  if (sections is! List) {
    return const [];
  }
  return [
    for (final section in sections)
      if (section is Map) _sectionFrom(section.cast<String, Object?>()),
  ];
}

ReportPdfSection _sectionFrom(Map<String, Object?> section) {
  final metadata = _mapFromPayload(section['metadata']);
  return ReportPdfSection(
    heading: reportLabel(section['key']?.toString() ?? ''),
    // A schedule that omitted rows says so on the page, in words, next to the
    // rows it did print.
    paragraphs: [
      if (metadata['truncated'] == true)
        'معروض ${metadata['returned_count']} من '
            '${metadata['total_count']} صفًا — التقرير مختصر.',
    ],
    tables: [_tableFromSection(section)],
  );
}

ReportPdfTable _tableFromSection(Map<String, Object?> section) {
  final columns = _stringList(section['columns']);
  final types = _mapFromPayload(section['column_types']);
  final rows = <List<String>>[
    for (final row in (section['rows'] as List? ?? const []))
      if (row is Map)
        [
          for (final column in columns)
            reportValue(
              column,
              row.cast<String, Object?>()[column],
              columnType: types[column]?.toString(),
            ),
        ],
  ];
  rows.addAll(_totalRows(section, columns, types));

  return ReportPdfTable(
    columns: [for (final column in columns) reportLabel(column)],
    rows: rows,
  );
}

/// The totals under the column, and — when rows were left out — the total of
/// every row as well. Both, or the reader cannot tell the difference between a
/// complete schedule and a short one.
List<List<String>> _totalRows(
  Map<String, Object?> section,
  List<String> columns,
  Map<String, Object?> types,
) {
  final totals = _mapFromPayload(section['totals']);
  if (totals.isEmpty || columns.isEmpty) {
    return const [];
  }
  final shown = _mapFromPayload(totals['shown']);
  final full = _mapFromPayload(totals['full']);
  if (shown.isEmpty) {
    return const [];
  }

  List<String> buildRow(String label, Map<String, Object?> values) {
    return [
      label,
      for (final column in columns.skip(1))
        values.containsKey(column)
            ? reportValue(
                column,
                values[column],
                columnType: types[column]?.toString(),
              )
            : '',
    ];
  }

  final rows = <List<String>>[buildRow('الإجمالي', shown)];
  final truncated =
      _mapFromPayload(section['metadata'])['truncated'] == true &&
      !_sameTotals(shown, full);
  if (truncated) {
    rows.add(buildRow('إجمالي كل الصفوف', full));
  }
  return rows;
}

bool _sameTotals(Map<String, Object?> shown, Map<String, Object?> full) {
  if (full.isEmpty) {
    return true;
  }
  for (final entry in shown.entries) {
    if ('${full[entry.key]}' != '${entry.value}') {
      return false;
    }
  }
  return true;
}

/// The closing block: what each figure includes, which basis, which date rule.
List<ReportPdfSection>? _notesSection(
  Map<String, Object?> payload,
  AppLocalizations l10n,
) {
  final notes = payload['notes'];
  if (notes is! List || notes.isEmpty) {
    return null;
  }
  final sentences = <String>[
    for (final note in notes)
      if (note is Map)
        ?reportNote(
          note['code']?.toString() ?? '',
          args: _mapFromPayload(note['args']),
        ),
  ];
  if (sentences.isEmpty) {
    return null;
  }
  return [
    ReportPdfSection(heading: l10n.reportNotesTitle, paragraphs: sentences),
  ];
}

Map<String, Object?> _mapFromPayload(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final item in value)
      if (item != null) item.toString(),
  ];
}

DateTime? _dateOrNull(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

List<ReportPdfField> _shopSettingFieldsForReport(
  ReportRunType type,
  ShopSettings? settings,
) {
  if (settings == null) {
    return const [];
  }

  return switch (type) {
    // A loss-making article is only possible where the loss guard allows it,
    // so a margin report says which way the shop has it set.
    ReportRunType.unitMargin => [
      ReportPdfField(
        label: 'منع البيع بخسارة',
        value: _boolLabel(settings.preventSellingAtLoss),
      ),
    ],
    ReportRunType.salesSummary ||
    ReportRunType.productMargin ||
    ReportRunType.discountAudit ||
    ReportRunType.salesByStaff => [
      ReportPdfField(
        label: 'منع البيع بخسارة',
        value: _boolLabel(settings.preventSellingAtLoss),
      ),
      ReportPdfField(
        label: 'نافذة إرجاع الكاشير',
        value: '${settings.cashierReturnWindowHours} ساعة',
      ),
      ReportPdfField(
        label: 'السماح بالبيع دون مخزون',
        value: _boolLabel(settings.allowOverselling),
      ),
    ],
    ReportRunType.paymentMethods || ReportRunType.cashPosition => [
      ReportPdfField(
        label: 'طرق الدفع المفعلة',
        value: _enabledPaymentMethods(settings),
      ),
      ReportPdfField(
        label: 'إيصال البطاقة مطلوب',
        value: _boolLabel(settings.requireCardPaymentReceipt),
      ),
      if (settings.enableCardPayments)
        ReportPdfField(
          label: 'عمولة البطاقة',
          value: _percentField(settings.cardCommissionPercent),
        ),
      if (settings.enableTransferPayments)
        ReportPdfField(
          label: 'عمولة التحويل',
          value: _percentField(settings.transferCommissionPercent),
        ),
      if (settings.trustedCardTerminalIds.isNotEmpty)
        ReportPdfField(
          label: 'محطات البطاقة المعتمدة',
          value: settings.trustedCardTerminalIds.join('، '),
        ),
    ],
    ReportRunType.registerClosure => [
      ReportPdfField(
        label: 'نقدية البداية مطلوبة',
        value: _boolLabel(settings.requireOpeningCash),
      ),
      ReportPdfField(
        label: 'الطباعة التلقائية للإيصالات',
        value: _boolLabel(settings.autoPrintReceipts),
      ),
      // With a floor set, "on" only holds for sales above it — a report that
      // says nothing about the floor overstates how many receipts were printed.
      if (settings.autoPrintReceipts && settings.hasAutoPrintFloor)
        ReportPdfField(
          label: 'الحد الأدنى للطباعة التلقائية',
          value: _autoPrintFloorLabel(settings),
        ),
      ReportPdfField(
        label: 'نافذة إرجاع الكاشير',
        value: '${settings.cashierReturnWindowHours} ساعة',
      ),
    ],
    ReportRunType.inventoryStatus ||
    ReportRunType.stockMovements ||
    ReportRunType.reorderItems => [
      ReportPdfField(
        label: 'حد تنبيه المخزون المنخفض',
        value: '${settings.lowStockThreshold}',
      ),
      ReportPdfField(
        label: 'طريقة تقييم المخزون',
        value: _valuationMethodLabel(settings.inventoryValuationMethod),
      ),
      ReportPdfField(
        label: 'السماح بالبيع دون مخزون',
        value: _boolLabel(settings.allowOverselling),
      ),
    ],
    ReportRunType.purchasingSummary || ReportRunType.payablesAging => [
      ReportPdfField(
        label: 'حد تنبيه المخزون المنخفض',
        value: '${settings.lowStockThreshold}',
      ),
      if (settings.enableTransferPayments)
        ReportPdfField(
          label: 'عمولة التحويل',
          value: _percentField(settings.transferCommissionPercent),
        ),
    ],
    // Money reports carry the valuation method, because it decides the cost of
    // sales the profit figure is built on — and, on the balance sheet, what
    // the goods on the shelf are stated at.
    ReportRunType.profitCosts ||
    ReportRunType.monthEndPack ||
    ReportRunType.balanceSheet => [
      ReportPdfField(
        label: 'طريقة تقييم المخزون',
        value: _valuationMethodLabel(settings.inventoryValuationMethod),
      ),
    ],
    ReportRunType.payrollSummary ||
    ReportRunType.expenseBreakdown ||
    ReportRunType.receivablesAging ||
    ReportRunType.customerStatement ||
    ReportRunType.supplierStatement ||
    // Identified stock is valued article by article, whatever the shop's
    // valuation method, so no stock setting changes these three.
    ReportRunType.unitAging ||
    ReportRunType.unitLedger ||
    ReportRunType.consignmentLedger => const [],
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String _enabledPaymentMethods(ShopSettings settings) {
  final methods = [
    if (settings.enableCashPayments) 'نقدًا',
    if (settings.enableCardPayments) 'بطاقة',
    if (settings.enableTransferPayments) 'تحويل',
  ];
  return methods.isEmpty ? 'لا توجد طرق دفع مفعلة' : methods.join('، ');
}

String _valuationMethodLabel(InventoryValuationMethod method) {
  return switch (method) {
    InventoryValuationMethod.fifo => 'الوارد أولًا صادر أولًا (FIFO)',
    InventoryValuationMethod.lifo => 'الوارد أخيرًا صادر أولًا (LIFO)',
    InventoryValuationMethod.movingAverage => 'المتوسط المرجح',
  };
}

String _autoPrintFloorLabel(ShopSettings settings) {
  final lines = settings.autoPrintMinLineCount ?? 0;
  final total = settings.autoPrintMinTotal ?? 0;
  return [
    if (lines > 0) '$lines صنف',
    if (total > 0) formatMoney(total),
  ].join(' أو ');
}

String _boolLabel(bool value) => value ? 'نعم' : 'لا';

String _percentField(Object? value) {
  return reportValue('share_percent', value, columnType: 'percent');
}
