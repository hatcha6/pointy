import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../purchasing/views/purchase_order_details_screen.dart';
import '../../purchasing/views/purchase_order_list_screen.dart';
import '../../register_sessions/views/session_orders.dart';
import '../view_models/product_details_view_model.dart';

class ProductDocumentHistorySection extends StatelessWidget {
  const ProductDocumentHistorySection({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final ProductDetailsViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showSales = capabilities.canViewRegisterSessionOrders;
    final showPurchases = capabilities.canAccessPurchasing;

    return PointyDetailSection(
      title: l10n.productDocumentHistoryTitle,
      icon: Icons.manage_search_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSales)
            _RecentSaleOrdersList(
              viewModel: viewModel,
              title: l10n.productRecentInvoicesTitle,
            ),
          if (showSales && showPurchases) const SizedBox(height: 16),
          if (showPurchases)
            _RecentPurchaseOrdersList(
              viewModel: viewModel,
              title: l10n.productRecentPurchaseBillsTitle,
              purchaseRepository: purchaseRepository,
              printingRepository: printingRepository,
              shopSettingsRepository: shopSettingsRepository,
              capabilities: capabilities,
            ),
        ],
      ),
    );
  }
}

class _RecentSaleOrdersList extends StatelessWidget {
  const _RecentSaleOrdersList({required this.viewModel, required this.title});

  final ProductDetailsViewModel viewModel;
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _HistorySubsection(
      title: title,
      icon: Icons.receipt_long_outlined,
      child: SizedBox(
        height: _documentHistoryListHeight(
          viewModel.recentSaleOrders.length,
          viewModel.hasMoreSaleHistory,
          hasError: viewModel.hasSaleHistoryError,
        ),
        child: PointyDataList<SaleOrder>(
          items: viewModel.recentSaleOrders,
          onLoadMore: viewModel.loadMoreSaleHistory,
          hasMore: viewModel.hasMoreSaleHistory,
          isLoadingInitial: viewModel.isLoadingSaleHistory,
          isLoadingMore: viewModel.isLoadingMoreSaleHistory,
          hasError: viewModel.hasSaleHistoryError,
          padding: EdgeInsets.zero,
          framed: false,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          errorBuilder: (context) => PointyErrorState(
            title: l10n.productRecentInvoicesLoadError,
            icon: Icons.receipt_long_outlined,
            action: FilledButton.icon(
              onPressed: viewModel.loadSaleHistory,
              icon: const Icon(Icons.sync),
              label: Text(l10n.retryButton),
            ),
          ),
          emptyBuilder: (context) => PointyEmptyState(
            icon: Icons.receipt_long_outlined,
            title: l10n.productRecentInvoicesEmpty,
          ),
          itemBuilder: (context, order) => SessionOrderTile(order: order),
        ),
      ),
    );
  }
}

class _RecentPurchaseOrdersList extends StatelessWidget {
  const _RecentPurchaseOrdersList({
    required this.viewModel,
    required this.title,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final ProductDetailsViewModel viewModel;
  final String title;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _HistorySubsection(
      title: title,
      icon: Icons.inventory_2_outlined,
      child: SizedBox(
        height: _documentHistoryListHeight(
          viewModel.recentPurchaseOrders.length,
          viewModel.hasMorePurchaseHistory,
          hasError: viewModel.hasPurchaseHistoryError,
        ),
        child: PointyDataList<PurchaseOrder>(
          items: viewModel.recentPurchaseOrders,
          onLoadMore: viewModel.loadMorePurchaseHistory,
          hasMore: viewModel.hasMorePurchaseHistory,
          isLoadingInitial: viewModel.isLoadingPurchaseHistory,
          isLoadingMore: viewModel.isLoadingMorePurchaseHistory,
          hasError: viewModel.hasPurchaseHistoryError,
          padding: EdgeInsets.zero,
          framed: false,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          errorBuilder: (context) => PointyErrorState(
            title: l10n.productRecentPurchaseBillsLoadError,
            icon: Icons.inventory_2_outlined,
            action: FilledButton.icon(
              onPressed: viewModel.loadPurchaseHistory,
              icon: const Icon(Icons.sync),
              label: Text(l10n.retryButton),
            ),
          ),
          emptyBuilder: (context) => PointyEmptyState(
            icon: Icons.inventory_2_outlined,
            title: l10n.productRecentPurchaseBillsEmpty,
          ),
          itemBuilder: (context, order) => PurchaseOrderTile(
            order: order,
            onTap: () => _openPurchaseOrder(context, order),
          ),
        ),
      ),
    );
  }

  Future<void> _openPurchaseOrder(
    BuildContext context,
    PurchaseOrder order,
  ) async {
    await Navigator.of(context).push(
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
    if (context.mounted) {
      await viewModel.loadPurchaseHistory();
    }
  }
}

class _HistorySubsection extends StatelessWidget {
  const _HistorySubsection({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: colors.primaryStrong),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

double _documentHistoryListHeight(
  int itemCount,
  bool hasMore, {
  bool hasError = false,
}) {
  // The error state is taller than the empty one — it carries a retry button —
  // and this box does not scroll, so it needs the full height or it overflows.
  if (hasError && itemCount == 0) {
    return 288;
  }
  if (hasMore || itemCount > 3) {
    return 288;
  }
  if (itemCount == 0) {
    return 220;
  }
  return itemCount * 88.0;
}
