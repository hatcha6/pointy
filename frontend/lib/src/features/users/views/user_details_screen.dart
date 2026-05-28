import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/pos_user.dart';
import '../../../data/models/user_activity.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../purchasing/views/purchase_order_filter_sheet.dart';
import '../view_models/user_details_view_model.dart';

class UserDetailsScreen extends StatelessWidget {
  const UserDetailsScreen({super.key, required this.viewModel});

  final UserDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final user = viewModel.user;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.userDetailsTitle(user.label)),
            isLoading: viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.refreshUserDetailsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.loadActivity,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: viewModel.isLoading && viewModel.activity == null
              ? const PointyLoadingArea()
              : viewModel.hasError && viewModel.activity == null
              ? PointyErrorState(
                  title: l10n.userActivityLoadError,
                  icon: Icons.manage_accounts_outlined,
                  action: FilledButton.icon(
                    onPressed: viewModel.loadActivity,
                    icon: const Icon(Icons.sync),
                    label: Text(l10n.refreshUserDetailsTooltip),
                  ),
                )
              : _UserDetailsBody(
                  user: user,
                  activity: viewModel.activity,
                  isRefreshing: viewModel.isLoading,
                ),
        );
      },
    );
  }
}

class _UserDetailsBody extends StatelessWidget {
  const _UserDetailsBody({
    required this.user,
    required this.activity,
    required this.isRefreshing,
  });

  final PosUser user;
  final UserActivityOverview? activity;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final overview = activity;
    final spacing = AdaptiveSpacing.of(context);

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _UserHeader(user: user, isRefreshing: isRefreshing),
              SizedBox(height: spacing.md),
              if (overview == null)
                PointyDetailSection(
                  title: l10n.userDetailsOverviewTitle,
                  icon: Icons.insights_outlined,
                  child: Text(l10n.userActivityLoadError),
                )
              else ...[
                _OverviewSection(activity: overview),
                SizedBox(height: spacing.md),
                _RecentSalesSection(sales: overview.recentSales),
                SizedBox(height: spacing.md),
                _RecentPurchasesSection(
                  purchaseOrders: overview.recentPurchaseOrders,
                ),
                SizedBox(height: spacing.md),
                _RecentSessionsSection(
                  sessions: overview.recentRegisterSessions,
                ),
                SizedBox(height: spacing.md),
                _RecentActivitySection(events: overview.recentActivity),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UserHeader extends StatelessWidget {
  const _UserHeader({required this.user, required this.isRefreshing});

  final PosUser user;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: user.label,
      icon: user.role.isManager
          ? Icons.admin_panel_settings_outlined
          : Icons.point_of_sale_outlined,
      trailing: isRefreshing
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(user.username),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PointyStatusPill(
                label: _roleLabel(l10n, user.role),
                icon: user.role.isManager
                    ? Icons.admin_panel_settings_outlined
                    : Icons.point_of_sale_outlined,
              ),
              PointyStatusPill(
                label: user.isActive
                    ? l10n.userStatusActive
                    : l10n.userStatusInactive,
                icon: user.isActive
                    ? Icons.check_circle_outline
                    : Icons.pause_circle_outline,
                color: user.isActive
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.activity});

  final UserActivityOverview activity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final metrics = [
      _MetricData(
        icon: Icons.receipt_long_outlined,
        label: l10n.userActivityNetSalesMetric,
        value: formatMoney(activity.sales.netSales),
        detail: l10n.userActivityInvoicesDetail(
          activity.sales.invoiceCount,
          activity.sales.paidInvoiceCount,
        ),
      ),
      _MetricData(
        icon: Icons.people_alt_outlined,
        label: l10n.userActivityCustomersMetric,
        value: activity.sales.customerCount.toString(),
        detail: l10n.userActivityReturnsDetail(
          activity.sales.returnCount,
          formatMoney(activity.sales.returnTotal),
        ),
      ),
      _MetricData(
        icon: Icons.inventory_2_outlined,
        label: l10n.userActivityPurchaseTotalMetric,
        value: formatMoney(activity.purchasing.purchaseTotal),
        detail: l10n.userActivitySupplierInvoicesDetail(
          activity.purchasing.supplierInvoiceCount,
          activity.purchasing.purchaseOrderCount,
        ),
      ),
      _MetricData(
        icon: Icons.payments_outlined,
        label: l10n.userActivitySupplierPaymentsMetric,
        value: formatMoney(activity.supplierPayments.paymentTotal),
        detail: l10n.userActivitySupplierPaymentsDetail(
          activity.supplierPayments.paymentCount,
          activity.supplierPayments.refundCount,
        ),
      ),
      _MetricData(
        icon: Icons.point_of_sale_outlined,
        label: l10n.userActivityRegisterSessionsMetric,
        value: activity.registerSessions.sessionCount.toString(),
        detail: l10n.userActivityRegisterSessionsDetail(
          activity.registerSessions.openCount,
          activity.registerSessions.closedCount,
        ),
      ),
      _MetricData(
        icon: Icons.sync_alt_outlined,
        label: l10n.userActivityCashMovementsMetric,
        value: formatMoney(
          activity.cashMovements.payInTotal -
              activity.cashMovements.payOutTotal,
        ),
        detail: l10n.userActivityCashMovementsDetail(
          formatMoney(activity.cashMovements.payInTotal),
          formatMoney(activity.cashMovements.payOutTotal),
        ),
      ),
    ];

    return PointyDetailSection(
      title: l10n.userDetailsOverviewTitle,
      icon: Icons.insights_outlined,
      child: _MetricGrid(metrics: metrics),
    );
  }
}

class _RecentSalesSection extends StatelessWidget {
  const _RecentSalesSection({required this.sales});

  final List<UserRecentSale> sales;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.userDetailsRecentSalesTitle,
      icon: Icons.receipt_long_outlined,
      child: _EmptyAwareColumn(
        isEmpty: sales.isEmpty,
        emptyText: l10n.userActivityEmptyRecentSales,
        children: [
          for (final sale in sales)
            _ActivityTile(
              icon: Icons.receipt_outlined,
              title: sale.receiptNumber.isEmpty
                  ? l10n.userActivityReceiptFallback(sale.id)
                  : sale.receiptNumber,
              subtitle: _joinParts([
                _saleStatusLabel(l10n, sale.status),
                sale.customerName.isEmpty
                    ? l10n.customerEmptyValue
                    : sale.customerName,
                if (sale.registerSessionNumber.isNotEmpty)
                  sale.registerSessionNumber,
                if (sale.createdAt != null) formatDateTime(sale.createdAt!),
              ]),
              trailing: formatMoney(sale.total),
            ),
        ],
      ),
    );
  }
}

class _RecentPurchasesSection extends StatelessWidget {
  const _RecentPurchasesSection({required this.purchaseOrders});

  final List<UserRecentPurchaseOrder> purchaseOrders;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.userDetailsRecentPurchasesTitle,
      icon: Icons.inventory_2_outlined,
      child: _EmptyAwareColumn(
        isEmpty: purchaseOrders.isEmpty,
        emptyText: l10n.userActivityEmptyRecentPurchases,
        children: [
          for (final order in purchaseOrders)
            _ActivityTile(
              icon: Icons.inventory_2_outlined,
              title: order.orderNumber.isEmpty
                  ? l10n.userActivityPurchaseFallback(order.id)
                  : order.orderNumber,
              subtitle: _joinParts([
                purchaseOrderStatusLabel(l10n, order.status),
                order.supplierName,
                if (order.supplierInvoiceNumber.isNotEmpty)
                  l10n.supplierInvoiceNumberValue(order.supplierInvoiceNumber),
                if (order.createdAt != null) formatDateTime(order.createdAt!),
              ]),
              trailing: formatMoney(order.total),
            ),
        ],
      ),
    );
  }
}

class _RecentSessionsSection extends StatelessWidget {
  const _RecentSessionsSection({required this.sessions});

  final List<UserRecentRegisterSession> sessions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.userDetailsRecentSessionsTitle,
      icon: Icons.point_of_sale_outlined,
      child: _EmptyAwareColumn(
        isEmpty: sessions.isEmpty,
        emptyText: l10n.userActivityEmptyRecentSessions,
        children: [
          for (final session in sessions)
            _ActivityTile(
              icon: session.status == 'closed'
                  ? Icons.lock_outline
                  : Icons.lock_open_outlined,
              title: session.sessionNumber.isEmpty
                  ? l10n.userActivitySessionFallback(session.id)
                  : session.sessionNumber,
              subtitle: _joinParts([
                _registerSessionStatusLabel(l10n, session.status),
                if (session.openedAt != null) formatDateTime(session.openedAt!),
                l10n.registerSessionOpeningCash(
                  formatMoney(session.openingCash),
                ),
                if (session.hasCashVariance)
                  l10n.sessionVarianceFlag(
                    formatMoney(session.cashVariance ?? 0),
                  ),
              ]),
              trailing: session.closingCash == null
                  ? null
                  : formatMoney(session.closingCash!),
            ),
        ],
      ),
    );
  }
}

class _RecentActivitySection extends StatelessWidget {
  const _RecentActivitySection({required this.events});

  final List<UserActivityEvent> events;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.userDetailsRecentActivityTitle,
      icon: Icons.history_outlined,
      child: _EmptyAwareColumn(
        isEmpty: events.isEmpty,
        emptyText: l10n.userActivityEmptyRecentActivity,
        children: [
          for (final event in events)
            _ActivityTile(
              icon: _eventIcon(event.name),
              title: _eventLabel(l10n, event.name),
              subtitle: _joinParts([
                _eventTypeLabel(l10n, event.eventType),
                if (event.occurredAt != null) formatDateTime(event.occurredAt!),
              ]),
            ),
        ],
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<_MetricData> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 3
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        final spacing = AdaptiveSpacing.of(context).sm;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final metric in metrics)
              SizedBox(
                width: tileWidth,
                child: PointyMetricTile(
                  label: metric.label,
                  value: metric.value,
                  icon: metric.icon,
                  subtitle: metric.detail.isEmpty ? null : metric.detail,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricData {
  const _MetricData({
    required this.icon,
    required this.label,
    required this.value,
    this.detail = '',
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
}

class _EmptyAwareColumn extends StatelessWidget {
  const _EmptyAwareColumn({
    required this.isEmpty,
    required this.emptyText,
    required this.children,
  });

  final bool isEmpty;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      return PointyEmptyState(icon: Icons.inbox_outlined, title: emptyText);
    }

    return Column(
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const Divider(height: 1),
          child,
        ],
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return PointyDataRow(
      leading: Icon(icon),
      title: title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      padding: EdgeInsetsDirectional.zero,
      minHeight: 64,
      trailing: trailing == null
          ? null
          : Text(
              trailing!,
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.end,
            ),
    );
  }
}

String _roleLabel(AppLocalizations l10n, UserRole role) {
  return switch (role) {
    UserRole.manager => l10n.managerRoleLabel,
    UserRole.cashier => l10n.cashierRoleLabel,
  };
}

String _saleStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'paid' => l10n.saleOrderStatusPaid,
    'void' => l10n.saleOrderStatusVoid,
    'open' => l10n.saleOrderStatusOpen,
    _ => l10n.saleOrderStatusOpen,
  };
}

String _registerSessionStatusLabel(AppLocalizations l10n, String status) {
  return status == 'closed'
      ? l10n.registerSessionStatusClosed
      : l10n.registerSessionStatusOpen;
}

String _eventLabel(AppLocalizations l10n, String name) {
  return switch (name) {
    'auth.login.succeeded' => l10n.userActivityEventLogin,
    'sales.register_session.started' => l10n.userActivityEventRegisterStarted,
    'sales.register_session.closed' => l10n.userActivityEventRegisterClosed,
    'sales.register_cash_movement.created' =>
      l10n.userActivityEventCashMovement,
    'users.user.created' => l10n.userActivityEventUserCreated,
    'users.user.updated' => l10n.userActivityEventUserUpdated,
    'users.user.deleted' => l10n.userActivityEventUserDeleted,
    _ => l10n.userActivityEventFallback,
  };
}

String _eventTypeLabel(AppLocalizations l10n, String eventType) {
  return switch (eventType) {
    'security' => l10n.userActivityEventTypeSecurity,
    'audit' => l10n.userActivityEventTypeAudit,
    'error' => l10n.userActivityEventTypeError,
    'performance' => l10n.userActivityEventTypePerformance,
    _ => l10n.userActivityEventTypeUsage,
  };
}

IconData _eventIcon(String name) {
  return switch (name) {
    'auth.login.succeeded' => Icons.login_outlined,
    'sales.register_session.started' => Icons.lock_open_outlined,
    'sales.register_session.closed' => Icons.lock_outline,
    'sales.register_cash_movement.created' => Icons.sync_alt_outlined,
    'users.user.created' ||
    'users.user.updated' ||
    'users.user.deleted' => Icons.manage_accounts_outlined,
    _ => Icons.history_outlined,
  };
}

String _joinParts(List<String> parts) {
  return parts.where((part) => part.trim().isNotEmpty).join(' • ');
}
