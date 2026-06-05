import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/purchase_order_list_view_model.dart';
import 'purchase_order_filter_sheet.dart';
import 'purchase_order_query_controls.dart';

class PurchaseOrderListScreen extends StatelessWidget {
  const PurchaseOrderListScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onCreatePurchaseOrder,
    required this.onOpenPurchaseOrder,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final PurchaseOrderListViewModel viewModel;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreatePurchaseOrder;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
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
            selectedDestination: AppNavigationDestination.purchasing,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: () {},
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.purchaseOrdersTitle),
            actions: [
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.accessPurchasing,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshPurchaseOrdersTooltip,
                  onPressed: viewModel.loadOrders,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.accessPurchasing,
            child: _PurchaseOrderListBody(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
              onCreatePurchaseOrder: onCreatePurchaseOrder,
              onOpenPurchaseOrder: onOpenPurchaseOrder,
            ),
          ),
        );
      },
    );
  }
}

class _PurchaseOrderListBody extends StatelessWidget {
  const _PurchaseOrderListBody({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    required this.onCreatePurchaseOrder,
    required this.onOpenPurchaseOrder,
  });

  final PurchaseOrderListViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreatePurchaseOrder;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveActionBar(
            alignment: WrapAlignment.start,
            actions: [
              if (capabilities.canCreatePurchaseOrder)
                FilledButton.icon(
                  onPressed: onCreatePurchaseOrder,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.newPurchaseOrderButton),
                ),
            ],
          ),
          SizedBox(height: spacing.sm),
          _OutstandingPurchasesSection(
            viewModel: viewModel,
            onOpenPurchaseOrder: onOpenPurchaseOrder,
          ),
          SizedBox(height: spacing.sm),
          PurchaseOrderQueryControls(
            query: viewModel.query,
            contactRepository: contactRepository,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
            enabled: !viewModel.isLoading,
          ),
          SizedBox(height: spacing.md),
          Expanded(
            child: PointyDataList<PurchaseOrder>(
              items: viewModel.orders,
              onLoadMore: viewModel.loadMoreOrders,
              hasMore: viewModel.hasMoreOrders,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              hasError: viewModel.hasLoadError,
              errorBuilder: (context) => PointyErrorState(
                title: l10n.purchaseOrdersLoadError,
                icon: Icons.receipt_long_outlined,
              ),
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.receipt_long_outlined,
                title: l10n.emptyPurchaseOrders,
              ),
              itemBuilder: (context, order) {
                return PurchaseOrderTile(
                  order: order,
                  onTap: () => onOpenPurchaseOrder(order),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OutstandingPurchasesSection extends StatelessWidget {
  const _OutstandingPurchasesSection({
    required this.viewModel,
    required this.onOpenPurchaseOrder,
  });

  final PurchaseOrderListViewModel viewModel;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orders = viewModel.outstandingReceivedNotPaid;

    if (viewModel.isLoadingOutstanding) {
      return const LinearProgressIndicator();
    }
    if (viewModel.hasOutstandingError && orders.isEmpty) {
      return Text(
        l10n.outstandingPurchasesLoadError,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    if (orders.isEmpty) {
      return const SizedBox.shrink();
    }

    final totalBalance = orders.fold<double>(
      0,
      (total, order) => total + order.balanceDue,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.outstandingPurchasesTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  viewModel.hasMoreOutstanding
                      ? l10n.outstandingPurchasesLoadedSummary(
                          orders.length,
                          formatMoney(totalBalance),
                        )
                      : l10n.outstandingPurchasesSummary(
                          orders.length,
                          formatMoney(totalBalance),
                        ),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: _outstandingListHeight(
                orders.length,
                viewModel.hasMoreOutstanding,
              ),
              child: InfiniteScrollList<PurchaseOrder>(
                items: orders,
                onLoadMore: viewModel.loadMoreOutstandingReceivedNotPaid,
                hasMore: viewModel.hasMoreOutstanding,
                isLoadingInitial: viewModel.isLoadingOutstanding,
                isLoadingMore: viewModel.isLoadingMoreOutstanding,
                emptyBuilder: (context) => const SizedBox.shrink(),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, order) {
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      order.orderNumber.isEmpty
                          ? l10n.purchaseOrderFallbackTitle(order.id)
                          : order.orderNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (order.supplierName != null &&
                            order.supplierName!.isNotEmpty)
                          order.supplierName!,
                        if (order.receivedAt != null)
                          formatDateTime(order.receivedAt!),
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(formatMoney(order.balanceDue)),
                    onTap: () => onOpenPurchaseOrder(order),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _outstandingListHeight(int orderCount, bool hasMore) {
    if (hasMore || orderCount > 3) {
      return 216;
    }
    if (orderCount == 1) {
      return 64;
    }
    if (orderCount == 2) {
      return 128;
    }
    return 192;
  }
}

class PurchaseOrderTile extends StatelessWidget {
  const PurchaseOrderTile({super.key, required this.order, this.onTap});

  final PurchaseOrder order;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final title = order.orderNumber.isEmpty
        ? l10n.purchaseOrderFallbackTitle(order.id)
        : order.orderNumber;
    final submittedAt = order.submittedAt;
    final receivedAt = order.receivedAt;
    final date = receivedAt ?? submittedAt ?? order.createdAt;

    return PointyDataRow(
      leading: Icon(_statusIcon(order.status), color: colorScheme.primary),
      title: l10n.purchaseOrderNumberValue(title),
      subtitle: [
        if (order.supplierInvoiceNumber.isNotEmpty)
          l10n.supplierInvoiceNumberValue(order.supplierInvoiceNumber),
        if (order.supplierInvoiceDate != null)
          l10n.supplierInvoiceDateValue(formatDate(order.supplierInvoiceDate!)),
        if (order.paymentStatus.isNotEmpty)
          _paymentStatusLabel(l10n, order.paymentStatus),
        l10n.lineItemCount(order.lineCount),
        if (date != null) formatDateTime(date),
        if (order.dueDate != null)
          l10n.purchaseOrderDueDateValue(formatDate(order.dueDate!)),
        if (order.supplierName != null && order.supplierName!.isNotEmpty)
          order.supplierName!,
      ].join(' • '),
      badges: [
        PointyStatusPill(
          label: purchaseOrderStatusLabel(l10n, order.status),
          icon: _statusIcon(order.status),
        ),
      ],
      trailing: Text(
        order.balanceDue > 0
            ? formatMoney(order.balanceDue)
            : formatMoney(order.total),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w800,
        ),
      ),
      onTap: onTap,
    );
  }

  IconData _statusIcon(String status) {
    return switch (status) {
      'draft' => Icons.edit_note_outlined,
      'submitted' => Icons.send_outlined,
      'received' => Icons.inventory_outlined,
      'cancelled' => Icons.cancel_outlined,
      _ => Icons.receipt_long_outlined,
    };
  }
}

String _paymentStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'partial' => l10n.purchasePaymentStatusPartial,
    'paid' => l10n.purchasePaymentStatusPaid,
    'credit' => l10n.purchasePaymentStatusCredit,
    _ => l10n.purchasePaymentStatusUnpaid,
  };
}
