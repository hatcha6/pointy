/// Arabic for everything a report payload says, in one place.
///
/// The payload is deliberately dumb data — column keys, row maps, note codes —
/// so the meaning lives on the server and the wording lives here. Three readers
/// consume it (the printed PDF, the on-screen table, the CSV export), and they
/// used to share nothing: the labels lived inside the PDF builder, so the
/// screen could not show a figure without the PDF being built first.
///
/// Two things changed with the payload and are honoured here:
///
/// * **Columns declare their type.** ``retail_value`` used to be money because
///   its name ended in "value". A section now carries ``column_types``, and a
///   declared type always wins over the name heuristics below — which stay only
///   for the summary block, whose values are heterogeneous by nature.
///
/// * **Notes are codes, not sentences.** The server states *which* fact applies
///   ("this stock figure is a position at a past date"); the sentence is here,
///   in the language the shop reads.
library;

import '../../shared/formatters.dart';

/// How a column should be read, mirroring ``apps.reports.sections.ColumnType``.
class ReportColumnType {
  static const text = 'text';

  /// The cell holds a payload key, not prose — a metric name, a statement
  /// line. Translated like a column header, or the report prints
  /// `net_operating_profit` at a customer.
  static const label = 'label';
  static const money = 'money';
  static const quantity = 'quantity';
  static const count = 'count';
  static const percent = 'percent';
  static const date = 'date';
  static const dateTime = 'datetime';
  static const choice = 'choice';
}

/// The Arabic name of a payload key — a section, a column, or a metric.
String reportLabel(String key) {
  final label = _labels[key];
  if (label != null) {
    return label;
  }
  final fallback = key
      .split('_')
      .map((part) => _labelTokens[part])
      .whereType<String>()
      .join(' ');
  return fallback.isEmpty ? 'بيان' : fallback;
}

/// A cell, formatted for reading.
///
/// [columnType] is the section's declaration and wins outright. Without one —
/// the summary block, whose rows hold money next to counts next to dates — the
/// key name decides, which is why the money and percent key sets below still
/// exist.
String reportValue(String key, Object? value, {String? columnType}) {
  if (value == null || value == '') {
    return '-';
  }
  if (value is bool) {
    return value ? 'نعم' : '—';
  }
  switch (columnType) {
    case ReportColumnType.label:
      return _labelValue(value.toString());
    case ReportColumnType.money:
      return _money(value);
    case ReportColumnType.percent:
      return _percent(value);
    case ReportColumnType.count:
    case ReportColumnType.quantity:
      return _plain(value);
    case ReportColumnType.choice:
      return _choice(value) ?? _plain(value);
    case ReportColumnType.date:
    case ReportColumnType.dateTime:
      return _plain(value);
  }

  final raw = value.toString();
  // Columns that hold a payload key rather than prose. Declared by the server
  // since ``ColumnType.LABEL``; kept by name too so a payload from an older
  // backend does not print an English key at a customer.
  if (const {'metric', 'line', 'cost_item', 'component'}.contains(key)) {
    return _labelValue(raw);
  }
  final choice = _choice(raw);
  if (choice != null) {
    return choice;
  }
  if (_moneyKeys.contains(key)) {
    return _money(value);
  }
  if (_percentKeys.contains(key)) {
    return _percent(value);
  }
  return _plain(value);
}

/// A payload key held as a cell value — a statement line, a stock movement, an
/// age band.
///
/// A line's own name wins. After it, a value the payload also sends in choice
/// columns reads exactly as it does there: a treasury component or a movement
/// type used to reach only the header table, miss it, and print بيان.
String _labelValue(String key) {
  return _labels[key] ?? _valueLabels[key] ?? reportLabel(key);
}

/// Whether a column should be right-aligned and read as a figure.
bool reportColumnIsNumeric(String columnType) {
  return const {
    ReportColumnType.money,
    ReportColumnType.quantity,
    ReportColumnType.count,
    ReportColumnType.percent,
  }.contains(columnType);
}

/// The sentence behind a note code.
///
/// An unknown code returns `null` rather than a placeholder: a client running
/// against a newer backend should stay quiet about a statement it cannot word,
/// not print a code at the foot of a financial document.
String? reportNote(String code, {Map<String, Object?> args = const {}}) {
  final template = _notes[code];
  if (template == null) {
    return null;
  }
  var text = template;
  args.forEach((key, value) {
    text = text.replaceAll('{$key}', value?.toString() ?? '');
  });
  return text;
}

/// The movement between two periods, as a signed percentage.
String? reportChange(Object? changePercent) {
  if (changePercent == null) {
    return null;
  }
  final value = num.tryParse(changePercent.toString());
  if (value == null) {
    return null;
  }
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(1)}%';
}

String _money(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.contains(currencySymbol)) {
    return normalized;
  }
  final amount = num.tryParse(normalized);
  if (amount == null) {
    return _compact(normalized);
  }
  return '${amount.toStringAsFixed(2)} $currencySymbol';
}

String _percent(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.endsWith('%')) {
    return normalized;
  }
  final percent = num.tryParse(normalized);
  if (percent == null) {
    return _compact(normalized);
  }
  return '${percent.toStringAsFixed(2)}%';
}

String? _choice(Object? value) {
  if (value is! String) {
    return null;
  }
  return _valueLabels[value.trim().toLowerCase()];
}

String _plain(Object? value) {
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
  return _compact(value.toString());
}

String _two(int value) => value.toString().padLeft(2, '0');

String _compact(String value) {
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

/// Keys whose value is money when the section did not say so.
const _moneyKeys = {
  'gross_sales',
  'discount_total',
  'refund_total',
  'net_sales',
  'gross_profit',
  'cost_of_sales',
  'credit_sales_total',
  'revenue',
  'revenue_total',
  'profit',
  'profit_total',
  'loss_making_total',
  'cost',
  'total',
  'payment_total',
  'commission_total',
  'net_banked_total',
  'commission',
  'net_banked',
  'opening_cash',
  'closing_cash',
  'expected_cash',
  'cash_variance',
  'variance_total',
  'retail_stock_value',
  'cost_stock_value',
  'unrealised_margin',
  'retail_value',
  'cost_value',
  'unit_cost',
  'purchase_total',
  'supplier_paid_total',
  'balance_due',
  'payable_balance',
  'credit_balance',
  'net_balance',
  'amount',
  'cash_sales_total',
  'cash_refund_total',
  'salary_expense',
  'paid_total',
  'pending_total',
  'staff_owe_total',
  'owed_to_staff_total',
  'owed_by_employee',
  'owed_to_employee',
  'gross_total',
  'additions_total',
  'deductions_total',
  'net_total',
  'payroll_paid_total',
  'payroll_cost_total',
  'payment_commission_total',
  'ad_hoc_expense_total',
  'shrinkage_total',
  'purchase_spend_total',
  'operating_expense_total',
  'net_operating_profit',
  'receivable_total',
  'payable_total',
  'overdue_total',
  'not_yet_due',
  'd0_30',
  'd31_60',
  'd61_90',
  'd90_plus',
  'opening_balance',
  'closing_balance',
  'invoiced_total',
  'received_total',
  'returned_total',
  'refunded_total',
  'account_entries_total',
  'opening_total',
  'movement_total',
  'closing_total',
  'counted_variance_total',
  'counted_variance',
  'expense_total',
  'received_value',
  'issued_value',
  'void_total',
  'average_sale',
  'debit',
  'credit',
  'balance',
  'net_position',
  'total_assets',
  'total_liabilities',
  'zakat_due',
  'zakat_base',
  'opening_net_position',
  'net_position_change',
  'period_result',
  'capital',
  'capital_on_shelf',
  'stale_capital',
  'consignment_stock_value',
  'consignor_payable',
  'consignor_receivable',
  'shop_commission',
  'custody_declared_value',
};

const _percentKeys = {
  'profit_margin_percent',
  'gross_margin_percent',
  'net_margin_percent',
  'margin_percent',
  'overdue_percent',
  'share_percent',
  'commission_rate_percent',
  'discount_rate_percent',
  'change_percent',
};

const _valueLabels = {
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
  'salary_deduction': 'خصم من الراتب',
  'account_credit': 'من رصيد العميل',
  'bank': 'مصرف',
  'pay_in': 'إيداع نقدي',
  'pay_out': 'سحب نقدي',
  'increase': 'زيادة مخزون',
  'decrease': 'نقص مخزون',
  'damaged': 'مخزون تالف',
  'expected': 'مخزون متوقع',
  'receive_expected': 'استلام مخزون متوقع',
  'receive_damaged': 'استلام تالف',
  'cancel_expected': 'إلغاء مخزون متوقع',
  'standard': 'نقدية',
  'credit': 'آجل',
  'quotation': 'عرض سعر',
  'return': 'مرتجع',
  'invoice': 'فاتورة',
  'payment': 'دفعة',
  'refund': 'ردّ مبلغ',
  'purchase': 'شراء',
  'supplier_credit': 'رصيد مورد',
  // A balance written onto an account rather than invoiced (apps.balances).
  'opening_balance': 'رصيد افتتاحي',
  'balance_adjustment': 'تسوية رصيد',
  'balance_refund': 'رد مبلغ نقدًا',
  'in': 'وارد',
  'out': 'صادر',
  'opening': 'رصيد افتتاحي',
  'sales': 'مبيعات',
  'drawer_in': 'إيداع بالدرج',
  'drawer_out': 'سحب من الدرج',
  'staff_loans': 'سلف الموظفين',
  'expenses': 'مصاريف',
  'suppliers': 'موردون',
  'payroll': 'رواتب',
  'commission': 'عمولات',
  'transfer_in': 'تحويل وارد',
  'transfer_out': 'تحويل صادر',
  'opening_value': 'قيمة أول المدة',
  'received_value': 'الوارد',
  'issued_value': 'المنصرف',
  'closing_value': 'قيمة آخر المدة',
  'unexplained_difference': 'فرق غير مفسَّر',
  'consignor_payout': 'مدفوعات أصحاب الأمانات',
  'integration_draw': 'سحب مزوّد الخدمة',
  // What moved one article: the ledger's voucher types.
  'sale': 'بيع',
  'sale_return': 'مرتجع بيع',
  'purchase_receipt': 'استلام مشتريات',
  'purchase_return': 'مرتجع مشتريات',
  'production': 'تصنيع',
  'stock_count': 'جرد',
  'adjustment': 'تسوية يدوية',
  'transfer_receipt': 'استلام تحويل مستودع',
  'consignment_cost': 'تكلفة أمانة عند بيعها',
  'consignment_intake': 'استلام أمانة',
  'consignment_return': 'إرجاع أمانة لصاحبها',
  'refurbishment': 'إصلاح أُضيف إلى التكلفة',
  // How long an article has stood on the shelf. The bands include their lower
  // bound and stop short of the upper one.
  '0-30': 'أقل من ٣٠ يومًا',
  '30-60': '٣٠ – ٥٩ يومًا',
  '60-90': '٦٠ – ٨٩ يومًا',
  '90-180': '٩٠ – ١٧٩ يومًا',
  '180+': '١٨٠ يومًا فأكثر',
  // Where one article stands, worded as the serialized-stock screen words it.
  'in_stock': 'في المخزون',
  'reserved': 'محجوزة',
  'sold': 'مباعة',
  'in_transit': 'قيد النقل',
  'returned': 'أُرجعت للمورد',
  'written_off': 'مشطوبة',
};

const _labels = {
  // -- sections ----------------------------------------------------------
  'summary': 'الملخص',
  'top_products': 'أفضل المنتجات',
  'recent_orders': 'آخر الطلبات',
  'daily_sales': 'المبيعات اليومية',
  'daily_payments': 'المدفوعات اليومية',
  'payment_methods': 'طرق الدفع',
  'register_sessions': 'جلسات الدرج',
  'inventory_items': 'المخزون',
  'stock_reconciliation': 'مطابقة المخزون',
  'movement_mix': 'ملخص الحركات',
  'stock_movements': 'حركات المخزون',
  'purchase_orders': 'أوامر الشراء',
  'supplier_balances': 'أرصدة الموردين',
  'reorder_items': 'أصناف تحتاج إعادة طلب',
  'payroll_runs': 'مسيرات الرواتب',
  'employee_totals': 'إجماليات الموظفين',
  'employee_account_balances': 'أرصدة حسابات الموظفين',
  'profit_statement': 'قائمة الأرباح',
  'cash_bridge': 'مطابقة الإيراد بالمقبوضات',
  'expense_categories': 'المصاريف حسب البند',
  'expenses': 'المصاريف',
  'receivables_aging': 'أعمار الذمم المدينة',
  'payables_aging': 'أعمار الذمم الدائنة',
  'statement_entries': 'حركة الحساب',
  'account_balances': 'أرصدة الحسابات',
  'cash_movements': 'حركة النقدية',
  'product_margin': 'هوامش المنتجات',
  'margin_losses': 'منتجات تُباع بخسارة',
  'category_margin': 'هوامش الأقسام',
  'discount_rules': 'قواعد الخصم',
  'giveaway_by_staff': 'الخصومات حسب الموظف',
  'voids_and_refunds': 'الإلغاءات والمرتجعات',
  'sales_by_staff': 'المبيعات حسب الموظف',
  'sales_by_hour': 'المبيعات حسب الساعة',

  // -- generic columns ---------------------------------------------------
  'metric': 'المؤشر',
  'value': 'القيمة',
  'previous': 'الفترة السابقة',
  'change_percent': 'التغير',
  'line': 'البند',
  'date': 'التاريخ',
  'document': 'المستند',
  'kind': 'النوع',
  'debit': 'مدين',
  'credit': 'دائن',
  'balance': 'الرصيد',
  'amount': 'المبلغ',
  'count': 'العدد',
  'total': 'الإجمالي',
  'quantity': 'الكمية',
  'revenue': 'الإيراد',
  'profit': 'الربح',
  'cost': 'التكلفة',
  'status': 'الحالة',
  'note': 'ملاحظة',
  'created_at': 'تاريخ الإنشاء',
  'created_by': 'أنشأه',
  'occurred_at': 'وقت الحدث',
  'reason': 'السبب',

  // -- sales -------------------------------------------------------------
  'gross_sales': 'إجمالي المبيعات',
  'discount_total': 'الخصومات',
  'refund_total': 'المرتجعات',
  'net_sales': 'صافي المبيعات',
  'gross_profit': 'الربح الإجمالي',
  'cost_of_sales': 'تكلفة المبيعات',
  'profit_margin_percent': 'هامش الربح',
  'gross_margin_percent': 'هامش الربح الإجمالي',
  'net_margin_percent': 'هامش الربح الصافي',
  'margin_percent': 'الهامش',
  'credit_sales_total': 'مبيعات آجلة',
  'credit_order_count': 'فواتير آجلة',
  'paid_order_count': 'الطلبات المدفوعة',
  'voided_order_count': 'الطلبات الملغاة',
  'return_count': 'المرتجعات',
  'items_sold': 'القطع المباعة',
  'order_count': 'عدد الطلبات',
  'product_name': 'المنتج',
  'category_name': 'القسم',
  'receipt_number': 'رقم الإيصال',
  'sale_type': 'نوع البيع',
  'revenue_total': 'إجمالي الإيراد',
  'profit_total': 'إجمالي الربح',
  'product_count': 'عدد المنتجات',
  'loss_making_count': 'منتجات بخسارة',
  'loss_making_total': 'قيمة الخسارة',
  'staff_name': 'الموظف',
  'staff_count': 'عدد الموظفين',
  'average_sale': 'متوسط الفاتورة',
  'busiest_hour': 'أكثر الساعات ازدحامًا',
  'hour': 'الساعة',

  // -- discounts and reversals -------------------------------------------
  'rule_name': 'قاعدة الخصم',
  'times_used': 'مرات الاستخدام',
  'discount_rate_percent': 'نسبة الخصم من المبيعات',
  'discounted_order_count': 'طلبات عليها خصم',
  'void_total': 'قيمة الإلغاءات',
  'void_count': 'عدد الإلغاءات',
  'refund_count': 'عدد المرتجعات',

  // -- payments and cash -------------------------------------------------
  'payment_total': 'إجمالي المدفوعات',
  'commission_total': 'إجمالي العمولات',
  'net_banked_total': 'صافي المُورَّد',
  'net_banked': 'الصافي',
  'commission_rate_percent': 'نسبة العمولة',
  'payment_count': 'عدد المدفوعات',
  'method': 'الطريقة',
  'payment_method': 'طريقة الدفع',
  'commission': 'العمولة',
  'session_count': 'عدد الجلسات',
  'open_count': 'المفتوحة',
  'closed_count': 'المغلقة',
  'variance_total': 'إجمالي الفرق',
  'short_session_count': 'جلسات بعجز',
  'over_session_count': 'جلسات بزيادة',
  'session_number': 'رقم الجلسة',
  'opened_at': 'فتحت في',
  'closed_at': 'أغلقت في',
  'opening_cash': 'نقدية البداية',
  'closing_cash': 'نقدية الإغلاق',
  'expected_cash': 'النقدية المتوقعة',
  'cash_variance': 'فرق النقدية',
  'pay_in_total': 'إجمالي الإيداعات',
  'pay_out_total': 'إجمالي السحوبات',
  'account_name': 'الحساب',
  'opening_total': 'رصيد أول المدة',
  'movement_total': 'صافي الحركة',
  'closing_total': 'رصيد آخر المدة',
  'opening_balance': 'رصيد أول المدة',
  'closing_balance': 'رصيد آخر المدة',
  'counted_variance': 'فرق الجرد',
  'counted_variance_total': 'إجمالي فروق الجرد',
  'accounts_counted': 'حسابات تم جردها',
  'accounts_total': 'عدد الحسابات',
  'last_counted_at': 'آخر جرد',
  'component': 'المكوّن',
  'direction': 'الاتجاه',

  // -- inventory ---------------------------------------------------------
  'stock_item_count': 'بنود المخزون',
  'low_stock_count': 'مخزون منخفض',
  'out_of_stock_count': 'نافد',
  'retail_stock_value': 'قيمة البيع',
  'cost_stock_value': 'قيمة المخزون بالتكلفة',
  'unrealised_margin': 'هامش غير محقق',
  'sku': 'رمز المنتج',
  'quantity_on_hand': 'المتوفر',
  'quantity_committed': 'المحجوز',
  'quantity_expected': 'المتوقع',
  'reorder_level': 'حد الطلب',
  'retail_value': 'قيمة البيع',
  'cost_value': 'قيمة التكلفة',
  'unit_cost': 'تكلفة الوحدة',
  'movement_count': 'عدد الحركات',
  'quantity_moved': 'الكمية المتحركة',
  'movement_type': 'نوع الحركة',
  'on_hand_before': 'قبل',
  'on_hand_after': 'بعد',
  'shrinkage_total': 'الفاقد',
  'received_value': 'قيمة الوارد',
  'issued_value': 'قيمة المنصرف',
  'reorder_item_count': 'أصناف عند حد الطلب',
  'suggested_quantity': 'الكمية المقترحة',
  'suggested_units': 'إجمالي الكميات المقترحة',

  // -- purchasing and payables -------------------------------------------
  'purchase_total': 'إجمالي المشتريات',
  'supplier_paid_total': 'المدفوع للموردين',
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
  'payable_total': 'إجمالي الذمم الدائنة',
  'invoiced_total': 'إجمالي الفواتير',

  // -- receivables -------------------------------------------------------
  'customer_name': 'العميل',
  'receivable_total': 'إجمالي الذمم المدينة',
  'overdue_total': 'المتأخر',
  'overdue_percent': 'نسبة المتأخر',
  'customer_count': 'عدد العملاء',
  'invoice_count': 'عدد الفواتير',
  'oldest_days': 'أقدم عمر (يوم)',
  'entry_count': 'عدد الحركات',
  'received_total': 'المحصَّل',
  'returned_total': 'المرتجعات',
  'refunded_total': 'المبالغ المردودة',
  'account_entries_total': 'الأرصدة والتسويات',
  'not_yet_due': 'لم يحلّ أجلها',
  'd0_30': 'حتى ٣٠ يومًا',
  'd31_60': '٣١ – ٦٠ يومًا',
  'd61_90': '٦١ – ٩٠ يومًا',
  'd90_plus': 'أكثر من ٩٠ يومًا',

  // -- payroll -----------------------------------------------------------
  'employee_name': 'الموظف',
  'run_number': 'رقم المسير',
  'period_start': 'بداية الفترة',
  'period_end': 'نهاية الفترة',
  'payment_date': 'تاريخ الصرف',
  'gross_total': 'الإجمالي الأساسي',
  'additions_total': 'الإضافات',
  'deductions_total': 'الخصومات',
  'net_total': 'الصافي',
  'salary_expense': 'تكلفة الرواتب للفترة',
  'staff_owe_total': 'على الموظفين في حساباتهم',
  'owed_to_staff_total': 'مستحق للموظفين في حساباتهم',
  'owed_by_employee': 'على الموظف',
  'owed_to_employee': 'مستحق للموظف',
  'paid_total': 'الرواتب المصروفة',
  'pending_total': 'رواتب معتمدة غير مصروفة',
  'payroll_run_count': 'عدد المسيرات',
  'active_employee_count': 'موظفون نشطون',

  // -- profit and expenses -----------------------------------------------
  'payroll_cost_total': 'تكلفة الرواتب',
  'payroll_paid_total': 'رواتب مصروفة',
  'payment_commission_total': 'عمولات الدفع',
  'ad_hoc_expense_total': 'مصاريف عامة',
  'purchase_spend_total': 'إنفاق المشتريات (ليس مصروفًا)',
  'operating_expense_total': 'إجمالي المصاريف التشغيلية',
  'net_operating_profit': 'صافي الربح التشغيلي',
  'expense_total': 'إجمالي المصاريف',
  'category_count': 'عدد البنود',
  'expense_count': 'عدد المصاريف',
  'largest_category': 'أكبر بند',
  'share_percent': 'النسبة',
  'description': 'الوصف',
  'spent_at': 'تاريخ الصرف',
  'recorded_by': 'سجّله',
  'revenue_recognised': 'الإيراد المعترف به',
  'opening_receivables': 'ذمم أول المدة',
  'closing_receivables': 'ذمم آخر المدة',
  'movement_in_receivables': 'التغير في الذمم',
  'cash_received_from_customers': 'المقبوض من العملاء',
  'settled_from_wages': 'المُسدَّد من رواتب الموظفين',
  'settled_from_account_credit': 'المُسدَّد من أرصدة العملاء الدائنة',
  'debts_recorded_on_account': 'ديون سُجلت على حسابات العملاء دون فاتورة',
  'unreconciled_difference': 'فرق غير مطابق',
  'opening_value': 'قيمة أول المدة',
  'closing_value': 'قيمة آخر المدة',

  // -- balance sheet and zakat --------------------------------------------
  // Worded after the statement shops kept before Pointy — لنا, علينا,
  // الصافي — because that is the page an owner already knows how to check.
  'balance_assets': 'لنا — الأصول',
  'balance_liabilities': 'علينا — الخصوم',
  'balance_net': 'الصافي',
  'net_position_movement': 'حركة الصافي خلال الفترة',
  'zakat': 'حساب الزكاة',
  'change': 'التغير',
  'stock_at_cost': 'البضاعة بسعر التكلفة',
  'stock_at_selling_price': 'البضاعة بسعر البيع',
  'cash_and_bank': 'النقدية في الخزينة والمصارف',
  'customer_receivables': 'ديون العملاء',
  'employee_loans': 'ديون الموظفين (السلف)',
  'employee_account_receivables': 'أرصدة على الموظفين',
  'provider_float': 'أرصدة لدى مزودي الخدمات',
  'supplier_credits': 'إشعارات دائنة لدى الموردين',
  'consignor_advances': 'مستحق على أصحاب الأمانات',
  'supplier_payables': 'مستحقات الموردين',
  'employee_payables': 'رواتب مستحقة للموظفين',
  'employee_account_payables': 'أرصدة مستحقة للموظفين',
  'consignor_payables': 'مستحقات أصحاب الأمانات',
  'customer_credits': 'أرصدة دائنة للعملاء (مستحقة لهم)',
  'total_assets': 'إجمالي الأصول (لنا)',
  'total_liabilities': 'إجمالي الخصوم (علينا)',
  'net_position': 'الصافي',
  'opening_net_position': 'الصافي أول المدة',
  'closing_net_position': 'الصافي آخر المدة',
  'net_position_change': 'التغير في الصافي',
  'outside_money_added': 'أموال أُدخلت من الخارج (رأس مال أو قرض)',
  'outside_money_withdrawn': 'مسحوبات المالك',
  'opening_balances_recorded': 'أرصدة افتتاحية سُجلت خلال الفترة',
  'period_result': 'نتيجة الفترة (ربح أو خسارة)',
  'zakat_assets_total': 'إجمالي الأموال الزكوية',
  'zakat_liabilities': 'يُخصم: الخصوم (علينا)',
  'zakat_base': 'وعاء الزكاة',
  'zakat_due': 'مقدار الزكاة (٢٫٥٪)',

  // -- identified stock and consignments ----------------------------------
  // The serialized-stock screens already call an article a جهاز and its code
  // its معرّف; the reports use the same words so a figure can be found again.
  'aging_buckets': 'الأجهزة حسب مدة بقائها',
  'aging_units': 'الأجهزة على الرف',
  'unit_margin': 'ربح كل جهاز',
  'unit_ledger': 'سجل الجهاز',
  'consignment_payables': 'مستحقات لم تُصرف لأصحابها',
  'consignment_sales': 'أمانات بيعت خلال الفترة',
  'bucket': 'المدة على الرف',
  'unit_count': 'عدد الأجهزة',
  'capital': 'رأس المال المجمَّد',
  'consigned_count': 'منها أمانات',
  'code': 'المعرّف',
  'days_held': 'أيام في المخزون',
  'asking_price': 'سعر العرض',
  'is_consignment': 'أمانة',
  'sold_at': 'تاريخ البيع',
  'sold_price': 'سعر البيع',
  'refurb_cost': 'تكلفة الإصلاح',
  'posting_at': 'التاريخ',
  'voucher_type': 'الحركة',
  'warehouse': 'المستودع',
  'batch': 'الدفعة',
  'rate': 'التكلفة',
  'consignor': 'صاحب الأمانة',
  'payout_due': 'المستحق لصاحبها',
  'days_waiting': 'أيام الانتظار',
  'payout': 'حصة صاحبها',
  'paid': 'صُرفت',
  'capital_on_shelf': 'رأس المال على الرفوف',
  'stale_unit_count': 'أجهزة راكدة (٩٠ يومًا فأكثر)',
  'stale_capital': 'رأس مال راكد (٩٠ يومًا فأكثر)',
  'units_sold': 'الأجهزة المباعة',
  'loss_making_units': 'أجهزة بيعت بخسارة',
  'spell_count': 'مرات دخوله المخزون',
  'event_count': 'عدد الحركات',
  'consignment_stock_value': 'قيمة الأمانات في مخزون المحل',
  'consignor_payable': 'مستحقات لأصحاب الأمانات',
  'consignor_receivable': 'مستحقات على أصحاب الأمانات',
  'shop_commission': 'عمولة المحل',
  'custody_unit_count': 'أمانات في العهدة',
  'custody_declared_value': 'القيمة المقدّرة للأمانات',

  // -- pack ---------------------------------------------------------------
  'sections_included': 'أقسام مُدرجة',
  'sections_omitted': 'أقسام غير مُدرجة',

  // -- audit --------------------------------------------------------------
  'returned_count': 'المعروض',
  'total_count': 'إجمالي الصفوف',
  'omitted_count': 'غير معروض',
  'truncated': 'مختصر',
};

const _labelTokens = {
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
  'expense': 'المصروف',
  'category': 'البند',
  'staff': 'الموظف',
  'account': 'الحساب',
  'opening': 'أول المدة',
  'closing': 'آخر المدة',
  'overdue': 'المتأخر',
  'aging': 'الأعمار',
  'statement': 'الكشف',
};

/// What each report note actually says.
///
/// These are the sentences the audit found missing: nothing on a printed report
/// said what "gross sales" included, which basis the profit was on, or that a
/// stock figure was a live position rather than the period's close.
const _notes = {
  // -- basis and definitions ---------------------------------------------
  'basis_accrual':
      'أساس الاستحقاق: يُحتسب الإيراد عند البيع والمصروف عند نشوئه، '
      'سواء تم التحصيل أو الدفع أم لا.',
  'basis_accrual_sales':
      'المبيعات محسوبة عند إصدار الفاتورة، وتشمل الفواتير الآجلة التي لم '
      'تُحصَّل بعد.',
  'gross_includes_void':
      'إجمالي المبيعات يشمل الفواتير الملغاة، ويُخصم أثرها في سطر المرتجعات '
      'حتى يتطابق الإجمالي مع صافي المبيعات.',
  'returns_reverse_margin':
      'المرتجع يعكس هامش الربح فقط؛ البضاعة تعود إلى المخزون بتكلفتها.',
  'payments_are_cash_received':
      'هذا التقرير يعرض المبالغ المقبوضة فعلًا، لا الإيراد المُعترف به. '
      'الفرق بينهما هو الفواتير الآجلة.',
  'refunds_net_in_payments': 'المبالغ المُعادة مطروحة من المدفوعات.',
  'payroll_is_period_cost':
      'تكلفة الرواتب هي تكلفة عمل الفترة (معتمدة أو مصروفة)، وليست ما صُرف '
      'نقدًا خلالها. تشمل الراتب كاملًا وإن خُصم منه قسط سلفة أو دين على '
      'الموظف، ولا تشمل ما صُرف معه تسويةً لرصيد سابق. تسويات أرصدة الموظفين '
      'تُحتسب يوم تسجيلها.',
  'payroll_cost_vs_paid':
      '«تكلفة الرواتب للفترة» تخص العمل المؤدَّى فيها؛ «الرواتب المصروفة» هي '
      'ما خرج من الصندوق خلالها. الرقمان مختلفان عمدًا.',
  'payroll_period_overlap': 'يُحتسب أي مسير تتقاطع فترته مع فترة التقرير.',
  'payroll_account_balances':
      'أرصدة حسابات الموظفين كما في نهاية الفترة: ما عليهم يُخصم من رواتبهم '
      'وما لهم يُصرف معها في مسير الرواتب القادم.',
  'purchases_are_not_expense':
      'شراء البضاعة ليس مصروفًا — فهو يحوّل النقد إلى مخزون. يظهر أسفل '
      'الإجمالي للعلم فقط ولا يدخل في المصاريف التشغيلية.',
  'shrinkage_is_non_cash_stock_loss':
      'الفاقد هو قيمة البضاعة التي خرجت دون بيع (جرد أو تسوية)، ويُحتسب '
      'مصروفًا غير نقدي.',
  'shrinkage_is_count_and_adjustment':
      'الفاقد يُحتسب من حركات الجرد والتسويات اليدوية.',
  'movement_quantity_base_units': 'الكميات بوحدة القياس الأساسية.',
  'margin_net_of_returns': 'الهوامش محسوبة بعد خصم المرتجعات.',
  'margin_cost_from_ledger':
      'التكلفة مأخوذة من سجل تقييم المخزون، لا من آخر سعر شراء.',
  'void_is_reversal': 'الإلغاء يعكس الفاتورة بالكامل في تاريخ الإلغاء.',
  'discount_at_line_and_document':
      'تشمل الخصومات ما طُبِّق على السطر وعلى الفاتورة معًا.',
  'staff_is_register_owner':
      'يُنسب البيع إلى صاحب جلسة الدرج التي حُرِّر عليها.',
  'hours_on_report_clock': 'الساعات بتوقيت التقارير المعتمد في النظام.',

  // -- stock ---------------------------------------------------------------
  'stock_as_of': 'قيمة المخزون بتاريخ {date}.',
  'stock_valued_at_cost':
      'المخزون مُقوَّم بالتكلفة الفعلية من سجل التقييم، لا بسعر البيع.',
  'stock_historical':
      'هذه صورة للمخزون في نهاية الفترة، مُستخرجة من سجل الحركات. لا تُعرض '
      'قيمة البيع لأنها ستُحتسب بأسعار اليوم لا بأسعار ذلك التاريخ.',
  'stock_live': 'هذه صورة المخزون الحالية وقت إنشاء التقرير.',

  // -- receivables and payables --------------------------------------------
  'receivable_is_open_credit':
      'الذمم المدينة هي الفواتير الآجلة القائمة ناقصًا ما سُدِّد منها وما أُرجع.',
  'aged_from_due_or_invoice_date':
      'حُسبت الأعمار من تاريخ الاستحقاق إن وُجد، وإلا فمن تاريخ الفاتورة.',
  'not_yet_due_excluded_from_ages':
      'الفواتير التي لم يحلّ أجلها بعد تظهر في عمود مستقل ولا تدخل في الأعمار.',
  'receivables_as_of': 'الأرصدة كما هي بتاريخ {date}.',
  'payable_is_billable_less_paid':
      'المستحق للمورد = قيمة الأمر بعد استبعاد ما أُلغي، ناقصًا كل ما دُفع.',
  'aged_from_due_or_order_date':
      'حُسبت الأعمار من تاريخ الاستحقاق إن وُجد، وإلا فمن تاريخ الأمر.',
  'payables_as_of': 'الأرصدة كما هي بتاريخ {date}.',
  'statement_running_balance':
      'الرصيد تراكمي: رصيد أول المدة + الحركات = رصيد آخر المدة.',
  'statement_credit_only':
      'يشمل الكشف الفواتير الآجلة ودفعاتها ومرتجعاتها فقط.',
  'statement_credit_and_account_entries':
      'يشمل الكشف الفواتير الآجلة ودفعاتها ومرتجعاتها والأرصدة الافتتاحية والتسويات المسجلة على الحساب.',
  'supplier_credit_is_owed': 'الرصيد الدائن يعني مبلغًا مستحقًا للمورد.',
  'purchase_is_stock_not_expense':
      'المشتريات تُضاف إلى المخزون ولا تُعد مصروفًا.',
  'balance_nets_credit': 'الصافي = المستحق ناقصًا أرصدة المورد الدائنة.',

  // -- cash ----------------------------------------------------------------
  'balances_are_derived':
      'الأرصدة مُستنتجة من حركات المال المسجّلة، وليست قيودًا مُدخلة يدويًا.',
  'payroll_assumed_cash':
      'الرواتب تُنسب إلى الصندوق النقدي لعدم وجود طريقة دفع مسجّلة لها؛ '
      'صحِّح ذلك بتحويل بين حساباتك إن كان الصرف بغير النقد.',
  'commission_assumed_bank': 'عمولات الدفع تُنسب إلى الحساب المصرفي.',
  'variance_closed_sessions_only': 'الفروق تُحتسب من الجلسات المغلقة فقط.',
  'open_session_no_variance': 'الجلسة المفتوحة لا فرق لها بعد.',

  // -- expenses -------------------------------------------------------------
  'expense_dated_when_spent': 'يُدرج المصروف بتاريخ صرفه.',
  'expense_excludes_stock': 'لا تشمل المصاريف شراء البضاعة.',

  // -- reorder --------------------------------------------------------------
  'reorder_target_is_twice_level':
      'الكمية المقترحة تُعيد المخزون إلى ضعف حد الطلب.',
  'reorder_counts_incoming':
      'تُخصم الكميات الواردة في الطريق حتى لا يتكرر الطلب.',

  // -- balance sheet and zakat ----------------------------------------------
  'balance_positions':
      'أول المدة هو الوضع في نهاية يوم {opening}، وآخر المدة هو الوضع في '
      'نهاية يوم {closing}.',
  'balance_stock_at_cost':
      'في الميزانية تُقوَّم البضاعة بتكلفتها من سجل التقييم، ولا تُحتسب '
      'البضاعة المودعة أمانةً لدى المحل.',
  'balance_net_is_equity':
      'لا يُسجَّل رأس المال على حدة، فالصافي هو حق المالك كاملًا: رأس المال '
      'مع ما تراكم من أرباح.',
  'period_result_basis':
      'نتيجة الفترة = الصافي آخر المدة − الصافي أول المدة − ما أُدخل من '
      'الخارج + مسحوبات المالك، وتشمل أي أرصدة افتتاحية سُجّلت خلال الفترة.',
  'zakat_basis':
      'في حساب الزكاة تُقوَّم البضاعة بسعر البيع الحالي، وتُضاف النقدية '
      'والديون المستحقة للمحل ويُخصم ما عليه، والزكاة ٢٫٥٪ من الوعاء إن كان '
      'موجبًا.',
  'zakat_prices_today':
      'كميات البضاعة كما كانت في {date}، لكنها مُقوَّمة بأسعار البيع الحالية '
      'لأن النظام لا يحفظ أسعار ذلك اليوم.',
  'zakat_conditions':
      'هذا حساب مساعد: تجب الزكاة إذا بلغ الوعاء النصاب وحال عليه الحول، '
      'ويُستبعد من الديون ما يُشك في تحصيله.',

  // -- identified stock and consignments -------------------------------------
  'aging_counts_consignment':
      'يشمل العدد الأمانات الموجودة على الرف، لأنها تشغل المكان نفسه وتتقادم '
      'مثل غيرها.',
  'aging_capital_excludes_consignment':
      'رأس المال لا يشمل الأمانات، فهي ليست من مال المحل.',
  'unit_margin_cost_includes_refurb':
      'تكلفة الجهاز تشمل ما أُنفق على إصلاحه، وتكلفة الأمانة هي ما استُحق '
      'لصاحبها عند بيعها.',
  'unit_ledger_is_one_article':
      'يعرض السجل كل ما مرّ به هذا المعرّف منذ دخوله المخزون، ولو دخله أكثر '
      'من مرة، بغض النظر عن الفترة المختارة.',
  'consignment_stock_value_is_zero':
      'الأمانات ليست من مخزون المحل، فقيمتها فيه صفر مهما كانت قيمتها '
      'لأصحابها.',
  'consignment_payable_counts_credit_sales':
      'يُستحق لصاحب الأمانة نصيبه عند البيع، ولو كان البيع آجلًا لم يُحصَّل '
      'بعد.',

  // -- the period itself ----------------------------------------------------
  'period_open':
      'الفترة ما زالت مفتوحة: قد تتغير هذه الأرقام إن سُجّلت حركات لاحقة '
      'بتاريخ يقع داخلها.',
  'period_closed':
      'الدفاتر مقفلة حتى {date}؛ أرقام هذه الفترة لا يمكن أن تتغير.',
  'compared_with': 'المقارنة مع الفترة من {start} إلى {end}.',
  'pack_is_assembled':
      'هذه الحزمة مُجمَّعة من التقارير نفسها، فأرقامها مطابقة لها بالضرورة.',
  'pack_omitted': 'لم تُدرج الأقسام التالية لعدم توفر صلاحية عليها: {reports}.',
};
