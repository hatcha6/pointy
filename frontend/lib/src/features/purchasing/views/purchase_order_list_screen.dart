import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/catalog/pointy_category_strip.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../ai/views/smart_reorder_action.dart';
import '../view_models/purchase_order_list_view_model.dart';
import 'purchase_order_filter_sheet.dart';
import 'purchase_order_query_controls.dart';

class PurchaseOrderListScreen extends StatelessWidget {
  const PurchaseOrderListScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    required this.navigation,
    required this.onCreatePurchaseOrder,
    required this.onOpenPurchaseOrder,
    required this.onEditPurchaseOrder,
  });

  final PurchaseOrderListViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final VoidCallback onCreatePurchaseOrder;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;
  final ValueChanged<PurchaseOrder> onEditPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.purchasing,
            navigation: navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.purchaseOrdersTitle),
            actions: [
              SmartReorderAction(
                navigation: navigation,
                capabilities: capabilities,
                from: AppNavigationDestination.purchasing,
              ),
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
          floatingActionButton: capabilities.canCreatePurchaseOrder
              ? FloatingActionButton.extended(
                  onPressed: onCreatePurchaseOrder,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.newPurchaseOrderButton),
                )
              : null,
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.accessPurchasing,
            child: _PurchaseOrderListBody(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
              onCreatePurchaseOrder: onCreatePurchaseOrder,
              onOpenPurchaseOrder: onOpenPurchaseOrder,
              onEditPurchaseOrder: onEditPurchaseOrder,
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
    required this.onEditPurchaseOrder,
  });

  final PurchaseOrderListViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreatePurchaseOrder;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;
  final ValueChanged<PurchaseOrder> onEditPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PayablesStrip(
            viewModel: viewModel,
            onOpenPurchaseOrder: onOpenPurchaseOrder,
          ),
          PurchaseOrderQueryControls(
            query: viewModel.query,
            contactRepository: contactRepository,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
            enabled: !viewModel.isLoading,
          ),
          SizedBox(height: spacing.sm),
          _StatusFilterStrip(
            query: viewModel.query,
            onApply: viewModel.applyQuery,
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
                action: capabilities.canCreatePurchaseOrder
                    ? FilledButton.icon(
                        onPressed: onCreatePurchaseOrder,
                        icon: const Icon(Icons.add),
                        label: Text(l10n.newPurchaseOrderButton),
                      )
                    : null,
              ),
              itemBuilder: (context, order) {
                // Drafts always; submitted orders until the first receipt
                // (which flips the status) or payment — same rule as the
                // details screen and the backend.
                final canEdit =
                    capabilities.canEditDraftPurchaseOrder &&
                    (order.status == 'draft' ||
                        (order.status == 'submitted' &&
                            order.paymentStatus == 'unpaid'));
                return PurchaseOrderTile(
                  order: order,
                  onTap: () => onOpenPurchaseOrder(order),
                  onPrint: () => _printOrder(context, order),
                  onShare: () => _shareOrder(context, order),
                  onEdit: canEdit ? () => onEditPurchaseOrder(order) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _printOrder(BuildContext context, PurchaseOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final didPrint = await viewModel.printOrder(order);
    if (!context.mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            didPrint
                ? l10n.purchaseOrderPrintSuccess(
                    order.orderNumber.isEmpty
                        ? l10n.purchaseOrderFallbackTitle(order.id)
                        : order.orderNumber,
                  )
                : l10n.purchaseOrderPrintError,
          ),
        ),
      );
  }

  Future<void> _shareOrder(BuildContext context, PurchaseOrder order) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final status = await viewModel.shareOrder(order);
    if (!context.mounted || status == OrderDocumentActionStatus.canceled) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            status == OrderDocumentActionStatus.completed
                ? l10n.purchaseOrderShareSuccess(
                    order.orderNumber.isEmpty
                        ? l10n.purchaseOrderFallbackTitle(order.id)
                        : order.orderNumber,
                  )
                : l10n.purchaseOrderShareError,
          ),
        ),
      );
  }
}

/// One-tap status filter chips above the list — the common filter without
/// opening the full filter sheet.
class _StatusFilterStrip extends StatelessWidget {
  const _StatusFilterStrip({required this.query, required this.onApply});

  final PurchaseOrderQuery query;
  final ValueChanged<PurchaseOrderQuery> onApply;

  static const _statuses = [
    PurchaseOrderStatusFilter.draft,
    PurchaseOrderStatusFilter.submitted,
    PurchaseOrderStatusFilter.received,
    PurchaseOrderStatusFilter.cancelled,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyCategoryStrip<PurchaseOrderStatusFilter>(
      allLabel: l10n.purchaseOrderStatusAll,
      items: [
        for (final status in _statuses)
          PointyCategoryStripItem(
            value: status,
            label: purchaseOrderStatusFilterLabel(l10n, status),
          ),
      ],
      selectedValues: query.status == PurchaseOrderStatusFilter.all
          ? const {}
          : {query.status},
      onSelectAll: () =>
          onApply(query.copyWith(status: PurchaseOrderStatusFilter.all)),
      onSelected: (status) => onApply(query.copyWith(status: status)),
    );
  }
}

/// "Supplier dues" — the redesigned outstanding (received-but-unpaid) summary.
///
/// A single amber-tinted card with the total owed up top and a *horizontal*
/// carousel of payable cards below, each tappable to open the order and pay.
/// Replaces the old sunken box that nested a vertical scroll inside the page.
class _PayablesStrip extends StatefulWidget {
  const _PayablesStrip({
    required this.viewModel,
    required this.onOpenPurchaseOrder,
  });

  final PurchaseOrderListViewModel viewModel;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;

  @override
  State<_PayablesStrip> createState() => _PayablesStripState();
}

class _PayablesStripState extends State<_PayablesStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      widget.viewModel.loadMoreOutstandingReceivedNotPaid();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final viewModel = widget.viewModel;
    final orders = viewModel.outstandingReceivedNotPaid;

    // Stay out of the way until there's something worth showing.
    if (orders.isEmpty) {
      if (viewModel.hasOutstandingError) {
        return Padding(
          padding: EdgeInsetsDirectional.only(bottom: spacing.md),
          child: PointyInlineMessage.warning(
            message: l10n.outstandingPurchasesLoadError,
            compact: true,
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.md),
      child: _card(context, orders),
    );
  }

  Widget _card(BuildContext context, List<PurchaseOrder> orders) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final total = orders.fold<double>(0, (sum, o) => sum + o.balanceDue);
    final totalStyle = textTheme.titleLarge?.copyWith(
      color: colors.warning,
      fontWeight: FontWeight.w800,
    );

    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.warning.withOpacity(0.06),
          colors.surface,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.warning.withOpacity(0.22)),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.warning.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.account_balance_wallet_outlined,
                  color: colors.warning,
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.purchasePayablesTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.viewModel.hasMoreOutstanding
                          ? '${l10n.purchasePayablesCount(orders.length)} ${l10n.purchasePayablesMore}'
                          : l10n.purchasePayablesCount(orders.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              Text(
                formatMoney(total),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: totalStyle == null
                    ? null
                    : PointyTypography.numeric(totalStyle),
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          SizedBox(
            height: 96,
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount:
                  orders.length + (widget.viewModel.hasMoreOutstanding ? 1 : 0),
              separatorBuilder: (_, __) => SizedBox(width: spacing.sm),
              itemBuilder: (context, index) {
                if (index >= orders.length) {
                  return const _PayableLoadingCard();
                }
                final order = orders[index];
                return _PayableCard(
                  order: order,
                  onTap: () => widget.onOpenPurchaseOrder(order),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PayableCard extends StatelessWidget {
  const _PayableCard({required this.order, required this.onTap});

  final PurchaseOrder order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final accent = order.isOverdue ? colors.danger : colors.warning;
    final supplier = order.supplierName?.trim() ?? '';

    return SizedBox(
      width: 212,
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PointyRadii.card),
              border: Border.all(color: colors.line),
            ),
            child: Padding(
              padding: EdgeInsets.all(spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          order.orderNumber.isEmpty
                              ? l10n.purchaseOrderFallbackTitle(order.id)
                              : order.orderNumber,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge?.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (order.isOverdue)
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: colors.danger,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    supplier.isEmpty ? '—' : supplier,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                  ),
                  const Spacer(),
                  Text(
                    l10n.purchaseOutstandingAmountValue(
                      formatMoney(order.balanceDue),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: switch (textTheme.titleSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w800,
                    )) {
                      final style? => PointyTypography.numeric(style),
                      null => null,
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PayableLoadingCard extends StatelessWidget {
  const _PayableLoadingCard();

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return SizedBox(
      width: 96,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PointyRadii.card),
          border: Border.all(color: colors.line),
        ),
        child: const Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

class PurchaseOrderTile extends StatelessWidget {
  const PurchaseOrderTile({
    super.key,
    required this.order,
    this.onTap,
    this.onPrint,
    this.onShare,
    this.onEdit,
  });

  final PurchaseOrder order;
  final VoidCallback? onTap;
  final VoidCallback? onPrint;
  final VoidCallback? onShare;

  /// Reopen this (draft) order in the purchasing screen to edit it. Null for
  /// non-draft orders or without edit permission.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final title = order.orderNumber.isEmpty
        ? l10n.purchaseOrderFallbackTitle(order.id)
        : order.orderNumber;
    final submittedAt = order.submittedAt;
    final receivedAt = order.receivedAt;
    final date = receivedAt ?? submittedAt ?? order.createdAt;
    final owing = order.balanceDue > 0;

    return PointyDataRow(
      leading: Icon(_statusIcon(order.status), color: colors.primaryStrong),
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
          color: _statusColor(colors, order.status),
        ),
        if (order.isOverdue)
          PointyStatusPill(
            label: l10n.purchaseOrderOverdueValue,
            icon: Icons.warning_amber_rounded,
            color: colors.danger,
          ),
      ],
      actions: [
        if (onPrint != null || onShare != null || onEdit != null)
          PopupMenuButton<_PurchaseOrderRowAction>(
            tooltip: l10n.purchaseOrderRowActionsTooltip,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              switch (action) {
                case _PurchaseOrderRowAction.edit:
                  onEdit?.call();
                case _PurchaseOrderRowAction.print:
                  onPrint?.call();
                case _PurchaseOrderRowAction.share:
                  onShare?.call();
              }
            },
            itemBuilder: (context) => [
              if (onEdit != null)
                PopupMenuItem<_PurchaseOrderRowAction>(
                  value: _PurchaseOrderRowAction.edit,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(l10n.editPurchaseOrderAction),
                  ),
                ),
              if (onPrint != null)
                PopupMenuItem<_PurchaseOrderRowAction>(
                  value: _PurchaseOrderRowAction.print,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.print_outlined),
                    title: Text(l10n.purchaseOrderPrintAction),
                  ),
                ),
              if (onShare != null)
                PopupMenuItem<_PurchaseOrderRowAction>(
                  value: _PurchaseOrderRowAction.share,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.ios_share_outlined),
                    title: Text(l10n.purchaseOrderShareAction),
                  ),
                ),
            ],
          ),
      ],
      trailing: Text(
        owing ? formatMoney(order.balanceDue) : formatMoney(order.total),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: owing ? colors.warning : colors.ink,
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
      'partial' || 'partially_received' => Icons.inventory_2_outlined,
      'received' => Icons.inventory_outlined,
      'cancelled' => Icons.cancel_outlined,
      _ => Icons.receipt_long_outlined,
    };
  }
}

Color _statusColor(PointySemanticColors colors, String status) {
  return switch (status) {
    'draft' => colors.mutedInk,
    'submitted' => colors.primaryStrong,
    'partial' || 'partially_received' => colors.warning,
    'received' => colors.success,
    'cancelled' => colors.danger,
    _ => colors.mutedInk,
  };
}

enum _PurchaseOrderRowAction { edit, print, share }

String _paymentStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'partial' => l10n.purchasePaymentStatusPartial,
    'paid' => l10n.purchasePaymentStatusPaid,
    'credit' => l10n.purchasePaymentStatusCredit,
    _ => l10n.purchasePaymentStatusUnpaid,
  };
}
