import 'dart:typed_data';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/pos_user.dart';
import '../../../data/models/report_run.dart';
import '../../../data/models/shop_settings.dart';
import 'report_pdf.dart';

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
  final sections = _sectionsFromPayload(payload);
  final summary = _mapFromPayload(payload['summary']);

  return BusinessReportPdfDocument(
    type: _businessReportType(run.reportType),
    title: _reportTitle(l10n, run.reportType),
    businessName: shopSettings?.shopName.trim().isNotEmpty == true
        ? shopSettings!.shopName.trim()
        : l10n.appTitle,
    generatedAt: run.completedAt ?? run.createdAt,
    businessLogoBytes: shopLogoBytes,
    businessHeader: _trimmedOrNull(shopSettings?.receiptHeader),
    businessFooter: _trimmedOrNull(shopSettings?.receiptFooter),
    generatedBy: includePreparedBy ? currentUser.label : null,
    reference: run.checksum.isEmpty
        ? 'تقرير-${run.id}'
        : run.checksum.substring(0, 12),
    period: period,
    shopSettingFields: _shopSettingFieldsForReport(
      run.reportType,
      shopSettings,
    ),
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
        value: _displayValueForKey(entry.key, entry.value),
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
            _displayValueForKey(column.toString(), row[column.toString()]),
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

List<ReportPdfField> _shopSettingFieldsForReport(
  ReportRunType type,
  ShopSettings? settings,
) {
  if (settings == null) {
    return const [];
  }

  return switch (type) {
    ReportRunType.salesSummary => [
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
    ReportRunType.paymentMethods => [
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
          value: _formatPercent(settings.cardCommissionPercent),
        ),
      if (settings.enableTransferPayments)
        ReportPdfField(
          label: 'عمولة التحويل',
          value: _formatPercent(settings.transferCommissionPercent),
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
      ReportPdfField(
        label: 'نافذة إرجاع الكاشير',
        value: '${settings.cashierReturnWindowHours} ساعة',
      ),
    ],
    ReportRunType.inventoryStatus || ReportRunType.stockMovements => [
      ReportPdfField(
        label: 'حد تنبيه المخزون المنخفض',
        value: '${settings.lowStockThreshold}',
      ),
      ReportPdfField(
        label: 'السماح بالبيع دون مخزون',
        value: _boolLabel(settings.allowOverselling),
      ),
      ReportPdfField(
        label: 'منع البيع بخسارة',
        value: _boolLabel(settings.preventSellingAtLoss),
      ),
    ],
    ReportRunType.purchasingSummary => [
      ReportPdfField(
        label: 'حد تنبيه المخزون المنخفض',
        value: '${settings.lowStockThreshold}',
      ),
      if (settings.enableTransferPayments)
        ReportPdfField(
          label: 'عمولة التحويل',
          value: _formatPercent(settings.transferCommissionPercent),
        ),
    ],
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

String _displayValueForKey(String key, Object? value) {
  if (value == null || value == '') {
    return '-';
  }

  final raw = value.toString();
  final translatedValue = _valueLabel(raw);
  if (translatedValue != null) {
    return translatedValue;
  }
  if (value is bool) {
    return _boolLabel(value);
  }
  if (_moneyKeys.contains(key)) {
    return _formatMoney(raw);
  }
  if (_percentKeys.contains(key)) {
    return _formatPercent(raw);
  }
  return _stringValue(value);
}

String _boolLabel(bool value) => value ? 'نعم' : 'لا';

String? _valueLabel(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return null;
  }
  return _arabicValueLabels[normalized];
}

String _formatMoney(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.contains('د.ل')) {
    return normalized;
  }
  final amount = num.tryParse(normalized);
  if (amount == null) {
    return _compactCellValue(normalized);
  }
  return '${amount.toStringAsFixed(2)} د.ل';
}

String _formatPercent(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.endsWith('%')) {
    return normalized;
  }
  final percent = num.tryParse(normalized);
  if (percent == null) {
    return _compactCellValue(normalized);
  }
  return '${percent.toStringAsFixed(2)}%';
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
  return _compactCellValue(value.toString());
}

String _two(int value) => value.toString().padLeft(2, '0');

String _compactCellValue(String value) {
  const maxCellCharacters = 140;
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.length <= maxCellCharacters) {
    return normalized;
  }
  return '${normalized.substring(0, maxCellCharacters - 3)}...';
}

String _labelFor(String key) {
  final label = _arabicLabels[key];
  if (label != null) {
    return label;
  }
  final fallback = key
      .split('_')
      .map((part) => _arabicLabelTokens[part])
      .whereType<String>()
      .join(' ');
  return fallback.isEmpty ? 'بيان' : fallback;
}

const _moneyKeys = {
  'gross_sales',
  'discount_total',
  'refund_total',
  'net_sales',
  'gross_profit',
  'revenue',
  'profit',
  'total',
  'payment_total',
  'commission_total',
  'commission',
  'opening_cash',
  'closing_cash',
  'expected_cash',
  'cash_variance',
  'variance_total',
  'retail_stock_value',
  'retail_value',
  'purchase_total',
  'balance_due',
  'payable_balance',
  'credit_balance',
  'net_balance',
};

const _percentKeys = {'profit_margin_percent'};

const _arabicValueLabels = {
  'open': 'مفتوحة',
  'closed': 'مغلقة',
  'paid': 'مدفوعة',
  'void': 'ملغاة',
  'voided': 'ملغاة',
  'draft': 'مسودة',
  'submitted': 'مرسلة',
  'partial': 'مستلمة جزئيًا',
  'partially_received': 'مستلمة جزئيًا',
  'received': 'مستلمة',
  'cancelled': 'ملغاة',
  'canceled': 'ملغاة',
  'cash': 'نقدًا',
  'card': 'بطاقة',
  'transfer': 'تحويل',
  'pay_in': 'إيداع نقدي',
  'pay_out': 'سحب نقدي',
  'increase': 'زيادة مخزون',
  'decrease': 'نقص مخزون',
  'damaged': 'مخزون تالف',
  'expected': 'مخزون متوقع',
  'receive_expected': 'استلام مخزون متوقع',
  'receive_damaged': 'استلام تالف',
  'cancel_expected': 'إلغاء مخزون متوقع',
};

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
  'sku': 'رمز المنتج',
  'quantity_on_hand': 'المتوفر',
  'quantity_committed': 'المحجوز',
  'quantity_expected': 'المتوقع',
  'reorder_level': 'حد الطلب',
  'retail_value': 'قيمة البيع',
  'pay_in_total': 'إجمالي الإيداعات',
  'pay_out_total': 'إجمالي السحوبات',
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
  'returned_count': 'المعروض',
  'total_count': 'إجمالي الصفوف',
  'omitted_count': 'غير معروض',
  'truncated': 'مختصر',
};

const _arabicLabelTokens = {
  'id': 'المعرف',
  'number': 'الرقم',
  'name': 'الاسم',
  'date': 'التاريخ',
  'time': 'الوقت',
  'status': 'الحالة',
  'created': 'الإنشاء',
  'updated': 'التحديث',
  'closed': 'الإغلاق',
  'opened': 'الافتتاح',
  'submitted': 'الإرسال',
  'received': 'الاستلام',
  'due': 'الاستحقاق',
  'product': 'المنتج',
  'variant': 'الصنف',
  'supplier': 'المورد',
  'customer': 'العميل',
  'order': 'الطلب',
  'receipt': 'الإيصال',
  'session': 'الجلسة',
  'register': 'الدرج',
  'payment': 'الدفع',
  'method': 'الطريقة',
  'movement': 'الحركة',
  'type': 'النوع',
  'quantity': 'الكمية',
  'count': 'العدد',
  'total': 'الإجمالي',
  'subtotal': 'المجموع',
  'discount': 'الخصم',
  'refund': 'المرتجع',
  'balance': 'الرصيد',
  'cash': 'النقدية',
  'profit': 'الربح',
  'margin': 'الهامش',
  'percent': 'النسبة',
  'value': 'القيمة',
  'retail': 'البيع',
  'stock': 'المخزون',
  'inventory': 'المخزون',
  'sku': 'رمز المنتج',
  'note': 'الملاحظة',
  'by': 'بواسطة',
  'before': 'قبل',
  'after': 'بعد',
  'on': 'على',
  'hand': 'المتوفر',
  'expected': 'المتوقع',
  'committed': 'المحجوز',
  'reorder': 'إعادة الطلب',
  'level': 'الحد',
  'commission': 'العمولة',
  'gross': 'الإجمالي',
  'net': 'الصافي',
  'sales': 'المبيعات',
  'purchase': 'الشراء',
  'purchasing': 'المشتريات',
  'payable': 'المستحق',
  'credit': 'الدائن',
  'open': 'المفتوح',
};
