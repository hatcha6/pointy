enum ReportRunType {
  salesSummary,
  paymentMethods,
  registerClosure,
  inventoryStatus,
  stockMovements,
  purchasingSummary,
  reorderItems,
  payrollSummary,
  profitCosts,
  receivablesAging,
  payablesAging,
  customerStatement,
  supplierStatement,
  cashPosition,
  expenseBreakdown,
  productMargin,
  discountAudit,
  salesByStaff,
  monthEndPack,
}

enum ReportOutputFormat { json, pdf, csv }

enum ReportRunStatus { pending, success, failed }

class ReportRun {
  const ReportRun({
    required this.id,
    required this.reportType,
    required this.params,
    required this.outputFormat,
    required this.status,
    required this.payload,
    required this.rowCount,
    required this.checksum,
    required this.createdAt,
    this.figuresChecksum = '',
    this.requestedBy,
    this.requestedByUsername,
    this.completedAt,
    this.errorMessage = '',
  });

  final int id;
  final ReportRunType reportType;
  final Map<String, Object?> params;
  final ReportOutputFormat outputFormat;
  final ReportRunStatus status;
  final Map<String, Object?> payload;
  final int rowCount;
  final String checksum;

  /// Hash of the figures alone, with the generation timestamp excluded — the
  /// one that can be compared between two runs of the same closed period.
  final String figuresChecksum;
  final int? requestedBy;
  final String? requestedByUsername;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String errorMessage;

  factory ReportRun.fromJson(Map<String, Object?> json) {
    return ReportRun(
      id: json['id'] as int,
      reportType: reportRunTypeFromJson(json['report_type'] as String?),
      params: _mapFromJson(json['params']),
      outputFormat: reportOutputFormatFromJson(
        json['output_format'] as String?,
      ),
      status: reportRunStatusFromJson(json['status'] as String?),
      payload: _mapFromJson(json['payload']),
      rowCount: json['row_count'] as int? ?? 0,
      checksum: json['checksum'] as String? ?? '',
      figuresChecksum: json['figures_checksum'] as String? ?? '',
      requestedBy: json['requested_by'] as int?,
      requestedByUsername: json['requested_by_username'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      completedAt: _dateTimeOrNull(json['completed_at']),
      errorMessage: json['error_message'] as String? ?? '',
    );
  }
}

class ReportRunDraft {
  const ReportRunDraft({
    required this.reportType,
    required this.params,
    this.outputFormat = ReportOutputFormat.pdf,
  });

  final ReportRunType reportType;
  final Map<String, Object?> params;
  final ReportOutputFormat outputFormat;

  Map<String, Object?> toJson() {
    return {
      'report_type': reportRunTypeToJson(reportType),
      'output_format': reportOutputFormatToJson(outputFormat),
      'params': params,
    };
  }
}

String reportRunTypeToJson(ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => 'sales_summary',
    ReportRunType.paymentMethods => 'payment_methods',
    ReportRunType.registerClosure => 'register_closure',
    ReportRunType.inventoryStatus => 'inventory_status',
    ReportRunType.stockMovements => 'stock_movements',
    ReportRunType.purchasingSummary => 'purchasing_summary',
    ReportRunType.reorderItems => 'reorder_items',
    ReportRunType.payrollSummary => 'payroll_summary',
    ReportRunType.profitCosts => 'profit_costs',
    ReportRunType.receivablesAging => 'receivables_aging',
    ReportRunType.payablesAging => 'payables_aging',
    ReportRunType.customerStatement => 'customer_statement',
    ReportRunType.supplierStatement => 'supplier_statement',
    ReportRunType.cashPosition => 'cash_position',
    ReportRunType.expenseBreakdown => 'expense_breakdown',
    ReportRunType.productMargin => 'product_margin',
    ReportRunType.discountAudit => 'discount_audit',
    ReportRunType.salesByStaff => 'sales_by_staff',
    ReportRunType.monthEndPack => 'month_end_pack',
  };
}

ReportRunType reportRunTypeFromJson(String? value) {
  return switch (value) {
    'sales_summary' => ReportRunType.salesSummary,
    'payment_methods' => ReportRunType.paymentMethods,
    'register_closure' => ReportRunType.registerClosure,
    'inventory_status' => ReportRunType.inventoryStatus,
    'stock_movements' => ReportRunType.stockMovements,
    'purchasing_summary' => ReportRunType.purchasingSummary,
    'reorder_items' => ReportRunType.reorderItems,
    'payroll_summary' => ReportRunType.payrollSummary,
    'profit_costs' => ReportRunType.profitCosts,
    'receivables_aging' => ReportRunType.receivablesAging,
    'payables_aging' => ReportRunType.payablesAging,
    'customer_statement' => ReportRunType.customerStatement,
    'supplier_statement' => ReportRunType.supplierStatement,
    'cash_position' => ReportRunType.cashPosition,
    'expense_breakdown' => ReportRunType.expenseBreakdown,
    'product_margin' => ReportRunType.productMargin,
    'discount_audit' => ReportRunType.discountAudit,
    'sales_by_staff' => ReportRunType.salesByStaff,
    'month_end_pack' => ReportRunType.monthEndPack,
    _ => ReportRunType.salesSummary,
  };
}

String reportOutputFormatToJson(ReportOutputFormat format) {
  return switch (format) {
    ReportOutputFormat.json => 'json',
    ReportOutputFormat.pdf => 'pdf',
    ReportOutputFormat.csv => 'csv',
  };
}

ReportOutputFormat reportOutputFormatFromJson(String? value) {
  return switch (value) {
    'json' => ReportOutputFormat.json,
    'csv' => ReportOutputFormat.csv,
    _ => ReportOutputFormat.pdf,
  };
}

ReportRunStatus reportRunStatusFromJson(String? value) {
  return switch (value) {
    'pending' => ReportRunStatus.pending,
    'failed' => ReportRunStatus.failed,
    _ => ReportRunStatus.success,
  };
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

DateTime? _dateTimeOrNull(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.parse(value);
}
