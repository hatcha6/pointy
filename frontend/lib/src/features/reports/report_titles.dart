/// One name and one description per report, shared by every surface.
///
/// The reports screen, the PDF and the run history each used to map a report
/// type to a title of its own; the screen's list and the document's list drifted
/// the moment a report was added to one and not the other.
library;

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/report_run.dart';

String reportTitle(AppLocalizations l10n, ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => l10n.reportSalesSummaryTitle,
    ReportRunType.paymentMethods => l10n.reportPaymentsTitle,
    ReportRunType.registerClosure => l10n.reportRegisterSessionsTitle,
    ReportRunType.inventoryStatus => l10n.reportInventoryValueTitle,
    ReportRunType.stockMovements => l10n.reportStockMovementTitle,
    ReportRunType.purchasingSummary => l10n.reportPurchasesTitle,
    ReportRunType.reorderItems => l10n.reportReorderItemsTitle,
    ReportRunType.payrollSummary => l10n.reportPayrollSummaryTitle,
    ReportRunType.profitCosts => l10n.reportProfitCostsTitle,
    ReportRunType.receivablesAging => l10n.reportReceivablesAgingTitle,
    ReportRunType.payablesAging => l10n.reportPayablesAgingTitle,
    ReportRunType.customerStatement => l10n.reportCustomerStatementTitle,
    ReportRunType.supplierStatement => l10n.reportSupplierStatementTitle,
    ReportRunType.cashPosition => l10n.reportCashPositionTitle,
    ReportRunType.expenseBreakdown => l10n.reportExpenseBreakdownTitle,
    ReportRunType.productMargin => l10n.reportProductMarginTitle,
    ReportRunType.discountAudit => l10n.reportDiscountAuditTitle,
    ReportRunType.salesByStaff => l10n.reportSalesByStaffTitle,
    ReportRunType.monthEndPack => l10n.reportMonthEndPackTitle,
    ReportRunType.balanceSheet => l10n.reportBalanceSheetTitle,
    ReportRunType.unitAging => l10n.reportUnitAgingTitle,
    ReportRunType.unitMargin => l10n.reportUnitMarginTitle,
    ReportRunType.unitLedger => l10n.reportUnitLedgerTitle,
    ReportRunType.consignmentLedger => l10n.reportConsignmentLedgerTitle,
  };
}

String reportSubtitle(AppLocalizations l10n, ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => l10n.reportSalesSummarySubtitle,
    ReportRunType.paymentMethods => l10n.reportPaymentsSubtitle,
    ReportRunType.registerClosure => l10n.reportRegisterSessionsSubtitle,
    ReportRunType.inventoryStatus => l10n.reportInventoryValueSubtitle,
    ReportRunType.stockMovements => l10n.reportStockMovementSubtitle,
    ReportRunType.purchasingSummary => l10n.reportPurchasesSubtitle,
    ReportRunType.reorderItems => l10n.reportReorderItemsSubtitle,
    ReportRunType.payrollSummary => l10n.reportPayrollSummarySubtitle,
    ReportRunType.profitCosts => l10n.reportProfitCostsSubtitle,
    ReportRunType.receivablesAging => l10n.reportReceivablesAgingSubtitle,
    ReportRunType.payablesAging => l10n.reportPayablesAgingSubtitle,
    ReportRunType.customerStatement => l10n.reportCustomerStatementSubtitle,
    ReportRunType.supplierStatement => l10n.reportSupplierStatementSubtitle,
    ReportRunType.cashPosition => l10n.reportCashPositionSubtitle,
    ReportRunType.expenseBreakdown => l10n.reportExpenseBreakdownSubtitle,
    ReportRunType.productMargin => l10n.reportProductMarginSubtitle,
    ReportRunType.discountAudit => l10n.reportDiscountAuditSubtitle,
    ReportRunType.salesByStaff => l10n.reportSalesByStaffSubtitle,
    ReportRunType.monthEndPack => l10n.reportMonthEndPackSubtitle,
    ReportRunType.balanceSheet => l10n.reportBalanceSheetSubtitle,
    ReportRunType.unitAging => l10n.reportUnitAgingSubtitle,
    ReportRunType.unitMargin => l10n.reportUnitMarginSubtitle,
    ReportRunType.unitLedger => l10n.reportUnitLedgerSubtitle,
    ReportRunType.consignmentLedger => l10n.reportConsignmentLedgerSubtitle,
  };
}

/// The drawer/tile grouping. Matches the backend's own ``category`` so a report
/// added on the server lands in the right group without a client change.
String reportCategoryLabel(AppLocalizations l10n, String category) {
  return switch (category) {
    'sales' => l10n.reportCategorySales,
    'payments' => l10n.reportCategoryPayments,
    'cash' => l10n.reportCategoryCash,
    'inventory' => l10n.reportCategoryInventory,
    'purchasing' => l10n.reportCategoryPurchasing,
    'employees' => l10n.reportCategoryEmployees,
    'receivables' => l10n.reportCategoryReceivables,
    'payables' => l10n.reportCategoryPayables,
    'expenses' => l10n.reportCategoryExpenses,
    'close' => l10n.reportCategoryClose,
    _ => category,
  };
}
