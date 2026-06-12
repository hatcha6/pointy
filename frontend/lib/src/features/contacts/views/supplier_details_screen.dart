import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../purchasing/views/purchase_order_details_screen.dart';
import '../../purchasing/views/purchase_order_filter_sheet.dart';
import '../view_models/supplier_details_view_model.dart';

class SupplierDetailsScreen extends StatefulWidget {
  const SupplierDetailsScreen({
    super.key,
    required this.supplier,
    required this.contactRepository,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final SupplierContact supplier;
  final ContactRepository contactRepository;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<SupplierDetailsScreen> createState() => _SupplierDetailsScreenState();
}

class _SupplierDetailsScreenState extends State<SupplierDetailsScreen> {
  late final SupplierDetailsViewModel _viewModel = SupplierDetailsViewModel(
    contactRepository: widget.contactRepository,
    purchaseRepository: widget.purchaseRepository,
    initialSupplier: widget.supplier,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final supplier = _viewModel.supplier;
        return Scaffold(
          appBar: AppBar(
            title: Text(supplier.name),
            actions: [
              IconButton(
                tooltip: l10n.refreshSupplierDetailsTooltip,
                onPressed: _viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: SupplierDetailsView(
              viewModel: _viewModel,
              purchaseRepository: widget.purchaseRepository,
              printingRepository: widget.printingRepository,
              shopSettingsRepository: widget.shopSettingsRepository,
              capabilities: widget.capabilities,
            ),
          ),
        );
      },
    );
  }
}

/// Embeddable supplier details body: used by [SupplierDetailsScreen] as a
/// pushed route on compact widths, and by the contacts master-detail pane on
/// desktop.
class SupplierDetailsView extends StatelessWidget {
  const SupplierDetailsView({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final SupplierDetailsViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final supplier = viewModel.supplier;
        return AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SupplierHeader(supplier: supplier),
              const SizedBox(height: 12),
              PointyDetailSection(
                title: l10n.supplierPurchaseSummaryTitle,
                icon: Icons.summarize_outlined,
                child: _SupplierTotals(viewModel: viewModel),
              ),
              const SizedBox(height: 12),
              PointyDetailSection(
                title: l10n.supplierPurchaseHistoryTitle,
                icon: Icons.receipt_long_outlined,
                child: _SupplierPurchaseHistory(
                  viewModel: viewModel,
                  onOpenPurchaseOrder: (order) =>
                      _openPurchaseOrder(context, order),
                ),
              ),
              const SizedBox(height: 12),
              PointyDetailSection(
                title: l10n.supplierReturnRefundHistoryTitle,
                icon: Icons.keyboard_return_outlined,
                child: _SupplierAdjustmentHistory(viewModel: viewModel),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openPurchaseOrder(BuildContext context, PurchaseOrder order) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PurchaseOrderDetailsScreen(
          purchaseRepository: purchaseRepository,
          printingRepository: printingRepository,
          shopSettingsRepository: shopSettingsRepository,
          initialOrder: order,
          capabilities: capabilities,
        ),
      ),
    );
  }
}

class _SupplierHeader extends StatelessWidget {
  const _SupplierHeader({required this.supplier});

  final SupplierContact supplier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  color: colorScheme.onPrimary,
                  size: 34,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    supplier.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              [
                if (supplier.contactName.isNotEmpty)
                  l10n.supplierContactValue(supplier.contactName),
                if (supplier.phone.isNotEmpty) supplier.phone,
                if (supplier.email.isNotEmpty) supplier.email,
                if (!supplier.isActive) l10n.inactiveContactLabel,
              ].join(' • '),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colorScheme.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplierTotals extends StatelessWidget {
  const _SupplierTotals({required this.viewModel});

  final SupplierDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final supplier = viewModel.supplier;

    return Column(
      children: [
        if (viewModel.hasSupplierError)
          _ErrorText(text: l10n.supplierDetailsLoadError),
        PointyDetailRow(
          label: l10n.supplierTotalBoughtLabel,
          value: formatMoney(supplier.totalBought),
        ),
        const Divider(height: 20),
        PointyDetailRow(
          label: l10n.supplierPurchaseCountLabel,
          value: l10n.supplierPurchaseCountValue(supplier.purchaseCount),
        ),
        const Divider(height: 20),
        PointyDetailRow(
          label: l10n.purchaseOrderBalanceDueLabel,
          value: formatMoney(supplier.payableBalance),
        ),
        if (supplier.creditBalance > 0) ...[
          const Divider(height: 20),
          PointyDetailRow(
            label: l10n.purchaseOrderCreditAppliedLabel,
            value: formatMoney(supplier.creditBalance),
          ),
        ],
      ],
    );
  }
}

class _SupplierPurchaseHistory extends StatelessWidget {
  const _SupplierPurchaseHistory({
    required this.viewModel,
    required this.onOpenPurchaseOrder,
  });

  final SupplierDetailsViewModel viewModel;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingHistory && viewModel.purchaseHistory.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasHistoryError && viewModel.purchaseHistory.isEmpty) {
      return _ErrorText(text: l10n.supplierPurchaseHistoryLoadError);
    }
    if (viewModel.purchaseHistory.isEmpty) {
      return Text(l10n.supplierPurchaseHistoryEmpty);
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.purchaseHistory.length,
        viewModel.hasMorePurchaseHistory,
      ),
      child: PointyDataList<PurchaseOrder>(
        items: viewModel.purchaseHistory,
        onLoadMore: viewModel.loadMorePurchaseHistory,
        hasMore: viewModel.hasMorePurchaseHistory,
        isLoadingInitial: viewModel.isLoadingHistory,
        isLoadingMore: viewModel.isLoadingMoreHistory,
        emptyBuilder: (context) => Text(l10n.supplierPurchaseHistoryEmpty),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, order) {
          return PointyDataRow(
            leading: const Icon(Icons.receipt_long_outlined),
            title: order.orderNumber.isEmpty
                ? l10n.purchaseOrderFallbackTitle(order.id)
                : order.orderNumber,
            subtitle: [
              purchaseOrderStatusLabel(l10n, order.status),
              l10n.lineItemCount(order.lineCount),
              if (order.receivedAt != null) formatDateTime(order.receivedAt!),
              if (order.balanceDue > 0)
                l10n.purchaseOutstandingAmountValue(
                  formatMoney(order.balanceDue),
                ),
            ].join(' • '),
            trailing: Text(formatMoney(order.total)),
            onTap: () => onOpenPurchaseOrder(order),
          );
        },
      ),
    );
  }
}

class _SupplierAdjustmentHistory extends StatelessWidget {
  const _SupplierAdjustmentHistory({required this.viewModel});

  final SupplierDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingAdjustments && viewModel.adjustmentHistory.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasAdjustmentError && viewModel.adjustmentHistory.isEmpty) {
      return _ErrorText(text: l10n.supplierReturnRefundHistoryLoadError);
    }
    if (viewModel.adjustmentHistory.isEmpty) {
      return Text(l10n.supplierReturnRefundHistoryEmpty);
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.adjustmentHistory.length,
        viewModel.hasMoreAdjustments,
      ),
      child: PointyDataList<PurchaseAdjustmentHistoryEntry>(
        items: viewModel.adjustmentHistory,
        onLoadMore: viewModel.loadMoreAdjustments,
        hasMore: viewModel.hasMoreAdjustments,
        isLoadingInitial: viewModel.isLoadingAdjustments,
        isLoadingMore: viewModel.isLoadingMoreAdjustments,
        emptyBuilder: (context) => Text(l10n.supplierReturnRefundHistoryEmpty),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, adjustment) {
          return PointyDataRow(
            leading: Icon(_adjustmentIcon(adjustment.type)),
            title: _adjustmentTypeLabel(l10n, adjustment.type),
            subtitle: [
              if (adjustment.purchaseOrderNumber != null &&
                  adjustment.purchaseOrderNumber!.isNotEmpty)
                l10n.purchaseOrderNumberValue(adjustment.purchaseOrderNumber!),
              if (adjustment.createdAt != null)
                formatDateTime(adjustment.createdAt!),
              l10n.lineItemCount(adjustment.lines.length),
              if (adjustment.reason.isNotEmpty) adjustment.reason,
            ].join(' • '),
            trailing: Text(formatMoney(adjustment.amount)),
          );
        },
      ),
    );
  }

  IconData _adjustmentIcon(PurchaseAdjustmentType type) {
    return switch (type) {
      PurchaseAdjustmentType.returnItems => Icons.keyboard_return_outlined,
      PurchaseAdjustmentType.refund => Icons.payments_outlined,
      PurchaseAdjustmentType.exchange => Icons.swap_horiz_outlined,
    };
  }

  String _adjustmentTypeLabel(
    AppLocalizations l10n,
    PurchaseAdjustmentType type,
  ) {
    return switch (type) {
      PurchaseAdjustmentType.returnItems => l10n.purchaseAdjustmentTypeReturn,
      PurchaseAdjustmentType.refund => l10n.purchaseAdjustmentTypeRefund,
      PurchaseAdjustmentType.exchange => l10n.purchaseAdjustmentTypeExchange,
    };
  }
}

double _historyListHeight(int itemCount, bool hasMore) {
  if (hasMore || itemCount > 3) {
    return 248;
  }
  if (itemCount == 1) {
    return 80;
  }
  if (itemCount == 2) {
    return 160;
  }
  return 240;
}

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
