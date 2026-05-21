import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/pos_user.dart';
import '../../../data/models/report_run.dart';
import 'report_pdf.dart';

BusinessReportPdfDocument buildBusinessReportPdfDocument({
  required ReportRun run,
  required AppLocalizations l10n,
  required PosUser currentUser,
  required bool includeAuditTrail,
  required bool includePreparedBy,
}) {
  final payload = run.payload;
  final period = _periodFromPayload(payload);
  final sections = _sectionsFromPayload(payload);
  final summary = _mapFromPayload(payload['summary']);

  return BusinessReportPdfDocument(
    type: _businessReportType(run.reportType),
    title: _reportTitle(l10n, run.reportType),
    businessName: l10n.appTitle,
    generatedAt: run.completedAt ?? run.createdAt,
    generatedBy: includePreparedBy ? currentUser.label : null,
    reference: run.checksum.isEmpty
        ? 'RPT-${run.id}'
        : run.checksum.substring(0, 12),
    period: period,
    metrics: _metricsFromSummary(summary),
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

BusinessReportType _businessReportType(ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => BusinessReportType.salesSummary,
    ReportRunType.paymentMethods => BusinessReportType.paymentSummary,
    ReportRunType.registerClosure => BusinessReportType.registerSessionArchive,
    ReportRunType.inventoryStatus => BusinessReportType.inventorySnapshot,
    ReportRunType.stockMovements => BusinessReportType.stockMovementArchive,
    ReportRunType.purchasingSummary => BusinessReportType.purchasingSummary,
  };
}

String _reportTitle(AppLocalizations l10n, ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => l10n.reportSalesSummaryTitle,
    ReportRunType.paymentMethods => l10n.reportPaymentsTitle,
    ReportRunType.registerClosure => l10n.reportRegisterSessionsTitle,
    ReportRunType.inventoryStatus => l10n.reportInventoryValueTitle,
    ReportRunType.stockMovements => l10n.reportStockMovementTitle,
    ReportRunType.purchasingSummary => l10n.reportPurchasesTitle,
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

List<ReportPdfMetric> _metricsFromSummary(Map<String, Object?> summary) {
  return [
    for (final entry in summary.entries.take(8))
      ReportPdfMetric(
        label: _labelFor(entry.key),
        value: _stringValue(entry.value),
      ),
  ];
}

List<ReportPdfSection> _sectionsFromPayload(Map<String, Object?> payload) {
  final sections = payload['sections'];
  if (sections is! List) {
    return const [];
  }
  return [
    for (final section in sections)
      if (section is Map)
        ReportPdfSection(
          heading: _labelFor(section['key']?.toString() ?? ''),
          tables: [_tableFromSection(section.cast<String, Object?>())],
        ),
  ];
}

ReportPdfTable _tableFromSection(Map<String, Object?> section) {
  final columns = (section['columns'] as List? ?? const [])
      .map((column) => _labelFor(column.toString()))
      .toList(growable: false);
  final rows = (section['rows'] as List? ?? const [])
      .whereType<Map>()
      .map(
        (row) => [
          for (final column in (section['columns'] as List? ?? const []))
            _stringValue(row[column.toString()]),
        ],
      )
      .toList(growable: false);

  return ReportPdfTable(columns: columns, rows: rows);
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

DateTime? _dateOrNull(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

String _stringValue(Object? value) {
  if (value == null || value == '') {
    return '-';
  }
  if (value is String && value.contains('T')) {
    final dateTime = DateTime.tryParse(value);
    if (dateTime != null) {
      final local = dateTime.toLocal();
      final date = '${local.year}/${_two(local.month)}/${_two(local.day)}';
      final time = '${_two(local.hour)}:${_two(local.minute)}';
      return '$date $time';
    }
  }
  return value.toString();
}

String _two(int value) => value.toString().padLeft(2, '0');

String _labelFor(String key) {
  return _arabicLabels[key] ?? key.replaceAll('_', ' ');
}

const _arabicLabels = {
  'summary': 'الملخص',
  'top_products': 'أفضل المنتجات',
  'recent_orders': 'آخر الطلبات',
  'payment_methods': 'طرق الدفع',
  'register_sessions': 'جلسات الدرج',
  'inventory_items': 'المخزون',
  'movement_mix': 'ملخص الحركات',
  'stock_movements': 'حركات المخزون',
  'purchase_orders': 'أوامر الشراء',
  'supplier_balances': 'أرصدة الموردين',
  'metric': 'المؤشر',
  'value': 'القيمة',
  'gross_sales': 'إجمالي المبيعات',
  'discount_total': 'الخصومات',
  'refund_total': 'المرتجعات',
  'net_sales': 'صافي المبيعات',
  'gross_profit': 'الربح الإجمالي',
  'profit_margin_percent': 'هامش الربح',
  'paid_order_count': 'الطلبات المدفوعة',
  'voided_order_count': 'الطلبات الملغاة',
  'return_count': 'المرتجعات',
  'items_sold': 'القطع المباعة',
  'product_name': 'المنتج',
  'quantity': 'الكمية',
  'revenue': 'الإيراد',
  'profit': 'الربح',
  'receipt_number': 'رقم الإيصال',
  'status': 'الحالة',
  'total': 'الإجمالي',
  'created_at': 'تاريخ الإنشاء',
  'payment_total': 'إجمالي المدفوعات',
  'commission_total': 'إجمالي العمولات',
  'payment_count': 'عدد المدفوعات',
  'method': 'الطريقة',
  'commission': 'العمولة',
  'count': 'العدد',
  'session_count': 'عدد الجلسات',
  'open_count': 'المفتوحة',
  'closed_count': 'المغلقة',
  'variance_total': 'إجمالي الفرق',
  'session_number': 'رقم الجلسة',
  'opened_at': 'فتحت في',
  'closed_at': 'أغلقت في',
  'opening_cash': 'نقدية البداية',
  'closing_cash': 'نقدية الإغلاق',
  'expected_cash': 'النقدية المتوقعة',
  'cash_variance': 'فرق النقدية',
  'product_count': 'عدد المنتجات',
  'stock_item_count': 'بنود المخزون',
  'low_stock_count': 'مخزون منخفض',
  'out_of_stock_count': 'نافد',
  'retail_stock_value': 'قيمة البيع',
  'sku': 'SKU',
  'quantity_on_hand': 'المتوفر',
  'quantity_committed': 'المحجوز',
  'quantity_expected': 'المتوقع',
  'reorder_level': 'حد الطلب',
  'retail_value': 'قيمة البيع',
  'movement_count': 'عدد الحركات',
  'quantity_moved': 'الكمية المتحركة',
  'movement_type': 'نوع الحركة',
  'on_hand_before': 'قبل',
  'on_hand_after': 'بعد',
  'created_by': 'أنشأه',
  'note': 'ملاحظة',
  'purchase_total': 'إجمالي المشتريات',
  'purchase_order_count': 'عدد أوامر الشراء',
  'open_order_count': 'أوامر مفتوحة',
  'supplier_count': 'عدد الموردين',
  'order_number': 'رقم الأمر',
  'supplier_name': 'المورد',
  'balance_due': 'المستحق',
  'due_date': 'تاريخ الاستحقاق',
  'payable_balance': 'رصيد مستحق',
  'credit_balance': 'رصيد دائن',
  'net_balance': 'الصافي',
};
