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

/// Lays the headline hero and the action center side by side on wide screens so
/// the top of the dashboard uses its horizontal space instead of stacking two
/// short full-width cards. Falls back to a vertical stack when narrow, or when
/// there is no hero (e.g. the user cannot view sales).
class _OverviewBand extends StatelessWidget {
  const _OverviewBand({required this.hero, required this.actionCenter});

  /// Side-by-side once the content band is at least this wide.
  static const double _sideBySideMin = 900;

  final Widget? hero;
  final Widget actionCenter;

  @override
  Widget build(BuildContext context) {
    final hero = this.hero;
    if (hero == null) {
      return actionCenter;
    }
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _sideBySideMin) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: hero),
              SizedBox(width: spacing.md),
              Expanded(flex: 2, child: actionCenter),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            hero,
            SizedBox(height: spacing.md),
            actionCenter,
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: where am I this period?
// ---------------------------------------------------------------------------

class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.summary, this.profitability});

  final SalesDashboardSummary summary;
  final ProfitabilityDashboardSummary? profitability;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final profitability = this.profitability;

    return Card(
      key: const ValueKey('dashboard_hero_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.sectionPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.dashboardNetSalesMetric,
              style: theme.textTheme.titleSmall?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: spacing.xs),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: spacing.sm,
              runSpacing: spacing.xs,
              children: [
                Text(
                  formatMoney(summary.netSales),
                  style: switch (theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.ink,
                  )) {
                    final style? => PointyTypography.numeric(style),
                    null => null,
                  },
                ),
                _ChangeBadge(
                  change: summary.netSalesChangePercent,
                  caption: l10n.dashboardVsPreviousPeriodLabel,
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            _HeroStatBand(
              children: [
                _HeroStat(
                  label: l10n.dashboardProfitFromSalesMetric,
                  value: formatMoney(summary.grossProfit),
                  caption: _formatPercent(summary.profitMarginPercent),
                  valueColor: colors.success,
                ),
                if (profitability != null)
                  _HeroStat(
                    label: l10n.dashboardNetProfitMetric,
                    value: formatMoney(profitability.netOperatingProfit),
                    caption: l10n.dashboardAfterExpensesCaption,
                    valueColor: profitability.netOperatingProfit >= 0
                        ? colors.success
                        : colors.danger,
                  ),
                _HeroStat(
                  label: l10n.dashboardOrdersMetric,
                  value: _formatNumber(summary.orderCount),
                  caption: _formatChange(summary.orderCountChangePercent),
                  captionColor: _changeColor(
                    context,
                    summary.orderCountChangePercent,
                  ),
                ),
                _HeroStat(
                  label: l10n.dashboardAverageOrderMetric,
                  value: formatMoney(summary.averageOrderValue),
                ),
                _HeroStat(
                  label: l10n.dashboardItemsSoldMetric,
                  value: _formatNumber(summary.itemsSold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Responsive band of hero KPI chips. Reflows from a single row on wide hero
/// cards down to two-per-row on phones, sizing each chip to fill its row.
class _HeroStatBand extends StatelessWidget {
  const _HeroStatBand({required this.children});

  static const double _minStatWidth = 150;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = AdaptiveSpacing.of(context).sm;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final perRow = (width / _minStatWidth).floor().clamp(
          1,
          children.length,
        );
        final tileWidth = (width - (perRow - 1) * gap) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: tileWidth, child: child),
          ],
        );
      },
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    this.caption,
    this.captionColor,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? caption;
  final Color? captionColor;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.mutedInk,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: switch (theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: valueColor,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
            ),
            if (caption != null && caption!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                caption!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: captionColor ?? colors.mutedInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({required this.change, this.caption});

  final double change;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final color = _changeColor(context, change);
    final icon = change > 0
        ? Icons.trending_up
        : change < 0
        ? Icons.trending_down
        : Icons.trending_flat;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        PointyStatusPill(
          label: _formatChange(change),
          icon: icon,
          color: color,
          compact: false,
        ),
        if (caption != null) ...[
          const SizedBox(height: 2),
          Text(
            caption!,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Action center: what needs me now?
// ---------------------------------------------------------------------------

class _DashboardAlert {
  const _DashboardAlert({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    this.detail,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
  final VoidCallback? onTap;
}

class _ActionCenter extends StatelessWidget {
  const _ActionCenter({
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
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final alerts = _buildAlerts(context, l10n);

    return Card(
      key: const ValueKey('dashboard_action_center_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  alerts.isEmpty
                      ? Icons.verified_outlined
                      : Icons.notifications_active_outlined,
                  color: alerts.isEmpty ? colors.success : colors.warning,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    l10n.dashboardActionCenterTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (alerts.isNotEmpty)
                  PointyStatusPill(
                    label: '${alerts.length}',
                    color: colors.warning,
                  ),
              ],
            ),
            SizedBox(height: spacing.sm),
            if (alerts.isEmpty)
              Row(
                key: const ValueKey('dashboard_all_clear_row'),
                children: [
                  Icon(Icons.check_circle_outline, color: colors.success),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Text(
                      l10n.dashboardAllClearMessage,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.success,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              )
            else
              for (var index = 0; index < alerts.length; index += 1) ...[
                _AlertRow(alert: alerts[index]),
                if (index < alerts.length - 1)
                  Divider(height: spacing.sm, color: colors.line),
              ],
          ],
        ),
      ),
    );
  }

  List<_DashboardAlert> _buildAlerts(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final colors = context.pointyColors;
    final sections = snapshot.sections;
    final alerts = <_DashboardAlert>[];

    final inventory = sections.inventory?.summary;
    if (inventory != null &&
        capabilities.allows(AppCapability.viewInventoryDashboard)) {
      if (inventory.outOfStockCount > 0) {
        alerts.add(
          _DashboardAlert(
            id: 'out_of_stock',
            icon: Icons.remove_shopping_cart_outlined,
            color: colors.danger,
            title: l10n.dashboardAlertOutOfStock(inventory.outOfStockCount),
            onTap: navigation.openCatalog,
          ),
        );
      }
      if (inventory.lowStockCount > 0) {
        alerts.add(
          _DashboardAlert(
            id: 'low_stock',
            icon: Icons.warning_amber_outlined,
            color: colors.warning,
            title: l10n.dashboardAlertLowStock(inventory.lowStockCount),
            onTap: navigation.openCatalog,
          ),
        );
      }
    }

    final purchasing = sections.purchasing?.summary;
    if (purchasing != null &&
        capabilities.allows(AppCapability.viewPurchasingDashboard) &&
        purchasing.overdueOrderCount > 0) {
      alerts.add(
        _DashboardAlert(
          id: 'overdue_purchases',
          icon: Icons.event_busy_outlined,
          color: colors.danger,
          title: l10n.dashboardAlertOverduePurchases(
            purchasing.overdueOrderCount,
          ),
          detail: formatMoney(purchasing.dueTotal),
          onTap: navigation.openPurchasing,
        ),
      );
    }

    final registers = sections.sales?.registers;
    if (registers != null &&
        capabilities.allows(AppCapability.viewSalesDashboard) &&
        registers.varianceCount > 0) {
      alerts.add(
        _DashboardAlert(
          id: 'register_variance',
          icon: Icons.difference_outlined,
          color: colors.warning,
          title: l10n.dashboardAlertRegisterVariance(registers.varianceCount),
          detail: formatMoney(registers.varianceTotal),
          onTap: navigation.openRegisterSessions,
        ),
      );
    }

    final payroll = sections.payroll?.summary;
    if (payroll != null && capabilities.allows(AppCapability.viewPayroll)) {
      if (payroll.draftRunCount > 0) {
        alerts.add(
          _DashboardAlert(
            id: 'draft_payroll',
            icon: Icons.edit_note_outlined,
            color: colors.warning,
            title: l10n.dashboardAlertDraftPayroll(payroll.draftRunCount),
            onTap: navigation.openEmployees,
          ),
        );
      }
      if (payroll.pendingRunCount > 0) {
        alerts.add(
          _DashboardAlert(
            id: 'pending_payroll',
            icon: Icons.price_check_outlined,
            color: colors.warning,
            title: l10n.dashboardAlertPendingPayroll,
            detail: formatMoney(payroll.pendingTotal),
            onTap: navigation.openEmployees,
          ),
        );
      }
      if (payroll.pendingLoanRequestCount > 0) {
        alerts.add(
          _DashboardAlert(
            id: 'pending_loans',
            icon: Icons.account_balance_wallet_outlined,
            color: colors.warning,
            title: l10n.dashboardAlertPendingLoans(
              payroll.pendingLoanRequestCount,
            ),
            onTap: navigation.openEmployees,
          ),
        );
      }
    }

    final discounts = sections.discounts;
    if (discounts != null &&
        capabilities.allows(AppCapability.viewDiscountDashboard) &&
        discounts.expiringRules.isNotEmpty) {
      alerts.add(
        _DashboardAlert(
          id: 'expiring_discounts',
          icon: Icons.local_offer_outlined,
          color: colors.primaryStrong,
          title: l10n.dashboardAlertExpiringDiscounts(
            discounts.expiringRules.length,
          ),
          onTap: navigation.openDiscounts,
        ),
      );
    }

    final fraud = sections.fraud?.summary;
    if (fraud != null &&
        capabilities.allows(AppCapability.viewFraudFindings) &&
        fraud.activeCount > 0) {
      alerts.add(
        _DashboardAlert(
          id: 'fraud_findings',
          icon: Icons.gpp_maybe_outlined,
          color: fraud.criticalCount > 0 ? colors.danger : colors.warning,
          title: l10n.dashboardAlertFraudFindings(fraud.activeCount),
          onTap: navigation.openIntegrityMonitor,
        ),
      );
    }

    final printing = sections.printing?.summary;
    if (printing != null &&
        capabilities.allows(AppCapability.viewPrintingDashboard) &&
        printing.failedCount > 0) {
      alerts.add(
        _DashboardAlert(
          id: 'print_failures',
          icon: Icons.print_disabled_outlined,
          color: colors.danger,
          title: l10n.dashboardAlertPrintFailures(printing.failedCount),
          onTap: navigation.openDeviceSettings,
        ),
      );
    }

    return alerts;
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert});

  final _DashboardAlert alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return InkWell(
      key: ValueKey('dashboard_alert_${alert.id}'),
      onTap: alert.onTap,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(alert.icon, color: alert.color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alert.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (alert.detail != null) ...[
              const SizedBox(width: 8),
              Text(
                alert.detail!,
                style: switch (theme.textTheme.bodyMedium?.copyWith(
                  color: alert.color,
                  fontWeight: FontWeight.w800,
                )) {
                  final style? => PointyTypography.numeric(style),
                  null => null,
                },
              ),
            ],
            if (alert.onTap != null) ...[
              const SizedBox(width: 4),
              PointyDisclosureChevron(color: colors.mutedInk, size: 20),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profit: what is actually left?
// ---------------------------------------------------------------------------

class _ProfitCard extends StatelessWidget {
  const _ProfitCard({required this.section});

  final DashboardProfitabilitySection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final summary = section.summary;
    final isPositive = summary.netOperatingProfit >= 0;

    return PointyDetailSection(
      key: const ValueKey('dashboard_profit_card'),
      title: l10n.dashboardProfitabilitySectionTitle,
      icon: Icons.account_balance_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProfitRow(
            label: l10n.dashboardGrossProfitMetric,
            value: formatMoney(summary.grossProfit),
          ),
          _ProfitRow(
            label: l10n.dashboardPayrollPaidMetric,
            value: '− ${formatMoney(summary.payrollPaidTotal)}',
            color: colors.danger,
          ),
          _ProfitRow(
            label: l10n.dashboardPaymentCommissionsMetric,
            value: '− ${formatMoney(summary.paymentCommissionTotal)}',
            color: colors.danger,
          ),
          if (summary.adHocExpenseTotal > 0)
            _ProfitRow(
              label: l10n.dashboardAdHocExpensesMetric,
              value: '− ${formatMoney(summary.adHocExpenseTotal)}',
              color: colors.danger,
            ),
          Divider(height: spacing.lg, color: colors.line),
          _ProfitRow(
            label: l10n.dashboardNetOperatingProfitMetric,
            value: formatMoney(summary.netOperatingProfit),
            color: isPositive ? colors.success : colors.danger,
            emphasized: true,
          ),
          if (summary.payrollAccruedTotal > 0) ...[
            SizedBox(height: spacing.xs),
            Text(
              l10n.dashboardApprovedAwaitingPaymentNote(
                formatMoney(summary.payrollAccruedTotal),
              ),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfitRow extends StatelessWidget {
  const _ProfitRow({
    required this.label,
    required this.value,
    this.color,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = emphasized
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: baseStyle?.copyWith(
                fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: switch (baseStyle?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            )) {
              final style? => PointyTypography.numeric(style),
              null => null,
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Compact metric summaries (rendered as cards in the unified grid)
// ---------------------------------------------------------------------------

class _SalesSummaryView extends StatelessWidget {
  const _SalesSummaryView({required this.summary});

  final SalesDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardPaymentsTotalMetric,
          trailing: formatMoney(summary.grossSales),
        ),
        _InsightRowData(
          title: l10n.dashboardItemsSoldMetric,
          trailing: _formatNumber(summary.itemsSold),
        ),
        _InsightRowData(
          title: l10n.dashboardDiscountsMetric,
          trailing: formatMoney(summary.discountTotal),
        ),
        _InsightRowData(
          title: l10n.dashboardRefundsMetric,
          subtitle: l10n.dashboardAdjustmentsDetail(
            summary.voidCount,
            summary.returnCount,
          ),
          trailing: formatMoney(summary.refundTotal),
        ),
      ],
    );
  }
}

class _InventorySummaryView extends StatelessWidget {
  const _InventorySummaryView({required this.summary});

  final InventoryDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardRetailStockValueMetric,
          trailing: formatMoney(summary.retailStockValue),
        ),
        _InsightRowData(
          title: l10n.dashboardProductsMetric,
          trailing: _formatNumber(summary.productCount),
        ),
        _InsightRowData(
          title: l10n.dashboardCommittedUnitsMetric,
          trailing: _formatNumber(summary.committedUnits),
        ),
        _InsightRowData(
          title: l10n.dashboardExpectedUnitsMetric,
          trailing: _formatNumber(summary.expectedUnits),
        ),
        _InsightRowData(
          title: l10n.dashboardLowStockMetric,
          trailing: _formatNumber(summary.lowStockCount),
          trailingColor: summary.lowStockCount > 0 ? colors.warning : null,
        ),
        _InsightRowData(
          title: l10n.dashboardOutOfStockMetric,
          trailing: _formatNumber(summary.outOfStockCount),
          trailingColor: summary.outOfStockCount > 0 ? colors.danger : null,
        ),
      ],
    );
  }
}

class _PurchasingSummaryView extends StatelessWidget {
  const _PurchasingSummaryView({required this.summary});

  final PurchasingDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardPurchasesMetric,
          trailing: formatMoney(summary.purchaseTotal),
        ),
        _InsightRowData(
          title: l10n.dashboardDueToSuppliersMetric,
          trailing: formatMoney(summary.dueTotal),
        ),
        _InsightRowData(
          title: l10n.dashboardOpenPurchasesMetric,
          trailing: _formatNumber(summary.openOrderCount),
        ),
        _InsightRowData(
          title: l10n.dashboardOverduePurchasesMetric,
          trailing: _formatNumber(summary.overdueOrderCount),
          trailingColor: summary.overdueOrderCount > 0 ? colors.danger : null,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Integrity card and shared charts/lists
// ---------------------------------------------------------------------------

class _IntegrityCard extends StatelessWidget {
  const _IntegrityCard({required this.section, required this.onOpen});

  final DashboardFraudSection section;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final summary = section.summary;
    final allClear = summary.activeCount == 0;

    return PointyDetailSection(
      key: const ValueKey('dashboard_integrity_card'),
      title: l10n.dashboardIntegritySectionTitle,
      icon: Icons.verified_user_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                allClear
                    ? Icons.verified_user_outlined
                    : Icons.gpp_maybe_outlined,
                color: allClear ? colors.success : colors.warning,
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Text(
                  allClear
                      ? l10n.dashboardIntegrityAllClear
                      : l10n.dashboardAlertFraudFindings(summary.activeCount),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: allClear ? colors.success : colors.ink,
                  ),
                ),
              ),
            ],
          ),
          if (!allClear) ...[
            SizedBox(height: spacing.sm),
            for (final finding in section.recentFindings.take(3))
              PointyDataRow(
                minHeight: 56,
                title: finding.userLabel,
                subtitle: finding.headline.isNotEmpty
                    ? finding.headline
                    : finding.ruleTitle,
                trailing: PointyStatusPill(
                  label: '${finding.riskScore}',
                  color: finding.severity == 'critical'
                      ? colors.danger
                      : colors.warning,
                  icon: Icons.speed_outlined,
                ),
              ),
          ],
          if (onOpen != null) ...[
            SizedBox(height: spacing.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                key: const ValueKey('dashboard_open_integrity_button'),
                onPressed: onOpen,
                icon: const Icon(Icons.shield_outlined),
                label: Text(l10n.dashboardOpenIntegrityButton),
              ),
            ),
          ],
        ],
      ),
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
    final colors = context.pointyColors;
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
              color: colors.primaryStrong,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: colors.primaryStrong.withValues(alpha: 0.14),
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
                    color: context.pointyColors.accentAmber,
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
                  color: context.pointyColors.surface,
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
  const _TopProductsList({required this.products, this.showProfit = false});

  final List<TopProductInsight> products;

  /// When true the trailing value shows per-product profit instead of revenue.
  final bool showProfit;

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
            trailing: formatMoney(
              showProfit ? product.profit : product.revenue,
            ),
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

class _TeamSummaryView extends StatelessWidget {
  const _TeamSummaryView({required this.summary});

  final PayrollDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardSalaryExpenseMetric,
          trailing: formatMoney(summary.salaryExpense),
        ),
        _InsightRowData(
          title: l10n.dashboardPayrollPaidMetric,
          trailing: formatMoney(summary.paidTotal),
        ),
        if (summary.pendingTotal > 0)
          _InsightRowData(
            title: l10n.dashboardPayrollPendingMetric,
            trailing: formatMoney(summary.pendingTotal),
          ),
        _InsightRowData(
          title: l10n.dashboardActiveEmployeesMetric,
          trailing: _formatNumber(summary.activeEmployeeCount),
        ),
      ],
    );
  }
}

class _CustomersSummaryView extends StatelessWidget {
  const _CustomersSummaryView({required this.summary});

  final CustomersDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _InsightRows(
      rows: [
        _InsightRowData(
          title: l10n.dashboardActiveCustomersMetric,
          trailing: _formatNumber(summary.activeCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardNewCustomersMetric,
          trailing: _formatNumber(summary.newCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardRepeatCustomersMetric,
          trailing: _formatNumber(summary.repeatCustomerCount),
        ),
        _InsightRowData(
          title: l10n.dashboardCustomersWithSalesMetric,
          trailing: _formatNumber(summary.customersWithSalesCount),
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
  const _InsightRowData({
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingColor,
  });

  final String title;
  final String? subtitle;
  final String? trailing;
  final Color? trailingColor;
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
              style: switch (Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: row.trailingColor,
              )) {
                final style? => PointyTypography.numeric(style),
                null => null,
              },
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

double _maxValue(Iterable<double> values) {
  final max = values.fold<double>(0, (current, value) {
    return value > current ? value : current;
  });
  return max <= 0 ? 1 : max * 1.25;
}

List<Color> _chartColors(BuildContext context) {
  final colors = context.pointyColors;
  return [
    colors.primaryStrong,
    colors.accentAmber,
    colors.primaryDark,
    colors.warning,
    colors.mutedInk,
    colors.danger,
  ];
}

Color _changeColor(BuildContext context, double value) {
  final colors = context.pointyColors;
  if (value < 0) {
    return colors.danger;
  }
  if (value > 0) {
    return colors.success;
  }
  return colors.mutedInk;
}

// Hoisted so the ICU locale data is parsed once, not rebuilt on every call
// (these format the dashboard's metric tiles and every insight-list row).
final NumberFormat _decimalFormat = NumberFormat.decimalPattern('ar');
final NumberFormat _compactFormat = NumberFormat.compact(locale: 'ar');

String _formatNumber(num value) => _decimalFormat.format(value);

String _formatPercent(double value) => '${value.toStringAsFixed(2)}%';

String _formatChange(double value) {
  final prefix = value > 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(2)}%';
}

String _compactNumber(double value) => _compactFormat.format(value);

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

String _discountChannelLabel(AppLocalizations l10n, String channel) {
  return switch (channel) {
    'sales' => l10n.discountChannelSales,
    'purchasing' => l10n.discountChannelPurchasing,
    'both' => l10n.discountChannelBoth,
    _ => channel,
  };
}

/// Content-shaped placeholder for the dashboard's first paint: a toolbar bar
/// and a responsive grid of metric-tile skeletons, matching the real layout.
class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.workspace,
        child: PointySkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: const [
                  PointySkeletonBox(width: 180, height: 30),
                  Spacer(),
                  PointySkeletonBox(width: 120, height: 36),
                ],
              ),
              SizedBox(height: spacing.lg),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 900
                      ? 3
                      : constraints.maxWidth >= 560
                      ? 2
                      : 1;
                  final gap = spacing.gutter;
                  final tileWidth =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < 6; i++)
                        SizedBox(
                          width: tileWidth,
                          child: const _MetricSkeletonTile(),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricSkeletonTile extends StatelessWidget {
  const _MetricSkeletonTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: PointyDimensions.metricTileMinHeight,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: context.pointyColors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          PointySkeletonBox(width: 90, height: 12),
          PointySkeletonBox(width: 130, height: 26),
          PointySkeletonBox(width: 70, height: 12),
        ],
      ),
    );
  }
}
