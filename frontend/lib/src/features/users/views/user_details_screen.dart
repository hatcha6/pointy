import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/user_activity.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../purchasing/views/purchase_order_filter_sheet.dart';
import '../role_presentation.dart';
import '../view_models/user_details_view_model.dart';

class UserDetailsScreen extends StatelessWidget {
  const UserDetailsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.onManagePermissions,
  });

  final UserDetailsViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// Opens the permission editor for the given user; resolves true if it saved,
  /// in which case the detail view refreshes.
  final Future<bool> Function(PosUser user) onManagePermissions;

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
                  capabilities: capabilities,
                  onManagePermissions: () async {
                    final changed = await onManagePermissions(viewModel.user);
                    if (changed) {
                      await viewModel.loadActivity();
                    }
                  },
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
    required this.capabilities,
    required this.onManagePermissions,
  });

  final PosUser user;
  final UserActivityOverview? activity;
  final bool isRefreshing;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onManagePermissions;

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
              _PermissionsSection(
                user: user,
                canManage: capabilities.canManageUsers,
                onManagePermissions: onManagePermissions,
              ),
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
                _CreditSalesSection(
                  sales: overview.recentCreditSales,
                  summary: overview.sales,
                ),
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
    final presentation = rolePresentationFor(context, user.role);
    return PointyDetailSection(
      title: user.label,
      icon: presentation.icon,
      trailing: isRefreshing
          ? const SizedBox.square(
              dimension: 20,
              child: PointySpinner(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('@${user.username}'),
          if (user.email.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              user.email.trim(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PointyStatusPill(
                label: presentation.label,
                icon: presentation.icon,
                color: presentation.color,
              ),
              PointyStatusPill(
                label: user.isActive
                    ? l10n.userStatusActive
                    : l10n.userStatusInactive,
                icon: user.isActive
                    ? Icons.check_circle_outline
                    : Icons.pause_circle_outline,
                color: user.isActive
                    ? context.pointyColors.primaryStrong
                    : context.pointyColors.danger,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermissionsSection extends StatelessWidget {
  const _PermissionsSection({
    required this.user,
    required this.canManage,
    required this.onManagePermissions,
  });

  final PosUser user;
  final bool canManage;
  final VoidCallback onManagePermissions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final isManager = user.role.isManager;
    final inheritedCount = isManager
        ? null
        : user.rolePermissions.where((code) => code != '*').length;

    return PointyDetailSection(
      title: l10n.userPermissionsSectionTitle,
      icon: Icons.verified_user_outlined,
      trailing: canManage
          ? TextButton.icon(
              onPressed: onManagePermissions,
              icon: const Icon(Icons.tune, size: 18),
              label: Text(l10n.userEditPermissionsAction),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isManager)
            Text(l10n.permissionsManagerHasAll)
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PointyStatusPill(
                  label: l10n.userPermissionsInheritedCount(
                    inheritedCount ?? 0,
                  ),
                  icon: Icons.lock_outline,
                  color: colors.mutedInk,
                ),
                PointyStatusPill(
                  label: l10n.userPermissionsExtraCount(
                    user.extraPermissionCount,
                  ),
                  icon: Icons.tune,
                  color: user.hasExtraPermissions
                      ? colors.accentAmber
                      : colors.mutedInk,
                ),
              ],
            ),
            if (!user.hasExtraPermissions) ...[
              const SizedBox(height: 8),
              Text(
                l10n.userPermissionsNoExtras,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ],
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
      PointyMetricGridItem(
        icon: Icons.receipt_long_outlined,
        label: l10n.userActivityNetSalesMetric,
        value: formatMoney(activity.sales.netSales),
        subtitle: l10n.userActivityInvoicesDetail(
          activity.sales.invoiceCount,
          activity.sales.paidInvoiceCount,
        ),
      ),
      PointyMetricGridItem(
        icon: Icons.people_alt_outlined,
        label: l10n.userActivityCustomersMetric,
        value: activity.sales.customerCount.toString(),
        subtitle: l10n.userActivityReturnsDetail(
          activity.sales.returnCount,
          formatMoney(activity.sales.returnTotal),
        ),
      ),
      PointyMetricGridItem(
        icon: Icons.inventory_2_outlined,
        label: l10n.userActivityPurchaseTotalMetric,
        value: formatMoney(activity.purchasing.purchaseTotal),
        subtitle: l10n.userActivitySupplierInvoicesDetail(
          activity.purchasing.supplierInvoiceCount,
          activity.purchasing.purchaseOrderCount,
        ),
      ),
      PointyMetricGridItem(
        icon: Icons.payments_outlined,
        label: l10n.userActivitySupplierPaymentsMetric,
        value: formatMoney(activity.supplierPayments.paymentTotal),
        subtitle: l10n.userActivitySupplierPaymentsDetail(
          activity.supplierPayments.paymentCount,
          activity.supplierPayments.refundCount,
        ),
      ),
      PointyMetricGridItem(
        icon: Icons.point_of_sale_outlined,
        label: l10n.userActivityRegisterSessionsMetric,
        value: activity.registerSessions.sessionCount.toString(),
        subtitle: l10n.userActivityRegisterSessionsDetail(
          activity.registerSessions.openCount,
          activity.registerSessions.closedCount,
        ),
      ),
      PointyMetricGridItem(
        icon: Icons.sync_alt_outlined,
        label: l10n.userActivityCashMovementsMetric,
        value: formatMoney(
          activity.cashMovements.payInTotal -
              activity.cashMovements.payOutTotal,
        ),
        subtitle: l10n.userActivityCashMovementsDetail(
          formatMoney(activity.cashMovements.payInTotal),
          formatMoney(activity.cashMovements.payOutTotal),
        ),
      ),
    ];

    return PointyDetailSection(
      title: l10n.userDetailsOverviewTitle,
      icon: Icons.insights_outlined,
      child: PointyMetricGrid(
        metrics: metrics,
        gap: PointyMetricGridGap.compact,
      ),
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

/// The آجل invoices this person issued, apart from their cash sales.
///
/// A debt is not a settled sale, and picking آجل rows out of a run of cash
/// invoices by eye was the only way to answer "what has this cashier left on
/// tab?". Each row leads with what is still owed rather than the invoice total,
/// because that is the number being looked for; the section carries the full
/// count and outstanding total, since the list itself is capped like every
/// other on this screen and must not read as the whole story.
class _CreditSalesSection extends StatelessWidget {
  const _CreditSalesSection({required this.sales, required this.summary});

  final List<UserRecentSale> sales;
  final UserSalesActivitySummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return PointyDetailSection(
      title: l10n.userDetailsCreditSalesTitle,
      icon: Icons.schedule_send_outlined,
      child: _EmptyAwareColumn(
        isEmpty: sales.isEmpty,
        emptyText: l10n.userActivityEmptyCreditSales,
        children: [
          if (summary.creditInvoiceCount > 0) ...[
            Text(
              l10n.userCreditOutstandingSummary(
                summary.creditInvoiceCount,
                formatMoney(summary.creditOutstandingTotal),
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: summary.creditOutstandingTotal > 0
                    ? colors.warning
                    : colors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final sale in sales)
            _ActivityTile(
              icon: sale.isOverdue
                  ? Icons.warning_amber_rounded
                  : Icons.schedule_outlined,
              title: sale.receiptNumber.isEmpty
                  ? l10n.userActivityReceiptFallback(sale.id)
                  : sale.receiptNumber,
              subtitle: _joinParts([
                sale.customerName.isEmpty
                    ? l10n.customerEmptyValue
                    : sale.customerName,
                if (sale.isOverdue)
                  l10n.invoiceOverdueShortBadge
                else if (sale.dueDate != null)
                  l10n.invoiceDueOnLabel(formatDate(sale.dueDate!)),
                if (sale.createdAt != null) formatDateTime(sale.createdAt!),
              ]),
              trailing: sale.balanceDue > 0
                  ? l10n.userCreditRemainingValue(formatMoney(sale.balanceDue))
                  : formatMoney(sale.total),
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
