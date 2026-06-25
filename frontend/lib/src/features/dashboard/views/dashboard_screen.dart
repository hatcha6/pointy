import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/dashboard.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/dashboard_view_model.dart';

part 'dashboard_screen_hero.dart';
part 'dashboard_screen_widgets.dart';

/// Owner-first dashboard: a headline that answers "how is the shop doing in
/// this period", an action center that answers "what needs me now", and then
/// progressively deeper insight sections as you scroll.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.navigation,
    this.onOpenIntegrityMonitor,
  });

  final DashboardViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final VoidCallback? onOpenIntegrityMonitor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.dashboard,
            navigation: navigation,
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
              navigation: _DashboardNavigation(
                openCatalog: _destinationAction(
                  context,
                  AppNavigationDestination.catalog,
                ),
                openContacts: _destinationAction(
                  context,
                  AppNavigationDestination.contacts,
                ),
                openPos: _destinationAction(
                  context,
                  AppNavigationDestination.pos,
                ),
                openPurchasing: _destinationAction(
                  context,
                  AppNavigationDestination.purchasing,
                ),
                openRegisterSessions: _destinationAction(
                  context,
                  AppNavigationDestination.registerSessions,
                ),
                openEmployees: _destinationAction(
                  context,
                  AppNavigationDestination.employees,
                ),
                openDiscounts: _destinationAction(
                  context,
                  AppNavigationDestination.discounts,
                ),
                openDeviceSettings: _destinationAction(
                  context,
                  AppNavigationDestination.deviceSettings,
                ),
                openIntegrityMonitor: onOpenIntegrityMonitor,
              ),
            ),
          ),
        );
      },
    );
  }

  VoidCallback? _destinationAction(
    BuildContext context,
    AppNavigationDestination destination,
  ) {
    if (!navigation.isDestinationAvailable(destination)) {
      return null;
    }
    return () => navigation.navigateTo(
      context,
      destination,
      from: AppNavigationDestination.dashboard,
    );
  }
}

/// Targets the action center can deep-link to.
class _DashboardNavigation {
  const _DashboardNavigation({
    required this.openCatalog,
    required this.openContacts,
    required this.openPos,
    required this.openPurchasing,
    required this.openRegisterSessions,
    required this.openEmployees,
    required this.openDiscounts,
    required this.openDeviceSettings,
    required this.openIntegrityMonitor,
  });

  final VoidCallback? openCatalog;
  final VoidCallback? openContacts;
  final VoidCallback? openPos;
  final VoidCallback? openPurchasing;
  final VoidCallback? openRegisterSessions;
  final VoidCallback? openEmployees;
  final VoidCallback? openDiscounts;
  final VoidCallback? openDeviceSettings;
  final VoidCallback? openIntegrityMonitor;
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.viewModel,
    required this.capabilities,
    required this.navigation,
  });

  final DashboardViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final _DashboardNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = viewModel.snapshot;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && snapshot == null) {
      return const _DashboardSkeleton();
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
          child: Column(
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
              SizedBox(height: spacing.md),
              _DashboardSections(
                snapshot: snapshot,
                capabilities: capabilities,
                navigation: navigation,
              ),
            ],
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
    required this.navigation,
  });

  final DashboardSnapshot snapshot;
  final AuthorizationCapabilities capabilities;
  final _DashboardNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final sections = snapshot.sections;

    bool can(AppCapability capability) => capabilities.allows(capability);

    final sales = can(AppCapability.viewSalesDashboard) ? sections.sales : null;
    final profitability = can(AppCapability.viewSalesDashboard)
        ? sections.profitability
        : null;
    final fraud = can(AppCapability.viewFraudFindings) ? sections.fraud : null;
    final inventory = can(AppCapability.viewInventoryDashboard)
        ? sections.inventory
        : null;
    final purchasing = can(AppCapability.viewPurchasingDashboard)
        ? sections.purchasing
        : null;
    final payments = can(AppCapability.viewPaymentDashboard)
        ? sections.payments
        : null;
    final customers = can(AppCapability.viewCustomerDashboard)
        ? sections.customers
        : null;
    final discounts = can(AppCapability.viewDiscountDashboard)
        ? sections.discounts
        : null;
    final payroll = can(AppCapability.viewPayroll) ? sections.payroll : null;
    final printing = can(AppCapability.viewPrintingDashboard)
        ? sections.printing
        : null;

    final productCount = inventory?.summary.productCount;
    final orderCount = sales?.summary.orderCount;
    final customerCount = customers?.summary.activeCustomerCount;
    // Only nudge a genuinely fresh shop: we must be able to see both inventory
    // and sales, and both are empty. This gates the card to owners/managers
    // (cashiers never have these capabilities) and auto-hides once the first
    // product and first sale exist.
    final showGetStarted =
        productCount != null &&
        productCount == 0 &&
        orderCount != null &&
        orderCount == 0;

    // Every detail card flows into a single masonry grid so cards pack tightly
    // across the whole page instead of leaving gaps inside per-section blocks.
    // Tall charts come first to anchor the columns; shorter cards fill behind.
    final cards = <Widget>[
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardSalesTrendTitle,
          icon: Icons.show_chart,
          minHeight: 300,
          child: _SalesTrendChart(points: sales.trend),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardHourlySalesTitle,
          icon: Icons.schedule,
          minHeight: 300,
          child: _HourlySalesChart(points: sales.hourlySales),
        ),
      if (payments != null)
        PointyDetailSection(
          title: l10n.dashboardPaymentMixTitle,
          icon: Icons.pie_chart_outline,
          minHeight: 300,
          child: _PaymentMixChart(methods: payments.methods),
        ),
      if (profitability != null) _ProfitCard(section: profitability),
      if (fraud != null)
        _IntegrityCard(section: fraud, onOpen: navigation.openIntegrityMonitor),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardTopProductsTitle,
          icon: Icons.star_outline,
          child: _TopProductsList(products: sales.topProducts),
        ),
      if (sales != null && sales.reports.productProfit.isNotEmpty)
        PointyDetailSection(
          title: l10n.dashboardTopProductsByProfitTitle,
          icon: Icons.payments_outlined,
          child: _TopProductsList(
            products: sales.reports.productProfit,
            showProfit: true,
          ),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardTopCategoriesTitle,
          icon: Icons.category_outlined,
          child: _TopCategoriesList(categories: sales.topCategories),
        ),
      if (customers != null)
        PointyDetailSection(
          title: l10n.dashboardTopCustomersTitle,
          icon: Icons.emoji_events_outlined,
          child: _TopCustomerList(customers: customers.topCustomers),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardRecentOrdersTitle,
          icon: Icons.history,
          child: _RecentOrdersList(orders: sales.recentOrders),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardRegistersTitle,
          icon: Icons.point_of_sale_outlined,
          child: _RegisterSummaryView(summary: sales.registers),
        ),
      if (payments != null)
        PointyDetailSection(
          title: l10n.dashboardPaymentMethodsTitle,
          icon: Icons.list_alt,
          child: _PaymentMethodList(methods: payments.methods),
        ),
      if (payroll != null)
        PointyDetailSection(
          title: l10n.dashboardPayrollSectionTitle,
          icon: Icons.badge_outlined,
          child: _TeamSummaryView(summary: payroll.summary),
        ),
      if (customers != null)
        PointyDetailSection(
          title: l10n.dashboardCustomersSectionTitle,
          icon: Icons.groups_outlined,
          child: _CustomersSummaryView(summary: customers.summary),
        ),
      if (discounts != null)
        PointyDetailSection(
          title: l10n.dashboardTopDiscountsTitle,
          icon: Icons.local_offer_outlined,
          child: _DiscountRuleList(rules: discounts.topRules),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardSalesSectionTitle,
          icon: Icons.receipt_long_outlined,
          child: _SalesSummaryView(summary: sales.summary),
        ),
      if (inventory != null)
        PointyDetailSection(
          title: l10n.dashboardInventorySectionTitle,
          icon: Icons.inventory_2,
          child: _InventorySummaryView(summary: inventory.summary),
        ),
      if (inventory != null)
        PointyDetailSection(
          title: l10n.dashboardLowStockTitle,
          icon: Icons.warning_amber,
          child: _StockItemList(items: inventory.lowStockItems),
        ),
      if (inventory != null)
        PointyDetailSection(
          title: l10n.dashboardDustyInventoryTitle,
          icon: Icons.hourglass_empty,
          child: _StockItemList(items: inventory.dustyItems),
        ),
      if (purchasing != null)
        PointyDetailSection(
          title: l10n.dashboardPurchasingSectionTitle,
          icon: Icons.add_shopping_cart,
          child: _PurchasingSummaryView(summary: purchasing.summary),
        ),
      if (purchasing != null)
        PointyDetailSection(
          title: l10n.dashboardOverduePurchasesTitle,
          icon: Icons.event_busy_outlined,
          child: _OverduePurchaseList(orders: purchasing.overdueOrders),
        ),
      if (purchasing != null)
        PointyDetailSection(
          title: l10n.dashboardSupplierBalancesTitle,
          icon: Icons.account_balance_wallet_outlined,
          child: _SupplierBalanceList(balances: purchasing.topSupplierBalances),
        ),
      if (printing != null && printing.summary.failedCount > 0)
        PointyDetailSection(
          title: l10n.dashboardPrintFailuresTitle,
          icon: Icons.print_disabled_outlined,
          child: _PrintFailureList(failures: printing.recentFailures),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (snapshot.todaySpecialDays.isNotEmpty) ...[
          _SpecialDayBanner(specialDays: snapshot.todaySpecialDays),
          SizedBox(height: spacing.lg),
        ],
        if (showGetStarted) ...[
          _GetStartedChecklist(
            // showGetStarted guarantees zero products and zero sales here; only
            // the customer step can already be done.
            hasProduct: false,
            hasCustomer: (customerCount ?? 0) > 0,
            hasSale: false,
            onAddProduct: navigation.openCatalog,
            onAddCustomer: navigation.openContacts,
            onFirstSale: navigation.openPos,
          ),
          SizedBox(height: spacing.lg),
        ],
        _OverviewBand(
          hero: sales != null
              ? _HeroSection(
                  summary: sales.summary,
                  profitability: profitability?.summary,
                )
              : null,
          actionCenter: _ActionCenter(
            snapshot: snapshot,
            capabilities: capabilities,
            navigation: navigation,
          ),
        ),
        if (cards.isNotEmpty) ...[
          SizedBox(height: spacing.lg),
          PointyMasonryGrid(children: cards),
        ],
      ],
    );
  }
}

/// First-run "Get started" card shown to a brand-new shop, nudging the owner
/// through the first product, customer, and sale. Each step deep-links to its
/// screen and self-hides when its capability is unavailable.
class _GetStartedChecklist extends StatelessWidget {
  const _GetStartedChecklist({
    required this.hasProduct,
    required this.hasCustomer,
    required this.hasSale,
    required this.onAddProduct,
    required this.onAddCustomer,
    required this.onFirstSale,
  });

  final bool hasProduct;
  final bool hasCustomer;
  final bool hasSale;
  final VoidCallback? onAddProduct;
  final VoidCallback? onAddCustomer;
  final VoidCallback? onFirstSale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final rows = <Widget>[
      if (onAddProduct != null)
        _GetStartedRow(
          icon: Icons.inventory_2_outlined,
          label: l10n.dashboardGetStartedAddProduct,
          done: hasProduct,
          onTap: onAddProduct!,
        ),
      if (onAddCustomer != null)
        _GetStartedRow(
          icon: Icons.person_add_alt_outlined,
          label: l10n.dashboardGetStartedAddCustomer,
          done: hasCustomer,
          onTap: onAddCustomer!,
        ),
      if (onFirstSale != null)
        _GetStartedRow(
          icon: Icons.point_of_sale_outlined,
          label: l10n.dashboardGetStartedFirstSale,
          done: hasSale,
          onTap: onFirstSale!,
        ),
    ];

    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
        boxShadow: PointyShadows.raised,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined, color: colors.primaryStrong),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.dashboardGetStartedTitle,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        l10n.dashboardGetStartedSubtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _GetStartedRow extends StatelessWidget {
  const _GetStartedRow({
    required this.icon,
    required this.label,
    required this.done,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: spacing.sm),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle : icon,
              color: done ? colors.success : colors.primaryStrong,
            ),
            SizedBox(width: spacing.md),
            Expanded(
              child: Text(
                label,
                style: textTheme.bodyLarge?.copyWith(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? colors.mutedInk : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (done)
              Text(
                l10n.dashboardGetStartedDone,
                style: textTheme.labelMedium?.copyWith(color: colors.success),
              )
            else
              const PointyDisclosureChevron(),
          ],
        ),
      ),
    );
  }
}
