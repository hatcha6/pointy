import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/dashboard.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/dashboard_view_model.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenEmployees,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final DashboardViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenEmployees;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.dashboard,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: () {},
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenEmployees: onOpenEmployees,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.dashboardTitle),
            isLoading: viewModel.isLoading,
            reserveLoadingSlot: false,
            actions: [
              DashboardGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshDashboardTooltip,
                  onPressed: viewModel.loadDashboard,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: DashboardGuard(
            capabilities: capabilities,
            child: _DashboardBody(
              viewModel: viewModel,
              capabilities: capabilities,
            ),
          ),
        );
      },
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.viewModel, required this.capabilities});

  final DashboardViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = viewModel.snapshot;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && snapshot == null) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasError && snapshot == null) {
      return PointyErrorState(
        icon: Icons.warning_amber,
        title: l10n.dashboardLoadError,
        action: FilledButton.icon(
          onPressed: viewModel.loadDashboard,
          icon: const Icon(Icons.sync),
          label: Text(l10n.refreshDashboardTooltip),
        ),
      );
    }
    if (snapshot == null || !snapshot.hasSections) {
      return PointyEmptyState(
        icon: Icons.dashboard_outlined,
        title: l10n.dashboardEmptyState,
      );
    }

    return RefreshIndicator(
      onRefresh: viewModel.loadDashboard,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.workspace,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DashboardToolbar(
                    snapshot: snapshot,
                    selectedDays: viewModel.selectedDays,
                    isLoading: viewModel.isLoading,
                    onChanged: viewModel.changePeriod,
                  ),
                  if (viewModel.hasError) ...[
                    SizedBox(height: spacing.md),
                    PointyInlineMessage.error(
                      message: l10n.dashboardLoadError,
                      icon: Icons.warning_amber_outlined,
                    ),
                  ],
                  SizedBox(height: spacing.lg),
                  _DashboardSections(
                    snapshot: snapshot,
                    capabilities: capabilities,
                    maxWidth: constraints.maxWidth,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DashboardToolbar extends StatelessWidget {
  const _DashboardToolbar({
    required this.snapshot,
    required this.selectedDays,
    required this.isLoading,
    required this.onChanged,
  });

  final DashboardSnapshot snapshot;
  final int selectedDays;
  final bool isLoading;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final generatedAt = snapshot.generatedAt;
    return PointySectionHeader(
      title: l10n.dashboardOverviewTitle,
      subtitle: generatedAt == null
          ? l10n.dashboardLastUpdatedUnknown
          : l10n.dashboardLastUpdated(formatDateTime(generatedAt)),
      leading: const Icon(Icons.dashboard_outlined),
      actions: [
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 7, label: Text(l10n.dashboardRange7Days)),
            ButtonSegment(value: 30, label: Text(l10n.dashboardRange30Days)),
            ButtonSegment(value: 90, label: Text(l10n.dashboardRange90Days)),
          ],
          selected: {selectedDays},
          onSelectionChanged: isLoading
              ? null
              : (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}

class _DashboardSections extends StatelessWidget {
  const _DashboardSections({
    required this.snapshot,
    required this.capabilities,
    required this.maxWidth,
  });

  final DashboardSnapshot snapshot;
  final AuthorizationCapabilities capabilities;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final sections = snapshot.sections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sections.sales != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewSalesDashboard,
            child: _SalesSection(section: sections.sales!, maxWidth: maxWidth),
          ),
        if (sections.payments != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewPaymentDashboard,
            child: _PaymentsSection(
              section: sections.payments!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.inventory != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewInventoryDashboard,
            child: _InventorySection(
              section: sections.inventory!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.purchasing != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewPurchasingDashboard,
            child: _PurchasingSection(
              section: sections.purchasing!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.payroll != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewPayroll,
            child: _PayrollSection(
              section: sections.payroll!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.profitability != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewSalesDashboard,
            child: _ProfitabilitySection(
              section: sections.profitability!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.customers != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewCustomerDashboard,
            child: _CustomersSection(
              section: sections.customers!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.discounts != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewDiscountDashboard,
            child: _DiscountsSection(
              section: sections.discounts!,
              maxWidth: maxWidth,
            ),
          ),
        if (sections.printing != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewPrintingDashboard,
            child: _PrintingSection(
              section: sections.printing!,
              maxWidth: maxWidth,
            ),
          ),
      ],
    );
  }
}

class _SalesSection extends StatelessWidget {
  const _SalesSection({required this.section, required this.maxWidth});

  final DashboardSalesSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardSalesSectionTitle,
      icon: Icons.trending_up,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardNetSalesMetric,
              value: formatMoney(summary.netSales),
              icon: Icons.payments_outlined,
              accentColor: _semanticColor(
                context,
                summary.netSalesChangePercent,
              ),
              subtitle: _formatChange(summary.netSalesChangePercent),
            ),
            PointyMetricGridItem(
              label: l10n.dashboardGrossProfitMetric,
              value: formatMoney(summary.grossProfit),
              icon: Icons.account_balance_wallet_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardProfitMarginMetric,
              value: _formatPercent(summary.profitMarginPercent),
              icon: Icons.percent,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardOrdersMetric,
              value: _formatNumber(summary.orderCount),
              icon: Icons.receipt_long_outlined,
              subtitle: _formatChange(summary.orderCountChangePercent),
            ),
            PointyMetricGridItem(
              label: l10n.dashboardAverageOrderMetric,
              value: formatMoney(summary.averageOrderValue),
              icon: Icons.shopping_bag_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardItemsSoldMetric,
              value: _formatNumber(summary.itemsSold),
              icon: Icons.inventory_2_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardDiscountsMetric,
              value: formatMoney(summary.discountTotal),
              icon: Icons.local_offer_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardRefundsMetric,
              value: formatMoney(summary.refundTotal),
              icon: Icons.assignment_return_outlined,
              subtitle: l10n.dashboardAdjustmentsDetail(
                summary.voidCount,
                summary.returnCount,
              ),
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardSalesTrendTitle,
              icon: Icons.show_chart,
              minHeight: 300,
              child: _SalesTrendChart(points: section.trend),
            ),
            PointyDetailSection(
              title: l10n.dashboardHourlySalesTitle,
              icon: Icons.schedule,
              minHeight: 300,
              child: _HourlySalesChart(points: section.hourlySales),
            ),
            PointyDetailSection(
              title: l10n.dashboardTopProductsTitle,
              icon: Icons.star_outline,
              child: _TopProductsList(products: section.topProducts),
            ),
            PointyDetailSection(
              title: l10n.dashboardTopCategoriesTitle,
              icon: Icons.category_outlined,
              child: _TopCategoriesList(categories: section.topCategories),
            ),
            PointyDetailSection(
              title: l10n.dashboardRecentOrdersTitle,
              icon: Icons.history,
              child: _RecentOrdersList(orders: section.recentOrders),
            ),
            PointyDetailSection(
              title: l10n.dashboardRegistersTitle,
              icon: Icons.point_of_sale_outlined,
              child: _RegisterSummaryView(summary: section.registers),
            ),
          ],
        ),
      ],
    );
  }
}

class _PaymentsSection extends StatelessWidget {
  const _PaymentsSection({required this.section, required this.maxWidth});

  final DashboardPaymentsSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _DashboardSection(
      title: l10n.dashboardPaymentsSectionTitle,
      icon: Icons.credit_card,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardPaymentsTotalMetric,
              value: formatMoney(section.summary.total),
              icon: Icons.payments_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPaymentCountMetric,
              value: _formatNumber(section.summary.paymentCount),
              icon: Icons.receipt_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardCommissionMetric,
              value: formatMoney(section.summary.commissionTotal),
              icon: Icons.percent,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardPaymentMixTitle,
              icon: Icons.pie_chart_outline,
              minHeight: 300,
              child: _PaymentMixChart(methods: section.methods),
            ),
            PointyDetailSection(
              title: l10n.dashboardPaymentMethodsTitle,
              icon: Icons.list_alt,
              child: _PaymentMethodList(methods: section.methods),
            ),
          ],
        ),
      ],
    );
  }
}

class _InventorySection extends StatelessWidget {
  const _InventorySection({required this.section, required this.maxWidth});

  final DashboardInventorySection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardInventorySectionTitle,
      icon: Icons.inventory_2,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardProductsMetric,
              value: _formatNumber(summary.productCount),
              icon: Icons.inventory_2_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardLowStockMetric,
              value: _formatNumber(summary.lowStockCount),
              icon: Icons.warning_amber,
              accentColor: summary.lowStockCount > 0
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardOutOfStockMetric,
              value: _formatNumber(summary.outOfStockCount),
              icon: Icons.remove_shopping_cart_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardRetailStockValueMetric,
              value: formatMoney(summary.retailStockValue),
              icon: Icons.storefront_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardCommittedUnitsMetric,
              value: _formatNumber(summary.committedUnits),
              icon: Icons.lock_outline,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardExpectedUnitsMetric,
              value: _formatNumber(summary.expectedUnits),
              icon: Icons.local_shipping_outlined,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardLowStockTitle,
              icon: Icons.warning_amber,
              child: _StockItemList(items: section.lowStockItems),
            ),
            PointyDetailSection(
              title: l10n.dashboardDustyInventoryTitle,
              icon: Icons.hourglass_empty,
              child: _StockItemList(items: section.dustyItems),
            ),
            PointyDetailSection(
              title: l10n.dashboardStockMovementMixTitle,
              icon: Icons.compare_arrows,
              minHeight: 300,
              child: _StockMovementChart(movements: section.movementMix),
            ),
            PointyDetailSection(
              title: l10n.dashboardRecentStockMovementsTitle,
              icon: Icons.history,
              child: _RecentStockMovementList(
                movements: section.recentMovements,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PurchasingSection extends StatelessWidget {
  const _PurchasingSection({required this.section, required this.maxWidth});

  final DashboardPurchasingSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardPurchasingSectionTitle,
      icon: Icons.add_shopping_cart,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardPurchasesMetric,
              value: formatMoney(summary.purchaseTotal),
              icon: Icons.shopping_cart_checkout,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardDueToSuppliersMetric,
              value: formatMoney(summary.dueTotal),
              icon: Icons.account_balance_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardOpenPurchasesMetric,
              value: _formatNumber(summary.openOrderCount),
              icon: Icons.pending_actions_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardOverduePurchasesMetric,
              value: _formatNumber(summary.overdueOrderCount),
              icon: Icons.event_busy_outlined,
              accentColor: summary.overdueOrderCount > 0
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardPurchaseStatusTitle,
              icon: Icons.donut_large,
              minHeight: 300,
              child: _StatusPieChart(
                rows: section.statusCounts,
                labelForStatus: (status) => _purchaseStatusLabel(l10n, status),
              ),
            ),
            PointyDetailSection(
              title: l10n.dashboardOverduePurchasesTitle,
              icon: Icons.event_busy_outlined,
              child: _OverduePurchaseList(orders: section.overdueOrders),
            ),
            PointyDetailSection(
              title: l10n.dashboardSupplierBalancesTitle,
              icon: Icons.account_balance_wallet_outlined,
              child: _SupplierBalanceList(
                balances: section.topSupplierBalances,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PayrollSection extends StatelessWidget {
  const _PayrollSection({required this.section, required this.maxWidth});

  final DashboardPayrollSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardPayrollSectionTitle,
      icon: Icons.badge,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardSalaryExpenseMetric,
              value: formatMoney(summary.salaryExpense),
              icon: Icons.payments_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPayrollPaidMetric,
              value: formatMoney(summary.paidTotal),
              icon: Icons.price_check_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPayrollPendingMetric,
              value: formatMoney(summary.pendingTotal),
              icon: Icons.pending_actions_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardActiveEmployeesMetric,
              value: _formatNumber(summary.activeEmployeeCount),
              icon: Icons.groups_outlined,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardRecentPayrollRunsTitle,
              icon: Icons.history,
              child: _RecentPayrollRunList(runs: section.recentRuns),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfitabilitySection extends StatelessWidget {
  const _ProfitabilitySection({required this.section, required this.maxWidth});

  final DashboardProfitabilitySection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardProfitabilitySectionTitle,
      icon: Icons.trending_up,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: false,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardGrossProfitMetric,
              value: formatMoney(summary.grossProfit),
              icon: Icons.storefront_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPayrollPaidMetric,
              value: formatMoney(summary.payrollPaidTotal),
              icon: Icons.badge_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPaymentCommissionsMetric,
              value: formatMoney(summary.paymentCommissionTotal),
              icon: Icons.credit_card_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardNetOperatingProfitMetric,
              value: formatMoney(summary.netOperatingProfit),
              icon: Icons.account_balance_wallet_outlined,
              accentColor: summary.netOperatingProfit < 0
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ],
    );
  }
}

class _CustomersSection extends StatelessWidget {
  const _CustomersSection({required this.section, required this.maxWidth});

  final DashboardCustomersSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardCustomersSectionTitle,
      icon: Icons.people,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardActiveCustomersMetric,
              value: _formatNumber(summary.activeCustomerCount),
              icon: Icons.people_outline,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardNewCustomersMetric,
              value: _formatNumber(summary.newCustomerCount),
              icon: Icons.person_add_alt,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardCustomersWithSalesMetric,
              value: _formatNumber(summary.customersWithSalesCount),
              icon: Icons.shopping_bag_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardRepeatCustomersMetric,
              value: _formatNumber(summary.repeatCustomerCount),
              icon: Icons.repeat,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardMarketingConsentMetric,
              value: _formatNumber(summary.marketingConsentCount),
              icon: Icons.mark_email_read_outlined,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardTopCustomersTitle,
              icon: Icons.workspace_premium_outlined,
              child: _TopCustomerList(customers: section.topCustomers),
            ),
            PointyDetailSection(
              title: l10n.dashboardRecentCustomersTitle,
              icon: Icons.person_add_alt,
              child: _RecentCustomerList(customers: section.recentCustomers),
            ),
          ],
        ),
      ],
    );
  }
}

class _DiscountsSection extends StatelessWidget {
  const _DiscountsSection({required this.section, required this.maxWidth});

  final DashboardDiscountsSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardDiscountsSectionTitle,
      icon: Icons.local_offer,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardActiveDiscountsMetric,
              value: _formatNumber(summary.activeRuleCount),
              icon: Icons.local_offer_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardCouponDiscountsMetric,
              value: _formatNumber(summary.couponRuleCount),
              icon: Icons.confirmation_number_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardRedemptionsMetric,
              value: _formatNumber(summary.redemptionCount),
              icon: Icons.redeem_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardSalesDiscountMetric,
              value: formatMoney(summary.salesDiscountTotal),
              icon: Icons.point_of_sale_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardPurchaseDiscountMetric,
              value: formatMoney(summary.purchaseDiscountTotal),
              icon: Icons.add_shopping_cart,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardTopDiscountsTitle,
              icon: Icons.leaderboard_outlined,
              child: _DiscountRuleList(rules: section.topRules),
            ),
            PointyDetailSection(
              title: l10n.dashboardExpiringDiscountsTitle,
              icon: Icons.event_busy_outlined,
              child: _ExpiringDiscountList(rules: section.expiringRules),
            ),
          ],
        ),
      ],
    );
  }
}

class _PrintingSection extends StatelessWidget {
  const _PrintingSection({required this.section, required this.maxWidth});

  final DashboardPrintingSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardPrintingSectionTitle,
      icon: Icons.print,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 180,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardQueuedPrintJobsMetric,
              value: _formatNumber(summary.queuedCount),
              icon: Icons.queue_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardClaimedPrintJobsMetric,
              value: _formatNumber(summary.claimedCount),
              icon: Icons.print_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardFailedPrintJobsMetric,
              value: _formatNumber(summary.failedCount),
              icon: Icons.error_outline,
              accentColor: summary.failedCount > 0
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardActivePrintAgentsMetric,
              value: _formatNumber(summary.activeAgentCount),
              icon: Icons.sensors,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardStalePrintAgentsMetric,
              value: _formatNumber(summary.staleAgentCount),
              icon: Icons.sensors_off,
            ),
          ],
        ),
        _ResponsiveWrap(
          maxWidth: maxWidth,
          children: [
            PointyDetailSection(
              title: l10n.dashboardPrintStatusTitle,
              icon: Icons.donut_large,
              minHeight: 300,
              child: _StatusPieChart(
                rows: section.statusCounts,
                labelForStatus: (status) => _printStatusLabel(l10n, status),
              ),
            ),
            PointyDetailSection(
              title: l10n.dashboardPrintFailuresTitle,
              icon: Icons.report_gmailerrorred,
              child: _PrintFailureList(failures: section.recentFailures),
            ),
          ],
        ),
      ],
    );
  }
}

class _DashboardSection extends StatelessWidget {
  const _DashboardSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySectionHeader(title: title, leading: Icon(icon, size: 22)),
          SizedBox(height: spacing.sm),
          ...children,
        ],
      ),
    );
  }
}

class _ResponsiveWrap extends StatelessWidget {
  const _ResponsiveWrap({required this.maxWidth, required this.children});

  final double maxWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Wrap(
      spacing: spacing.md,
      runSpacing: spacing.md,
      children: [
        for (final child in children)
          SizedBox(
            width: _cardWidth(
              maxWidth,
              minWidth: 320,
              maxColumns: 2,
              gap: spacing.md,
            ),
            child: child,
          ),
      ],
    );
  }
}

class _SalesTrendChart extends StatelessWidget {
  const _SalesTrendChart({required this.points});

  final List<SalesTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.every((point) => point.netSales == 0)) {
      return const _EmptyWidgetData();
    }
    final maxY = _maxValue(points.map((point) => point.netSales));
    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(context),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var index = 0; index < points.length; index += 1)
                  FlSpot(index.toDouble(), points[index].netSales),
              ],
              isCurved: true,
              color: Theme.of(context).colorScheme.primary,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HourlySalesChart extends StatelessWidget {
  const _HourlySalesChart({required this.points});

  final List<HourlySalesPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.every((point) => point.netSales == 0)) {
      return const _EmptyWidgetData();
    }
    final visible = points
        .where((point) => point.hour % 3 == 0 || point.netSales > 0)
        .toList(growable: false);
    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(context),
          barGroups: [
            for (final point in visible)
              BarChartGroupData(
                x: point.hour,
                barRods: [
                  BarChartRodData(
                    toY: point.netSales,
                    width: 9,
                    borderRadius: BorderRadius.circular(4),
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PaymentMixChart extends StatelessWidget {
  const _PaymentMixChart({required this.methods});

  final List<PaymentMethodInsight> methods;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nonZero = methods
        .where((method) => method.total.abs() > 0)
        .toList(growable: false);
    if (nonZero.isEmpty) {
      return const _EmptyWidgetData();
    }
    final colors = _chartColors(context);
    return SizedBox(
      height: 220,
      child: PieChart(
        PieChartData(
          centerSpaceRadius: 46,
          sectionsSpace: 2,
          sections: [
            for (var index = 0; index < nonZero.length; index += 1)
              PieChartSectionData(
                value: nonZero[index].total.abs(),
                title: _paymentMethodLabel(l10n, nonZero[index].method),
                radius: 74,
                color: colors[index % colors.length],
                titleStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StockMovementChart extends StatelessWidget {
  const _StockMovementChart({required this.movements});

  final List<StockMovementMixInsight> movements;

  @override
  Widget build(BuildContext context) {
    final visible = movements.where((item) => item.quantity > 0).toList();
    if (visible.isEmpty) {
      return const _EmptyWidgetData();
    }
    final colors = _chartColors(context);
    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: _axisTitles(context),
          barGroups: [
            for (var index = 0; index < visible.length; index += 1)
              BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: visible[index].quantity.toDouble(),
                    width: 22,
                    borderRadius: BorderRadius.circular(4),
                    color: colors[index % colors.length],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusPieChart extends StatelessWidget {
  const _StatusPieChart({required this.rows, required this.labelForStatus});

  final List<StatusCountInsight> rows;
  final String Function(String status) labelForStatus;

  @override
  Widget build(BuildContext context) {
    final visible = rows.where((row) => row.count > 0).toList(growable: false);
    if (visible.isEmpty) {
      return const _EmptyWidgetData();
    }
    final colors = _chartColors(context);
    return SizedBox(
      height: 220,
      child: PieChart(
        PieChartData(
          centerSpaceRadius: 42,
          sections: [
            for (var index = 0; index < visible.length; index += 1)
              PieChartSectionData(
                value: visible[index].count.toDouble(),
                title: labelForStatus(visible[index].status),
                radius: 72,
                color: colors[index % colors.length],
                titleStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopProductsList extends StatelessWidget {
  const _TopProductsList({required this.products});

  final List<TopProductInsight> products;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (products.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final product in products)
          _InsightRowData(
            title: product.productName,
            subtitle: product.sku.isEmpty
                ? l10n.dashboardQuantityOnly(product.quantity)
                : l10n.dashboardQuantityWithSku(product.quantity, product.sku),
            trailing: formatMoney(product.revenue),
          ),
      ],
    );
  }
}

class _TopCategoriesList extends StatelessWidget {
  const _TopCategoriesList({required this.categories});

  final List<TopCategoryInsight> categories;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (categories.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final category in categories)
          _InsightRowData(
            title: category.categoryName.isEmpty
                ? l10n.dashboardUncategorizedLabel
                : category.categoryName,
            subtitle: l10n.dashboardQuantityOnly(category.quantity),
            trailing: formatMoney(category.revenue),
          ),
      ],
    );
  }
}

class _RecentOrdersList extends StatelessWidget {
  const _RecentOrdersList({required this.orders});

  final List<RecentOrderInsight> orders;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (orders.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final order in orders)
          _InsightRowData(
            title: order.receiptNumber,
            subtitle: order.customerName.isEmpty
                ? _orderStatusLabel(l10n, order.status)
                : order.customerName,
            trailing: formatMoney(order.total),
          ),
      ],
    );
  }
}

class _RegisterSummaryView extends StatelessWidget {
  const _RegisterSummaryView({required this.summary});

  final RegisterDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardOpenRegistersLabel,
          trailing: _formatNumber(summary.openCount),
        ),
        _InsightRowData(
          title: l10n.dashboardClosedRegistersLabel,
          trailing: _formatNumber(summary.closedCount),
        ),
        _InsightRowData(
          title: l10n.dashboardVarianceRegistersLabel,
          subtitle: formatMoney(summary.varianceTotal),
          trailing: _formatNumber(summary.varianceCount),
        ),
      ],
    );
  }
}

class _PaymentMethodList extends StatelessWidget {
  const _PaymentMethodList({required this.methods});

  final List<PaymentMethodInsight> methods;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (methods.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final method in methods)
          _InsightRowData(
            title: _paymentMethodLabel(l10n, method.method),
            subtitle: l10n.dashboardPaymentMethodCount(method.count),
            trailing: formatMoney(method.total),
          ),
      ],
    );
  }
}

class _StockItemList extends StatelessWidget {
  const _StockItemList({required this.items});

  final List<StockItemInsight> items;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (items.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final item in items)
          _InsightRowData(
            title: item.productName,
            subtitle: l10n.dashboardStockItemSubtitle(
              item.sku,
              item.reorderLevel,
              item.quantityExpected,
            ),
            trailing: _formatNumber(item.quantityOnHand),
          ),
      ],
    );
  }
}

class _RecentStockMovementList extends StatelessWidget {
  const _RecentStockMovementList({required this.movements});

  final List<RecentStockMovementInsight> movements;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (movements.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final movement in movements)
          _InsightRowData(
            title: movement.productName,
            subtitle: _stockMovementLabel(l10n, movement.movementType),
            trailing: _formatNumber(movement.quantity),
          ),
      ],
    );
  }
}

class _OverduePurchaseList extends StatelessWidget {
  const _OverduePurchaseList({required this.orders});

  final List<OverduePurchaseInsight> orders;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final order in orders)
          _InsightRowData(
            title: order.orderNumber,
            subtitle: order.supplierName,
            trailing: formatMoney(order.balanceDue),
          ),
      ],
    );
  }
}

class _SupplierBalanceList extends StatelessWidget {
  const _SupplierBalanceList({required this.balances});

  final List<SupplierBalanceInsight> balances;

  @override
  Widget build(BuildContext context) {
    if (balances.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final balance in balances)
          _InsightRowData(
            title: balance.supplierName,
            trailing: formatMoney(balance.netBalance),
          ),
      ],
    );
  }
}

class _RecentPayrollRunList extends StatelessWidget {
  const _RecentPayrollRunList({required this.runs});

  final List<RecentPayrollRunInsight> runs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (runs.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final run in runs)
          _InsightRowData(
            title: run.runNumber,
            subtitle: run.periodStart == null || run.periodEnd == null
                ? _payrollRunStatusLabel(l10n, run.status)
                : l10n.payrollPeriodSubtitle(
                    formatDate(run.periodStart!),
                    formatDate(run.periodEnd!),
                  ),
            trailing: formatMoney(run.netTotal),
          ),
      ],
    );
  }
}

class _TopCustomerList extends StatelessWidget {
  const _TopCustomerList({required this.customers});

  final List<TopCustomerInsight> customers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (customers.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final customer in customers)
          _InsightRowData(
            title: customer.customerName.isEmpty
                ? l10n.dashboardAnonymousCustomerLabel
                : customer.customerName,
            subtitle: l10n.dashboardOrderCount(customer.orderCount),
            trailing: formatMoney(customer.salesTotal),
          ),
      ],
    );
  }
}

class _RecentCustomerList extends StatelessWidget {
  const _RecentCustomerList({required this.customers});

  final List<RecentCustomerInsight> customers;

  @override
  Widget build(BuildContext context) {
    if (customers.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final customer in customers)
          _InsightRowData(
            title: customer.customerName,
            subtitle: customer.customerNumber,
            trailing: customer.createdAt == null
                ? ''
                : formatDate(customer.createdAt!),
          ),
      ],
    );
  }
}

class _DiscountRuleList extends StatelessWidget {
  const _DiscountRuleList({required this.rules});

  final List<DiscountRuleInsight> rules;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (rules.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final rule in rules)
          _InsightRowData(
            title: rule.ruleName,
            subtitle: _discountChannelLabel(l10n, rule.channel),
            trailing: formatMoney(rule.discountTotal),
          ),
      ],
    );
  }
}

class _ExpiringDiscountList extends StatelessWidget {
  const _ExpiringDiscountList({required this.rules});

  final List<ExpiringDiscountRuleInsight> rules;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (rules.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final rule in rules)
          _InsightRowData(
            title: rule.ruleName,
            subtitle: _discountChannelLabel(l10n, rule.channel),
            trailing: rule.endsAt == null ? '' : formatDate(rule.endsAt!),
          ),
      ],
    );
  }
}

class _PrintFailureList extends StatelessWidget {
  const _PrintFailureList({required this.failures});

  final List<PrintFailureInsight> failures;

  @override
  Widget build(BuildContext context) {
    if (failures.isEmpty) {
      return const _EmptyWidgetData();
    }
    return _InsightRows(
      rows: [
        for (final failure in failures)
          _InsightRowData(
            title: failure.receiptNumber,
            subtitle: failure.errorMessage,
            trailing: failure.failedAt == null
                ? ''
                : formatDateTime(failure.failedAt!),
          ),
      ],
    );
  }
}

class _InsightRowData {
  const _InsightRowData({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final String? trailing;
}

class _InsightRows extends StatelessWidget {
  const _InsightRows({required this.rows});

  final List<_InsightRowData> rows;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      children: [
        for (var index = 0; index < rows.length; index += 1) ...[
          _InsightRow(row: rows[index]),
          if (index < rows.length - 1) SizedBox(height: spacing.xs),
        ],
      ],
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.row});

  final _InsightRowData row;

  @override
  Widget build(BuildContext context) {
    return PointyDataRow(
      title: row.title,
      subtitle: row.subtitle,
      minHeight: 60,
      trailing: row.trailing == null || row.trailing!.isEmpty
          ? null
          : Text(
              row.trailing!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
    );
  }
}

class _EmptyWidgetData extends StatelessWidget {
  const _EmptyWidgetData();

  @override
  Widget build(BuildContext context) {
    return PointyEmptyState(
      icon: Icons.insights_outlined,
      title: AppLocalizations.of(context)!.dashboardNoWidgetData,
    );
  }
}

FlTitlesData _axisTitles(BuildContext context) {
  final textStyle = Theme.of(context).textTheme.labelSmall;
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 42,
        getTitlesWidget: (value, meta) {
          return Text(
            _compactNumber(value),
            style: textStyle,
            textAlign: TextAlign.center,
          );
        },
      ),
    ),
    bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  );
}

double _cardWidth(
  double maxWidth, {
  required double minWidth,
  required int maxColumns,
  double gap = 12,
}) {
  var columns = maxWidth ~/ minWidth;
  columns = columns.clamp(1, maxColumns).toInt();
  final gaps = (columns - 1) * gap;
  return (maxWidth - gaps) / columns;
}

double _maxValue(Iterable<double> values) {
  final max = values.fold<double>(0, (current, value) {
    return value > current ? value : current;
  });
  return max <= 0 ? 1 : max * 1.25;
}

List<Color> _chartColors(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return [
    scheme.primary,
    scheme.secondary,
    scheme.tertiary,
    scheme.error,
    scheme.inversePrimary,
    scheme.outline,
  ];
}

Color _semanticColor(BuildContext context, double value) {
  if (value < 0) {
    return Theme.of(context).colorScheme.error;
  }
  return Theme.of(context).colorScheme.primary;
}

String _formatNumber(num value) =>
    NumberFormat.decimalPattern('ar').format(value);

String _formatPercent(double value) => '${value.toStringAsFixed(2)}%';

String _formatChange(double value) {
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(2)}%';
}

String _compactNumber(double value) {
  return NumberFormat.compact(locale: 'ar').format(value);
}

String _paymentMethodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'cash' => l10n.paymentMethodCash,
    'card' => l10n.paymentMethodCard,
    'transfer' => l10n.paymentMethodTransfer,
    _ => method,
  };
}

String _orderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'open' => l10n.dashboardOrderStatusOpen,
    'paid' => l10n.dashboardOrderStatusPaid,
    'void' => l10n.dashboardOrderStatusVoid,
    _ => status,
  };
}

String _purchaseStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'draft' => l10n.purchaseOrderStatusDraft,
    'submitted' => l10n.purchaseOrderStatusSubmitted,
    'partially_received' => l10n.purchaseOrderStatusPartiallyReceived,
    'received' => l10n.purchaseOrderStatusReceived,
    'cancelled' => l10n.purchaseOrderStatusCancelled,
    _ => status,
  };
}

String _printStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'queued' => l10n.dashboardPrintStatusQueued,
    'claimed' => l10n.dashboardPrintStatusClaimed,
    'printed' => l10n.dashboardPrintStatusPrinted,
    'failed' => l10n.dashboardPrintStatusFailed,
    'canceled' => l10n.dashboardPrintStatusCanceled,
    _ => status,
  };
}

String _stockMovementLabel(AppLocalizations l10n, String movementType) {
  return switch (movementType) {
    'increase' => l10n.stockMovementIncrease,
    'decrease' => l10n.stockMovementDecrease,
    'damaged' => l10n.stockMovementDamaged,
    'expected' => l10n.stockMovementExpected,
    'receive_expected' => l10n.stockMovementReceiveExpected,
    'receive_damaged' => l10n.stockMovementReceiveDamaged,
    'cancel_expected' => l10n.stockMovementCancelExpected,
    _ => movementType,
  };
}

String _payrollRunStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'draft' => l10n.payrollStatusDraft,
    'approved' => l10n.payrollStatusApproved,
    'paid' => l10n.payrollStatusPaid,
    'void' => l10n.payrollStatusVoid,
    _ => status,
  };
}

String _discountChannelLabel(AppLocalizations l10n, String channel) {
  return switch (channel) {
    'sales' => l10n.discountChannelSales,
    'purchasing' => l10n.discountChannelPurchasing,
    'both' => l10n.discountChannelBoth,
    _ => channel,
  };
}
