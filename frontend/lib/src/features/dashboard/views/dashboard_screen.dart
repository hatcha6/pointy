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
    required this.openPurchasing,
    required this.openRegisterSessions,
    required this.openEmployees,
    required this.openDiscounts,
    required this.openDeviceSettings,
    required this.openIntegrityMonitor,
  });

  final VoidCallback? openCatalog;
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
                  SizedBox(height: spacing.md),
                  _DashboardSections(
                    snapshot: snapshot,
                    capabilities: capabilities,
                    navigation: navigation,
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
    required this.navigation,
    required this.maxWidth,
  });

  final DashboardSnapshot snapshot;
  final AuthorizationCapabilities capabilities;
  final _DashboardNavigation navigation;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final sections = snapshot.sections;
    final spacing = AdaptiveSpacing.of(context);
    final showSales =
        sections.sales != null &&
        capabilities.allows(AppCapability.viewSalesDashboard);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showSales) ...[
          _HeroSection(summary: sections.sales!.summary),
          SizedBox(height: spacing.md),
        ],
        _ActionCenter(
          snapshot: snapshot,
          capabilities: capabilities,
          navigation: navigation,
        ),
        SizedBox(height: spacing.xl),
        if (showSales)
          _SalesStorySection(section: sections.sales!, maxWidth: maxWidth),
        if (sections.profitability != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewSalesDashboard,
            child: _ProfitSection(section: sections.profitability!),
          ),
        if (sections.fraud != null &&
            capabilities.allows(AppCapability.viewFraudFindings))
          _IntegritySection(
            section: sections.fraud!,
            onOpen: navigation.openIntegrityMonitor,
          ),
        if (showSales)
          _BestSellersSection(
            sales: sections.sales!,
            customers:
                capabilities.allows(AppCapability.viewCustomerDashboard)
                ? sections.customers
                : null,
          ),
        if (sections.inventory != null)
          DashboardWidgetGuard(
            capabilities: capabilities,
            capability: AppCapability.viewInventoryDashboard,
            child: _InventoryHealthSection(
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
        _OperationsSection(
          snapshot: snapshot,
          capabilities: capabilities,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: where am I this period?
// ---------------------------------------------------------------------------

class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.summary});

  final SalesDashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;

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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _HeroStat(
                    label: l10n.dashboardGrossProfitMetric,
                    value: formatMoney(summary.grossProfit),
                    caption: _formatPercent(summary.profitMarginPercent),
                  ),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: _HeroStat(
                    label: l10n.dashboardOrdersMetric,
                    value: _formatNumber(summary.orderCount),
                    caption: _formatChange(summary.orderCountChangePercent),
                    captionColor: _changeColor(
                      context,
                      summary.orderCountChangePercent,
                    ),
                  ),
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: _HeroStat(
                    label: l10n.dashboardAverageOrderMetric,
                    value: formatMoney(summary.averageOrderValue),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    this.caption,
    this.captionColor,
  });

  final String label;
  final String value;
  final String? caption;
  final Color? captionColor;

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
// Sales story: how did the period unfold?
// ---------------------------------------------------------------------------

class _SalesStorySection extends StatelessWidget {
  const _SalesStorySection({required this.section, required this.maxWidth});

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
        PointyCardGrid(
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
          ],
        ),
        SizedBox(height: AdaptiveSpacing.of(context).sm),
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 160,
          maxColumns: 4,
          metrics: [
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
            PointyMetricGridItem(
              label: l10n.dashboardPaymentsTotalMetric,
              value: formatMoney(summary.grossSales),
              icon: Icons.payments_outlined,
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Profit: what is actually left?
// ---------------------------------------------------------------------------

class _ProfitSection extends StatelessWidget {
  const _ProfitSection({required this.section});

  final DashboardProfitabilitySection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final summary = section.summary;
    final isPositive = summary.netOperatingProfit >= 0;

    return _DashboardSection(
      title: l10n.dashboardProfitabilitySectionTitle,
      icon: Icons.account_balance_outlined,
      children: [
        Card(
          key: const ValueKey('dashboard_profit_card'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: spacing.compactPadding,
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
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
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
// Best sellers: what and who drives the business?
// ---------------------------------------------------------------------------

class _BestSellersSection extends StatelessWidget {
  const _BestSellersSection({required this.sales, required this.customers});

  final DashboardSalesSection sales;
  final DashboardCustomersSection? customers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _DashboardSection(
      title: l10n.dashboardBestSellersTitle,
      icon: Icons.star_outline,
      children: [
        PointyCardGrid(
          children: [
            PointyDetailSection(
              title: l10n.dashboardTopProductsTitle,
              icon: Icons.star_outline,
              child: _TopProductsList(products: sales.topProducts),
            ),
            PointyDetailSection(
              title: l10n.dashboardTopCategoriesTitle,
              icon: Icons.category_outlined,
              child: _TopCategoriesList(categories: sales.topCategories),
            ),
            if (customers != null)
              PointyDetailSection(
                title: l10n.dashboardTopCustomersTitle,
                icon: Icons.emoji_events_outlined,
                child: _TopCustomerList(customers: customers!.topCustomers),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Inventory health
// ---------------------------------------------------------------------------

class _InventoryHealthSection extends StatelessWidget {
  const _InventoryHealthSection({
    required this.section,
    required this.maxWidth,
  });

  final DashboardInventorySection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardInventorySectionTitle,
      icon: Icons.inventory_2,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 160,
          maxColumns: 4,
          includeBottomSpacing: true,
          metrics: [
            PointyMetricGridItem(
              label: l10n.dashboardRetailStockValueMetric,
              value: formatMoney(summary.retailStockValue),
              icon: Icons.storefront_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardProductsMetric,
              value: _formatNumber(summary.productCount),
              icon: Icons.inventory_2_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardLowStockMetric,
              value: _formatNumber(summary.lowStockCount),
              icon: Icons.warning_amber,
              accentColor: summary.lowStockCount > 0 ? colors.warning : null,
            ),
            PointyMetricGridItem(
              label: l10n.dashboardOutOfStockMetric,
              value: _formatNumber(summary.outOfStockCount),
              icon: Icons.remove_shopping_cart_outlined,
              accentColor: summary.outOfStockCount > 0 ? colors.danger : null,
            ),
          ],
        ),
        PointyCardGrid(
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
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Purchasing & suppliers
// ---------------------------------------------------------------------------

class _PurchasingSection extends StatelessWidget {
  const _PurchasingSection({required this.section, required this.maxWidth});

  final DashboardPurchasingSection section;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final summary = section.summary;
    return _DashboardSection(
      title: l10n.dashboardPurchasingSectionTitle,
      icon: Icons.add_shopping_cart,
      children: [
        PointyMetricGrid(
          maxWidth: maxWidth,
          minTileWidth: 160,
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
              accentColor: summary.overdueOrderCount > 0 ? colors.danger : null,
            ),
          ],
        ),
        PointyCardGrid(
          children: [
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

// ---------------------------------------------------------------------------
// Daily operations: registers, payments, recent activity, devices
// ---------------------------------------------------------------------------

class _OperationsSection extends StatelessWidget {
  const _OperationsSection({
    required this.snapshot,
    required this.capabilities,
  });

  final DashboardSnapshot snapshot;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sections = snapshot.sections;
    final payments =
        sections.payments != null &&
            capabilities.allows(AppCapability.viewPaymentDashboard)
        ? sections.payments
        : null;
    final sales =
        sections.sales != null &&
            capabilities.allows(AppCapability.viewSalesDashboard)
        ? sections.sales
        : null;
    final discounts =
        sections.discounts != null &&
            capabilities.allows(AppCapability.viewDiscountDashboard)
        ? sections.discounts
        : null;
    final printing =
        sections.printing != null &&
            capabilities.allows(AppCapability.viewPrintingDashboard)
        ? sections.printing
        : null;

    final cards = <Widget>[
      if (payments != null)
        PointyDetailSection(
          title: l10n.dashboardPaymentMixTitle,
          icon: Icons.pie_chart_outline,
          minHeight: 300,
          child: _PaymentMixChart(methods: payments.methods),
        ),
      if (payments != null)
        PointyDetailSection(
          title: l10n.dashboardPaymentMethodsTitle,
          icon: Icons.list_alt,
          child: _PaymentMethodList(methods: payments.methods),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardRegistersTitle,
          icon: Icons.point_of_sale_outlined,
          child: _RegisterSummaryView(summary: sales.registers),
        ),
      if (sales != null)
        PointyDetailSection(
          title: l10n.dashboardRecentOrdersTitle,
          icon: Icons.history,
          child: _RecentOrdersList(orders: sales.recentOrders),
        ),
      if (discounts != null)
        PointyDetailSection(
          title: l10n.dashboardTopDiscountsTitle,
          icon: Icons.local_offer_outlined,
          child: _DiscountRuleList(rules: discounts.topRules),
        ),
      if (printing != null && printing.summary.failedCount > 0)
        PointyDetailSection(
          title: l10n.dashboardPrintFailuresTitle,
          icon: Icons.print_disabled_outlined,
          child: _PrintFailureList(failures: printing.recentFailures),
        ),
    ];

    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }

    return _DashboardSection(
      title: l10n.dashboardOperationsTitle,
      icon: Icons.storefront_outlined,
      children: [PointyCardGrid(children: cards)],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared section scaffold, charts, and lists
// ---------------------------------------------------------------------------

class _IntegritySection extends StatelessWidget {
  const _IntegritySection({required this.section, required this.onOpen});

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

    return _DashboardSection(
      title: l10n.dashboardIntegritySectionTitle,
      icon: Icons.verified_user_outlined,
      children: [
        Card(
          key: const ValueKey('dashboard_integrity_card'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: spacing.compactPadding,
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
                            : l10n.dashboardAlertFraudFindings(
                                summary.activeCount,
                              ),
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
          ),
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
              style: switch (Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)) {
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

String _discountChannelLabel(AppLocalizations l10n, String channel) {
  return switch (channel) {
    'sales' => l10n.discountChannelSales,
    'purchasing' => l10n.discountChannelPurchasing,
    'both' => l10n.discountChannelBoth,
    _ => channel,
  };
}
