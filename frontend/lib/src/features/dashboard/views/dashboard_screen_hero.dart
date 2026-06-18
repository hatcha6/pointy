part of 'dashboard_screen.dart';

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
