class DashboardSnapshot {
  const DashboardSnapshot({
    required this.period,
    required this.sections,
    this.generatedAt,
  });

  final DashboardPeriod period;
  final DashboardSections sections;
  final DateTime? generatedAt;

  bool get hasSections => sections.hasAny;

  factory DashboardSnapshot.fromJson(Map<String, Object?> json) {
    return DashboardSnapshot(
      generatedAt: _dateTimeFromJson(json['generated_at']),
      period: DashboardPeriod.fromJson(_mapFromJson(json['period'])),
      sections: DashboardSections.fromJson(_mapFromJson(json['sections'])),
    );
  }
}

class DashboardPeriod {
  const DashboardPeriod({
    required this.days,
    this.start,
    this.end,
    this.previousStart,
    this.previousEnd,
  });

  final int days;
  final DateTime? start;
  final DateTime? end;
  final DateTime? previousStart;
  final DateTime? previousEnd;

  factory DashboardPeriod.fromJson(Map<String, Object?> json) {
    return DashboardPeriod(
      days: _intFromJson(json['days']),
      start: _dateTimeFromJson(json['start']),
      end: _dateTimeFromJson(json['end']),
      previousStart: _dateTimeFromJson(json['previous_start']),
      previousEnd: _dateTimeFromJson(json['previous_end']),
    );
  }
}

class DashboardSections {
  const DashboardSections({
    this.sales,
    this.payments,
    this.inventory,
    this.purchasing,
    this.payroll,
    this.profitability,
    this.customers,
    this.discounts,
    this.printing,
  });

  final DashboardSalesSection? sales;
  final DashboardPaymentsSection? payments;
  final DashboardInventorySection? inventory;
  final DashboardPurchasingSection? purchasing;
  final DashboardPayrollSection? payroll;
  final DashboardProfitabilitySection? profitability;
  final DashboardCustomersSection? customers;
  final DashboardDiscountsSection? discounts;
  final DashboardPrintingSection? printing;

  bool get hasAny =>
      sales != null ||
      payments != null ||
      inventory != null ||
      purchasing != null ||
      payroll != null ||
      profitability != null ||
      customers != null ||
      discounts != null ||
      printing != null;

  factory DashboardSections.fromJson(Map<String, Object?> json) {
    return DashboardSections(
      sales: json['sales'] is Map<String, Object?>
          ? DashboardSalesSection.fromJson(
              json['sales'] as Map<String, Object?>,
            )
          : null,
      payments: json['payments'] is Map<String, Object?>
          ? DashboardPaymentsSection.fromJson(
              json['payments'] as Map<String, Object?>,
            )
          : null,
      inventory: json['inventory'] is Map<String, Object?>
          ? DashboardInventorySection.fromJson(
              json['inventory'] as Map<String, Object?>,
            )
          : null,
      purchasing: json['purchasing'] is Map<String, Object?>
          ? DashboardPurchasingSection.fromJson(
              json['purchasing'] as Map<String, Object?>,
            )
          : null,
      payroll: json['payroll'] is Map<String, Object?>
          ? DashboardPayrollSection.fromJson(
              json['payroll'] as Map<String, Object?>,
            )
          : null,
      profitability: json['profitability'] is Map<String, Object?>
          ? DashboardProfitabilitySection.fromJson(
              json['profitability'] as Map<String, Object?>,
            )
          : null,
      customers: json['customers'] is Map<String, Object?>
          ? DashboardCustomersSection.fromJson(
              json['customers'] as Map<String, Object?>,
            )
          : null,
      discounts: json['discounts'] is Map<String, Object?>
          ? DashboardDiscountsSection.fromJson(
              json['discounts'] as Map<String, Object?>,
            )
          : null,
      printing: json['printing'] is Map<String, Object?>
          ? DashboardPrintingSection.fromJson(
              json['printing'] as Map<String, Object?>,
            )
          : null,
    );
  }
}

class DashboardSalesSection {
  const DashboardSalesSection({
    required this.summary,
    required this.registers,
    this.trend = const [],
    this.hourlySales = const [],
    this.topProducts = const [],
    this.reports = const SalesReports(),
    this.topCategories = const [],
    this.recentOrders = const [],
  });

  final SalesDashboardSummary summary;
  final RegisterDashboardSummary registers;
  final List<SalesTrendPoint> trend;
  final List<HourlySalesPoint> hourlySales;
  final List<TopProductInsight> topProducts;
  final SalesReports reports;
  final List<TopCategoryInsight> topCategories;
  final List<RecentOrderInsight> recentOrders;

  factory DashboardSalesSection.fromJson(Map<String, Object?> json) {
    return DashboardSalesSection(
      summary: SalesDashboardSummary.fromJson(_mapFromJson(json['summary'])),
      registers: RegisterDashboardSummary.fromJson(
        _mapFromJson(json['registers']),
      ),
      trend: _listFromJson(json['trend'])
          .whereType<Map<String, Object?>>()
          .map(SalesTrendPoint.fromJson)
          .toList(growable: false),
      hourlySales: _listFromJson(json['hourly_sales'])
          .whereType<Map<String, Object?>>()
          .map(HourlySalesPoint.fromJson)
          .toList(growable: false),
      topProducts: _listFromJson(json['top_products'])
          .whereType<Map<String, Object?>>()
          .map(TopProductInsight.fromJson)
          .toList(growable: false),
      reports: SalesReports.fromJson(_mapFromJson(json['reports'])),
      topCategories: _listFromJson(json['top_categories'])
          .whereType<Map<String, Object?>>()
          .map(TopCategoryInsight.fromJson)
          .toList(growable: false),
      recentOrders: _listFromJson(json['recent_orders'])
          .whereType<Map<String, Object?>>()
          .map(RecentOrderInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class SalesDashboardSummary {
  const SalesDashboardSummary({
    required this.grossSales,
    required this.discountTotal,
    required this.refundTotal,
    required this.netSales,
    required this.grossProfit,
    required this.profitMarginPercent,
    required this.netSalesChangePercent,
    required this.orderCount,
    required this.orderCountChangePercent,
    required this.averageOrderValue,
    required this.itemsSold,
    required this.voidCount,
    required this.returnCount,
  });

  final double grossSales;
  final double discountTotal;
  final double refundTotal;
  final double netSales;
  final double grossProfit;
  final double profitMarginPercent;
  final double netSalesChangePercent;
  final int orderCount;
  final double orderCountChangePercent;
  final double averageOrderValue;
  final int itemsSold;
  final int voidCount;
  final int returnCount;

  factory SalesDashboardSummary.fromJson(Map<String, Object?> json) {
    return SalesDashboardSummary(
      grossSales: _moneyFromJson(json['gross_sales']),
      discountTotal: _moneyFromJson(json['discount_total']),
      refundTotal: _moneyFromJson(json['refund_total']),
      netSales: _moneyFromJson(json['net_sales']),
      grossProfit: _moneyFromJson(json['gross_profit']),
      profitMarginPercent: _moneyFromJson(json['profit_margin_percent']),
      netSalesChangePercent: _moneyFromJson(json['net_sales_change_percent']),
      orderCount: _intFromJson(json['order_count']),
      orderCountChangePercent: _moneyFromJson(
        json['order_count_change_percent'],
      ),
      averageOrderValue: _moneyFromJson(json['average_order_value']),
      itemsSold: _intFromJson(json['items_sold']),
      voidCount: _intFromJson(json['void_count']),
      returnCount: _intFromJson(json['return_count']),
    );
  }
}

class RegisterDashboardSummary {
  const RegisterDashboardSummary({
    required this.openCount,
    required this.closedCount,
    required this.varianceCount,
    required this.varianceTotal,
  });

  final int openCount;
  final int closedCount;
  final int varianceCount;
  final double varianceTotal;

  factory RegisterDashboardSummary.fromJson(Map<String, Object?> json) {
    return RegisterDashboardSummary(
      openCount: _intFromJson(json['open_count']),
      closedCount: _intFromJson(json['closed_count']),
      varianceCount: _intFromJson(json['variance_count']),
      varianceTotal: _moneyFromJson(json['variance_total']),
    );
  }
}

class SalesTrendPoint {
  const SalesTrendPoint({
    required this.netSales,
    required this.orderCount,
    this.date,
  });

  final DateTime? date;
  final double netSales;
  final int orderCount;

  factory SalesTrendPoint.fromJson(Map<String, Object?> json) {
    return SalesTrendPoint(
      date: _dateTimeFromJson(json['date']),
      netSales: _moneyFromJson(json['net_sales']),
      orderCount: _intFromJson(json['order_count']),
    );
  }
}

class HourlySalesPoint {
  const HourlySalesPoint({required this.hour, required this.netSales});

  final int hour;
  final double netSales;

  factory HourlySalesPoint.fromJson(Map<String, Object?> json) {
    return HourlySalesPoint(
      hour: _intFromJson(json['hour']),
      netSales: _moneyFromJson(json['net_sales']),
    );
  }
}

class SalesReports {
  const SalesReports({
    this.productTopSold = const [],
    this.productRevenue = const [],
    this.productProfit = const [],
    this.variantTopSold = const [],
    this.variantRevenue = const [],
    this.variantProfit = const [],
  });

  final List<TopProductInsight> productTopSold;
  final List<TopProductInsight> productRevenue;
  final List<TopProductInsight> productProfit;
  final List<TopVariantInsight> variantTopSold;
  final List<TopVariantInsight> variantRevenue;
  final List<TopVariantInsight> variantProfit;

  factory SalesReports.fromJson(Map<String, Object?> json) {
    final products = _mapFromJson(json['products']);
    final variants = _mapFromJson(json['variants']);
    return SalesReports(
      productTopSold: _productInsights(products['top_sold']),
      productRevenue: _productInsights(products['revenue']),
      productProfit: _productInsights(products['profit']),
      variantTopSold: _variantInsights(variants['top_sold']),
      variantRevenue: _variantInsights(variants['revenue']),
      variantProfit: _variantInsights(variants['profit']),
    );
  }

  static List<TopProductInsight> _productInsights(Object? value) {
    return _listFromJson(value)
        .whereType<Map<String, Object?>>()
        .map(TopProductInsight.fromJson)
        .toList(growable: false);
  }

  static List<TopVariantInsight> _variantInsights(Object? value) {
    return _listFromJson(value)
        .whereType<Map<String, Object?>>()
        .map(TopVariantInsight.fromJson)
        .toList(growable: false);
  }
}

class TopProductInsight {
  const TopProductInsight({
    required this.productId,
    required this.productName,
    required this.sku,
    required this.quantity,
    required this.revenue,
    required this.profit,
    this.variantCount = 0,
  });

  final int productId;
  final String productName;
  final String sku;
  final int quantity;
  final double revenue;
  final double profit;
  final int variantCount;

  factory TopProductInsight.fromJson(Map<String, Object?> json) {
    return TopProductInsight(
      productId: _intFromJson(json['product_id']),
      productName: json['product_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      revenue: _moneyFromJson(json['revenue']),
      profit: _moneyFromJson(json['profit']),
      variantCount: _intFromJson(json['variant_count']),
    );
  }
}

class TopVariantInsight {
  const TopVariantInsight({
    required this.productId,
    required this.variantId,
    required this.productName,
    required this.parentProductName,
    required this.variantName,
    required this.sku,
    required this.barcode,
    required this.quantity,
    required this.revenue,
    required this.profit,
  });

  final int productId;
  final int variantId;
  final String productName;
  final String parentProductName;
  final String variantName;
  final String sku;
  final String barcode;
  final int quantity;
  final double revenue;
  final double profit;

  factory TopVariantInsight.fromJson(Map<String, Object?> json) {
    return TopVariantInsight(
      productId: _intFromJson(json['product_id']),
      variantId: _intFromJson(json['variant_id']),
      productName: json['product_name']?.toString() ?? '',
      parentProductName: json['parent_product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      barcode: json['barcode']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      revenue: _moneyFromJson(json['revenue']),
      profit: _moneyFromJson(json['profit']),
    );
  }
}

class TopCategoryInsight {
  const TopCategoryInsight({
    required this.categoryName,
    required this.quantity,
    required this.revenue,
  });

  final String categoryName;
  final int quantity;
  final double revenue;

  factory TopCategoryInsight.fromJson(Map<String, Object?> json) {
    return TopCategoryInsight(
      categoryName: json['category_name']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      revenue: _moneyFromJson(json['revenue']),
    );
  }
}

class RecentOrderInsight {
  const RecentOrderInsight({
    required this.receiptNumber,
    required this.customerName,
    required this.status,
    required this.total,
    this.createdAt,
  });

  final String receiptNumber;
  final String customerName;
  final String status;
  final double total;
  final DateTime? createdAt;

  factory RecentOrderInsight.fromJson(Map<String, Object?> json) {
    return RecentOrderInsight(
      receiptNumber: json['receipt_number']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      total: _moneyFromJson(json['total']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class DashboardPaymentsSection {
  const DashboardPaymentsSection({
    required this.summary,
    this.methods = const [],
  });

  final PaymentsDashboardSummary summary;
  final List<PaymentMethodInsight> methods;

  factory DashboardPaymentsSection.fromJson(Map<String, Object?> json) {
    return DashboardPaymentsSection(
      summary: PaymentsDashboardSummary.fromJson(_mapFromJson(json['summary'])),
      methods: _listFromJson(json['methods'])
          .whereType<Map<String, Object?>>()
          .map(PaymentMethodInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class PaymentsDashboardSummary {
  const PaymentsDashboardSummary({
    required this.total,
    required this.commissionTotal,
    required this.paymentCount,
  });

  final double total;
  final double commissionTotal;
  final int paymentCount;

  factory PaymentsDashboardSummary.fromJson(Map<String, Object?> json) {
    return PaymentsDashboardSummary(
      total: _moneyFromJson(json['total']),
      commissionTotal: _moneyFromJson(json['commission_total']),
      paymentCount: _intFromJson(json['payment_count']),
    );
  }
}

class PaymentMethodInsight {
  const PaymentMethodInsight({
    required this.method,
    required this.total,
    required this.commission,
    required this.count,
  });

  final String method;
  final double total;
  final double commission;
  final int count;

  factory PaymentMethodInsight.fromJson(Map<String, Object?> json) {
    return PaymentMethodInsight(
      method: json['method']?.toString() ?? '',
      total: _moneyFromJson(json['total']),
      commission: _moneyFromJson(json['commission']),
      count: _intFromJson(json['count']),
    );
  }
}

class DashboardInventorySection {
  const DashboardInventorySection({
    required this.summary,
    this.lowStockItems = const [],
    this.lowStockVariants = const [],
    this.dustyItems = const [],
    this.movementMix = const [],
    this.recentMovements = const [],
  });

  final InventoryDashboardSummary summary;
  final List<StockItemInsight> lowStockItems;
  final List<StockItemInsight> lowStockVariants;
  final List<StockItemInsight> dustyItems;
  final List<StockMovementMixInsight> movementMix;
  final List<RecentStockMovementInsight> recentMovements;

  factory DashboardInventorySection.fromJson(Map<String, Object?> json) {
    final lowStockItems = _stockItemInsights(json['low_stock_items']);
    final lowStockVariants = _stockItemInsights(json['low_stock_variants']);
    return DashboardInventorySection(
      summary: InventoryDashboardSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
      lowStockItems: lowStockItems,
      lowStockVariants: lowStockVariants.isEmpty
          ? lowStockItems
          : lowStockVariants,
      dustyItems: _stockItemInsights(json['dusty_items']),
      movementMix: _listFromJson(json['movement_mix'])
          .whereType<Map<String, Object?>>()
          .map(StockMovementMixInsight.fromJson)
          .toList(growable: false),
      recentMovements: _listFromJson(json['recent_movements'])
          .whereType<Map<String, Object?>>()
          .map(RecentStockMovementInsight.fromJson)
          .toList(growable: false),
    );
  }

  static List<StockItemInsight> _stockItemInsights(Object? value) {
    return _listFromJson(value)
        .whereType<Map<String, Object?>>()
        .map(StockItemInsight.fromJson)
        .toList(growable: false);
  }
}

class InventoryDashboardSummary {
  const InventoryDashboardSummary({
    required this.productCount,
    required this.activeProductCount,
    required this.stockItemCount,
    required this.lowStockCount,
    required this.outOfStockCount,
    required this.committedUnits,
    required this.expectedUnits,
    required this.retailStockValue,
  });

  final int productCount;
  final int activeProductCount;
  final int stockItemCount;
  final int lowStockCount;
  final int outOfStockCount;
  final int committedUnits;
  final int expectedUnits;
  final double retailStockValue;

  factory InventoryDashboardSummary.fromJson(Map<String, Object?> json) {
    return InventoryDashboardSummary(
      productCount: _intFromJson(json['product_count']),
      activeProductCount: _intFromJson(json['active_product_count']),
      stockItemCount: _intFromJson(json['stock_item_count']),
      lowStockCount: _intFromJson(json['low_stock_count']),
      outOfStockCount: _intFromJson(json['out_of_stock_count']),
      committedUnits: _intFromJson(json['committed_units']),
      expectedUnits: _intFromJson(json['expected_units']),
      retailStockValue: _moneyFromJson(json['retail_stock_value']),
    );
  }
}

class StockItemInsight {
  const StockItemInsight({
    required this.productId,
    required this.variantId,
    required this.productName,
    required this.variantName,
    required this.sku,
    required this.quantityOnHand,
    required this.quantityExpected,
    required this.quantityCommitted,
    required this.reorderLevel,
  });

  final int productId;
  final int variantId;
  final String productName;
  final String variantName;
  final String sku;
  final int quantityOnHand;
  final int quantityExpected;
  final int quantityCommitted;
  final int reorderLevel;

  factory StockItemInsight.fromJson(Map<String, Object?> json) {
    return StockItemInsight(
      productId: _intFromJson(json['product_id']),
      variantId: _intFromJson(json['variant_id']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      quantityOnHand: _intFromJson(json['quantity_on_hand']),
      quantityExpected: _intFromJson(json['quantity_expected']),
      quantityCommitted: _intFromJson(json['quantity_committed']),
      reorderLevel: _intFromJson(json['reorder_level']),
    );
  }
}

class StockMovementMixInsight {
  const StockMovementMixInsight({
    required this.movementType,
    required this.quantity,
    required this.count,
  });

  final String movementType;
  final int quantity;
  final int count;

  factory StockMovementMixInsight.fromJson(Map<String, Object?> json) {
    return StockMovementMixInsight(
      movementType: json['movement_type']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      count: _intFromJson(json['count']),
    );
  }
}

class RecentStockMovementInsight {
  const RecentStockMovementInsight({
    required this.productName,
    required this.movementType,
    required this.quantity,
    this.createdAt,
  });

  final String productName;
  final String movementType;
  final int quantity;
  final DateTime? createdAt;

  factory RecentStockMovementInsight.fromJson(Map<String, Object?> json) {
    return RecentStockMovementInsight(
      productName: json['product_name']?.toString() ?? '',
      movementType: json['movement_type']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class DashboardPurchasingSection {
  const DashboardPurchasingSection({
    required this.summary,
    this.statusCounts = const [],
    this.overdueOrders = const [],
    this.topSupplierBalances = const [],
  });

  final PurchasingDashboardSummary summary;
  final List<StatusCountInsight> statusCounts;
  final List<OverduePurchaseInsight> overdueOrders;
  final List<SupplierBalanceInsight> topSupplierBalances;

  factory DashboardPurchasingSection.fromJson(Map<String, Object?> json) {
    return DashboardPurchasingSection(
      summary: PurchasingDashboardSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
      statusCounts: _listFromJson(json['status_counts'])
          .whereType<Map<String, Object?>>()
          .map(StatusCountInsight.fromJson)
          .toList(growable: false),
      overdueOrders: _listFromJson(json['overdue_orders'])
          .whereType<Map<String, Object?>>()
          .map(OverduePurchaseInsight.fromJson)
          .toList(growable: false),
      topSupplierBalances: _listFromJson(json['top_supplier_balances'])
          .whereType<Map<String, Object?>>()
          .map(SupplierBalanceInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class PurchasingDashboardSummary {
  const PurchasingDashboardSummary({
    required this.purchaseTotal,
    required this.openOrderCount,
    required this.receivedOrderCount,
    required this.dueTotal,
    required this.overdueOrderCount,
    required this.supplierCount,
  });

  final double purchaseTotal;
  final int openOrderCount;
  final int receivedOrderCount;
  final double dueTotal;
  final int overdueOrderCount;
  final int supplierCount;

  factory PurchasingDashboardSummary.fromJson(Map<String, Object?> json) {
    return PurchasingDashboardSummary(
      purchaseTotal: _moneyFromJson(json['purchase_total']),
      openOrderCount: _intFromJson(json['open_order_count']),
      receivedOrderCount: _intFromJson(json['received_order_count']),
      dueTotal: _moneyFromJson(json['due_total']),
      overdueOrderCount: _intFromJson(json['overdue_order_count']),
      supplierCount: _intFromJson(json['supplier_count']),
    );
  }
}

class DashboardPayrollSection {
  const DashboardPayrollSection({
    required this.summary,
    this.recentRuns = const [],
  });

  final PayrollDashboardSummary summary;
  final List<RecentPayrollRunInsight> recentRuns;

  factory DashboardPayrollSection.fromJson(Map<String, Object?> json) {
    return DashboardPayrollSection(
      summary: PayrollDashboardSummary.fromJson(_mapFromJson(json['summary'])),
      recentRuns: _listFromJson(json['recent_runs'])
          .whereType<Map<String, Object?>>()
          .map(RecentPayrollRunInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class PayrollDashboardSummary {
  const PayrollDashboardSummary({
    required this.salaryExpense,
    required this.paidTotal,
    required this.pendingTotal,
    required this.activeEmployeeCount,
    required this.payrollRunCount,
  });

  final double salaryExpense;
  final double paidTotal;
  final double pendingTotal;
  final int activeEmployeeCount;
  final int payrollRunCount;

  factory PayrollDashboardSummary.fromJson(Map<String, Object?> json) {
    return PayrollDashboardSummary(
      salaryExpense: _moneyFromJson(json['salary_expense']),
      paidTotal: _moneyFromJson(json['paid_total']),
      pendingTotal: _moneyFromJson(json['pending_total']),
      activeEmployeeCount: _intFromJson(json['active_employee_count']),
      payrollRunCount: _intFromJson(json['payroll_run_count']),
    );
  }
}

class RecentPayrollRunInsight {
  const RecentPayrollRunInsight({
    required this.id,
    required this.runNumber,
    required this.status,
    required this.netTotal,
    this.periodStart,
    this.periodEnd,
    this.paymentDate,
  });

  final int id;
  final String runNumber;
  final String status;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final DateTime? paymentDate;
  final double netTotal;

  factory RecentPayrollRunInsight.fromJson(Map<String, Object?> json) {
    return RecentPayrollRunInsight(
      id: _intFromJson(json['id']),
      runNumber: json['run_number']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      periodStart: _dateTimeFromJson(json['period_start']),
      periodEnd: _dateTimeFromJson(json['period_end']),
      paymentDate: _dateTimeFromJson(json['payment_date']),
      netTotal: _moneyFromJson(json['net_total']),
    );
  }
}

class DashboardProfitabilitySection {
  const DashboardProfitabilitySection({required this.summary});

  final ProfitabilityDashboardSummary summary;

  factory DashboardProfitabilitySection.fromJson(Map<String, Object?> json) {
    return DashboardProfitabilitySection(
      summary: ProfitabilityDashboardSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
    );
  }
}

class ProfitabilityDashboardSummary {
  const ProfitabilityDashboardSummary({
    required this.grossProfit,
    required this.payrollPaidTotal,
    required this.payrollAccruedTotal,
    required this.paymentCommissionTotal,
    required this.purchaseSpendTotal,
    required this.operatingExpenseTotal,
    required this.netOperatingProfit,
  });

  final double grossProfit;
  final double payrollPaidTotal;
  final double payrollAccruedTotal;
  final double paymentCommissionTotal;
  final double purchaseSpendTotal;
  final double operatingExpenseTotal;
  final double netOperatingProfit;

  factory ProfitabilityDashboardSummary.fromJson(Map<String, Object?> json) {
    return ProfitabilityDashboardSummary(
      grossProfit: _moneyFromJson(json['gross_profit']),
      payrollPaidTotal: _moneyFromJson(json['payroll_paid_total']),
      payrollAccruedTotal: _moneyFromJson(json['payroll_accrued_total']),
      paymentCommissionTotal: _moneyFromJson(json['payment_commission_total']),
      purchaseSpendTotal: _moneyFromJson(json['purchase_spend_total']),
      operatingExpenseTotal: _moneyFromJson(json['operating_expense_total']),
      netOperatingProfit: _moneyFromJson(json['net_operating_profit']),
    );
  }
}

class StatusCountInsight {
  const StatusCountInsight({required this.status, required this.count});

  final String status;
  final int count;

  factory StatusCountInsight.fromJson(Map<String, Object?> json) {
    return StatusCountInsight(
      status: json['status']?.toString() ?? '',
      count: _intFromJson(json['count']),
    );
  }
}

class OverduePurchaseInsight {
  const OverduePurchaseInsight({
    required this.orderNumber,
    required this.supplierName,
    required this.balanceDue,
    this.dueDate,
  });

  final String orderNumber;
  final String supplierName;
  final DateTime? dueDate;
  final double balanceDue;

  factory OverduePurchaseInsight.fromJson(Map<String, Object?> json) {
    return OverduePurchaseInsight(
      orderNumber: json['order_number']?.toString() ?? '',
      supplierName: json['supplier_name']?.toString() ?? '',
      dueDate: _dateTimeFromJson(json['due_date']),
      balanceDue: _moneyFromJson(json['balance_due']),
    );
  }
}

class SupplierBalanceInsight {
  const SupplierBalanceInsight({
    required this.supplierName,
    required this.netBalance,
  });

  final String supplierName;
  final double netBalance;

  factory SupplierBalanceInsight.fromJson(Map<String, Object?> json) {
    return SupplierBalanceInsight(
      supplierName: json['supplier_name']?.toString() ?? '',
      netBalance: _moneyFromJson(json['net_balance']),
    );
  }
}

class DashboardCustomersSection {
  const DashboardCustomersSection({
    required this.summary,
    this.topCustomers = const [],
    this.recentCustomers = const [],
  });

  final CustomersDashboardSummary summary;
  final List<TopCustomerInsight> topCustomers;
  final List<RecentCustomerInsight> recentCustomers;

  factory DashboardCustomersSection.fromJson(Map<String, Object?> json) {
    return DashboardCustomersSection(
      summary: CustomersDashboardSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
      topCustomers: _listFromJson(json['top_customers'])
          .whereType<Map<String, Object?>>()
          .map(TopCustomerInsight.fromJson)
          .toList(growable: false),
      recentCustomers: _listFromJson(json['recent_customers'])
          .whereType<Map<String, Object?>>()
          .map(RecentCustomerInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class CustomersDashboardSummary {
  const CustomersDashboardSummary({
    required this.activeCustomerCount,
    required this.newCustomerCount,
    required this.customersWithSalesCount,
    required this.repeatCustomerCount,
    required this.marketingConsentCount,
  });

  final int activeCustomerCount;
  final int newCustomerCount;
  final int customersWithSalesCount;
  final int repeatCustomerCount;
  final int marketingConsentCount;

  factory CustomersDashboardSummary.fromJson(Map<String, Object?> json) {
    return CustomersDashboardSummary(
      activeCustomerCount: _intFromJson(json['active_customer_count']),
      newCustomerCount: _intFromJson(json['new_customer_count']),
      customersWithSalesCount: _intFromJson(json['customers_with_sales_count']),
      repeatCustomerCount: _intFromJson(json['repeat_customer_count']),
      marketingConsentCount: _intFromJson(json['marketing_consent_count']),
    );
  }
}

class TopCustomerInsight {
  const TopCustomerInsight({
    required this.customerName,
    required this.salesTotal,
    required this.orderCount,
  });

  final String customerName;
  final double salesTotal;
  final int orderCount;

  factory TopCustomerInsight.fromJson(Map<String, Object?> json) {
    return TopCustomerInsight(
      customerName: json['customer_name']?.toString() ?? '',
      salesTotal: _moneyFromJson(json['sales_total']),
      orderCount: _intFromJson(json['order_count']),
    );
  }
}

class RecentCustomerInsight {
  const RecentCustomerInsight({
    required this.customerName,
    required this.customerNumber,
    this.createdAt,
  });

  final String customerName;
  final String customerNumber;
  final DateTime? createdAt;

  factory RecentCustomerInsight.fromJson(Map<String, Object?> json) {
    return RecentCustomerInsight(
      customerName: json['customer_name']?.toString() ?? '',
      customerNumber: json['customer_number']?.toString() ?? '',
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class DashboardDiscountsSection {
  const DashboardDiscountsSection({
    required this.summary,
    this.topRules = const [],
    this.expiringRules = const [],
  });

  final DiscountsDashboardSummary summary;
  final List<DiscountRuleInsight> topRules;
  final List<ExpiringDiscountRuleInsight> expiringRules;

  factory DashboardDiscountsSection.fromJson(Map<String, Object?> json) {
    return DashboardDiscountsSection(
      summary: DiscountsDashboardSummary.fromJson(
        _mapFromJson(json['summary']),
      ),
      topRules: _listFromJson(json['top_rules'])
          .whereType<Map<String, Object?>>()
          .map(DiscountRuleInsight.fromJson)
          .toList(growable: false),
      expiringRules: _listFromJson(json['expiring_rules'])
          .whereType<Map<String, Object?>>()
          .map(ExpiringDiscountRuleInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class DiscountsDashboardSummary {
  const DiscountsDashboardSummary({
    required this.activeRuleCount,
    required this.couponRuleCount,
    required this.redemptionCount,
    required this.salesDiscountTotal,
    required this.purchaseDiscountTotal,
  });

  final int activeRuleCount;
  final int couponRuleCount;
  final int redemptionCount;
  final double salesDiscountTotal;
  final double purchaseDiscountTotal;

  factory DiscountsDashboardSummary.fromJson(Map<String, Object?> json) {
    return DiscountsDashboardSummary(
      activeRuleCount: _intFromJson(json['active_rule_count']),
      couponRuleCount: _intFromJson(json['coupon_rule_count']),
      redemptionCount: _intFromJson(json['redemption_count']),
      salesDiscountTotal: _moneyFromJson(json['sales_discount_total']),
      purchaseDiscountTotal: _moneyFromJson(json['purchase_discount_total']),
    );
  }
}

class DiscountRuleInsight {
  const DiscountRuleInsight({
    required this.ruleName,
    required this.channel,
    required this.discountTotal,
    required this.redemptionCount,
  });

  final String ruleName;
  final String channel;
  final double discountTotal;
  final int redemptionCount;

  factory DiscountRuleInsight.fromJson(Map<String, Object?> json) {
    return DiscountRuleInsight(
      ruleName: json['rule_name']?.toString() ?? '',
      channel: json['channel']?.toString() ?? '',
      discountTotal: _moneyFromJson(json['discount_total']),
      redemptionCount: _intFromJson(json['redemption_count']),
    );
  }
}

class ExpiringDiscountRuleInsight {
  const ExpiringDiscountRuleInsight({
    required this.ruleName,
    required this.channel,
    this.endsAt,
  });

  final String ruleName;
  final String channel;
  final DateTime? endsAt;

  factory ExpiringDiscountRuleInsight.fromJson(Map<String, Object?> json) {
    return ExpiringDiscountRuleInsight(
      ruleName: json['rule_name']?.toString() ?? '',
      channel: json['channel']?.toString() ?? '',
      endsAt: _dateTimeFromJson(json['ends_at']),
    );
  }
}

class DashboardPrintingSection {
  const DashboardPrintingSection({
    required this.summary,
    this.statusCounts = const [],
    this.recentFailures = const [],
  });

  final PrintingDashboardSummary summary;
  final List<StatusCountInsight> statusCounts;
  final List<PrintFailureInsight> recentFailures;

  factory DashboardPrintingSection.fromJson(Map<String, Object?> json) {
    return DashboardPrintingSection(
      summary: PrintingDashboardSummary.fromJson(_mapFromJson(json['summary'])),
      statusCounts: _listFromJson(json['status_counts'])
          .whereType<Map<String, Object?>>()
          .map(StatusCountInsight.fromJson)
          .toList(growable: false),
      recentFailures: _listFromJson(json['recent_failures'])
          .whereType<Map<String, Object?>>()
          .map(PrintFailureInsight.fromJson)
          .toList(growable: false),
    );
  }
}

class PrintingDashboardSummary {
  const PrintingDashboardSummary({
    required this.queuedCount,
    required this.claimedCount,
    required this.failedCount,
    required this.printedCount,
    required this.activeAgentCount,
    required this.staleAgentCount,
  });

  final int queuedCount;
  final int claimedCount;
  final int failedCount;
  final int printedCount;
  final int activeAgentCount;
  final int staleAgentCount;

  factory PrintingDashboardSummary.fromJson(Map<String, Object?> json) {
    return PrintingDashboardSummary(
      queuedCount: _intFromJson(json['queued_count']),
      claimedCount: _intFromJson(json['claimed_count']),
      failedCount: _intFromJson(json['failed_count']),
      printedCount: _intFromJson(json['printed_count']),
      activeAgentCount: _intFromJson(json['active_agent_count']),
      staleAgentCount: _intFromJson(json['stale_agent_count']),
    );
  }
}

class PrintFailureInsight {
  const PrintFailureInsight({
    required this.id,
    required this.receiptNumber,
    required this.errorMessage,
    this.failedAt,
  });

  final int id;
  final String receiptNumber;
  final String errorMessage;
  final DateTime? failedAt;

  factory PrintFailureInsight.fromJson(Map<String, Object?> json) {
    return PrintFailureInsight(
      id: _intFromJson(json['id']),
      receiptNumber: json['receipt_number']?.toString() ?? '',
      errorMessage: json['error_message']?.toString() ?? '',
      failedAt: _dateTimeFromJson(json['failed_at']),
    );
  }
}

Map<String, Object?> _mapFromJson(Object? value) {
  return value is Map<String, Object?> ? value : const {};
}

List<Object?> _listFromJson(Object? value) {
  return value is List<Object?> ? value : const [];
}

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
