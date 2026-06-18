import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_query.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_details_view_model.dart';
import 'product_bulk_actions.dart';
import 'product_details_screen.dart';

class ProductList extends StatelessWidget {
  const ProductList({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    required this.saleRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.analyticsEngine,
    required this.onBarcodeSubmitted,
    required this.onOpenCameraScanner,
    required this.onCreateProduct,
    this.onOpenProduct,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final SaleRepository saleRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;
  final FutureOr<bool> Function(String barcode) onBarcodeSubmitted;
  final VoidCallback onOpenCameraScanner;
  final VoidCallback onCreateProduct;

  /// Overrides the default push navigation when a product row is opened.
  /// The catalog master-detail pane uses this to select inline.
  final ValueChanged<Product>? onOpenProduct;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final selectionMode = viewModel.selectionMode;

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySectionHeader(
            title: l10n.productListTitle,
            trailing: viewModel.isLoading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : (capabilities.canChangeProduct && !selectionMode)
                ? IconButton(
                    tooltip: l10n.bulkSelectTooltip,
                    icon: const Icon(Icons.checklist_outlined),
                    onPressed: viewModel.enterSelectionMode,
                  )
                : null,
          ),
          if (viewModel.errorMessage == 'catalog_load_error') ...[
            SizedBox(height: spacing.sm),
            Text(
              l10n.catalogLoadError,
              style: TextStyle(color: context.pointyColors.danger),
            ),
          ],
          SizedBox(height: spacing.sm),
          if (selectionMode)
            _BulkSelectionBar(
              viewModel: viewModel,
              isViewingArchived: viewModel.isViewingArchived,
              onArchive: () => _runArchive(context),
              onReprice: () => _openReprice(context),
              onCategorize: () => _openCategorize(context),
              onFlags: () => _openFlags(context),
            )
          else ...[
            _CatalogActionBar(
              query: viewModel.query,
              catalogRepository: viewModel.catalogRepository,
              onSearchChanged: viewModel.updateSearch,
              onQueryChanged: viewModel.applyQuery,
              onBarcodeSubmitted: onBarcodeSubmitted,
              onOpenCameraScanner: onOpenCameraScanner,
              canCreateProduct: capabilities.canCreateProduct,
              onCreateProduct: onCreateProduct,
            ),
            if (capabilities.canChangeProduct) ...[
              SizedBox(height: spacing.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _ArchivedFilterChip(
                  isViewingArchived: viewModel.isViewingArchived,
                  onChanged: viewModel.setViewingArchived,
                ),
              ),
            ],
          ],
          SizedBox(height: spacing.md),
          Expanded(
            child: PointyProductTable(
              products: viewModel.products,
              onLoadMore: viewModel.loadMoreProducts,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              selectionMode: selectionMode,
              selectedIds: viewModel.selectedIds,
              onToggleSelect: (product) =>
                  viewModel.toggleSelection(product.id),
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.inventory_2_outlined,
                title: l10n.emptyCatalog,
              ),
              onOpenProduct: (product) =>
                  (onOpenProduct ?? (p) => _openProduct(context, p))(product),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runArchive(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final archiving = !viewModel.isViewingArchived;
    final count = viewModel.selectedCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          archiving ? Icons.archive_outlined : Icons.unarchive_outlined,
        ),
        title: Text(
          archiving
              ? l10n.bulkArchiveConfirmTitle
              : l10n.bulkRestoreConfirmTitle,
        ),
        content: Text(
          archiving
              ? l10n.bulkArchiveConfirmMessage(count)
              : l10n.bulkRestoreConfirmMessage(count),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              archiving ? l10n.bulkArchiveAction : l10n.bulkRestoreAction,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final result = await viewModel.bulkArchive(archived: archiving);
    if (context.mounted) {
      _showResult(context, result);
    }
  }

  Future<void> _openReprice(BuildContext context) async {
    final choice = await showBulkRepriceSheet(context);
    if (choice == null || !context.mounted) {
      return;
    }
    final result = await viewModel.bulkReprice(
      mode: choice.mode,
      value: choice.value,
    );
    if (context.mounted) {
      _showResult(context, result);
    }
  }

  Future<void> _openCategorize(BuildContext context) async {
    final choice = await showBulkCategorizeSheet(
      context,
      catalogRepository: viewModel.catalogRepository,
    );
    if (choice == null || !context.mounted) {
      return;
    }
    final result = await viewModel.bulkCategorize(
      categoryIds: choice.categoryIds,
      mode: choice.mode,
    );
    if (context.mounted) {
      _showResult(context, result);
    }
  }

  Future<void> _openFlags(BuildContext context) async {
    final choice = await showBulkFlagsSheet(context);
    if (choice == null || !context.mounted) {
      return;
    }
    final result = await viewModel.bulkSetFlags(
      isActive: choice.isActive,
      tracksExpiry: choice.tracksExpiry,
      isService: choice.isService,
      isPrepared: choice.isPrepared,
    );
    if (context.mounted) {
      _showResult(context, result);
    }
  }

  void _showResult(BuildContext context, BulkActionResult result) {
    final l10n = AppLocalizations.of(context)!;
    final message = !result.ok
        ? l10n.bulkActionError
        : result.updated == 0
        ? l10n.bulkActionNoChanges
        : l10n.bulkActionSuccess(result.updated);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openProduct(BuildContext context, Product product) {
    openProductDetails(
      context,
      product: product,
      catalogRepository: viewModel.catalogRepository,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      saleRepository: saleRepository,
      shopSettingsRepository: shopSettingsRepository,
      capabilities: capabilities,
      analyticsEngine: analyticsEngine,
      onChanged: viewModel.loadProducts,
    );
  }
}

class _ArchivedFilterChip extends StatelessWidget {
  const _ArchivedFilterChip({
    required this.isViewingArchived,
    required this.onChanged,
  });

  final bool isViewingArchived;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FilterChip(
      avatar: const Icon(Icons.archive_outlined, size: 18),
      label: Text(l10n.archivedFilterLabel),
      selected: isViewingArchived,
      onSelected: onChanged,
    );
  }
}

class _BulkSelectionBar extends StatelessWidget {
  const _BulkSelectionBar({
    required this.viewModel,
    required this.isViewingArchived,
    required this.onArchive,
    required this.onReprice,
    required this.onCategorize,
    required this.onFlags,
  });

  final CatalogViewModel viewModel;
  final bool isViewingArchived;
  final VoidCallback onArchive;
  final VoidCallback onReprice;
  final VoidCallback onCategorize;
  final VoidCallback onFlags;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final count = viewModel.selectedCount;
    final busy = viewModel.isBulkRunning;
    final enabled = count > 0 && !busy;
    final allSelected = viewModel.allVisibleSelected;

    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            IconButton(
              tooltip: l10n.cancelButton,
              icon: const Icon(Icons.close),
              onPressed: busy ? null : viewModel.exitSelectionMode,
            ),
            Text(
              l10n.bulkSelectedCount(count),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : (allSelected
                        ? viewModel.clearSelection
                        : viewModel.selectAllVisible),
              icon: Icon(
                allSelected ? Icons.deselect_outlined : Icons.select_all,
              ),
              label: Text(
                allSelected
                    ? l10n.bulkClearSelectionAction
                    : l10n.bulkSelectAllAction,
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            OutlinedButton.icon(
              onPressed: enabled ? onArchive : null,
              icon: Icon(
                isViewingArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              label: Text(
                isViewingArchived
                    ? l10n.bulkRestoreAction
                    : l10n.bulkArchiveAction,
              ),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? onReprice : null,
              icon: const Icon(Icons.sell_outlined),
              label: Text(l10n.bulkRepriceAction),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? onCategorize : null,
              icon: const Icon(Icons.category_outlined),
              label: Text(l10n.bulkCategorizeAction),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? onFlags : null,
              icon: const Icon(Icons.flag_outlined),
              label: Text(l10n.bulkFlagsAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogActionBar extends StatelessWidget {
  const _CatalogActionBar({
    required this.query,
    required this.catalogRepository,
    required this.onSearchChanged,
    required this.onQueryChanged,
    required this.onBarcodeSubmitted,
    required this.onOpenCameraScanner,
    required this.canCreateProduct,
    required this.onCreateProduct,
  });

  final ProductQuery query;
  final CatalogRepository catalogRepository;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<ProductQuery> onQueryChanged;
  final FutureOr<bool> Function(String barcode) onBarcodeSubmitted;
  final VoidCallback onOpenCameraScanner;
  final bool canCreateProduct;
  final VoidCallback onCreateProduct;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final addButtonWidth = canCreateProduct ? 170.0 : 0.0;
        final searchWidth =
            width >= AppBreakpoints.tabletMin && canCreateProduct
            ? (width - addButtonWidth - spacing.sm)
                  .clamp(320.0, width)
                  .toDouble()
            : width;

        return ResponsiveActionBar(
          compactBreakpoint: AppBreakpoints.tabletMin,
          alignment: WrapAlignment.spaceBetween,
          actions: [
            SizedBox(
              width: searchWidth,
              child: ProductQueryControls(
                query: query,
                catalogRepository: catalogRepository,
                searchFieldKey: const ValueKey('catalog_product_lookup_field'),
                onSearchChanged: onSearchChanged,
                onSearchSubmitted: onBarcodeSubmitted,
                onOpenCameraScanner: onOpenCameraScanner,
                onQueryChanged: onQueryChanged,
              ),
            ),
            if (canCreateProduct)
              FilledButton.icon(
                onPressed: onCreateProduct,
                icon: const Icon(Icons.add),
                label: Text(l10n.addProductButton),
              ),
          ],
        );
      },
    );
  }
}

Future<void> openProductDetails(
  BuildContext context, {
  required Product product,
  required CatalogRepository catalogRepository,
  required InventoryRepository inventoryRepository,
  required PrintingRepository printingRepository,
  required PurchaseRepository purchaseRepository,
  required SaleRepository saleRepository,
  required ShopSettingsRepository shopSettingsRepository,
  required AuthorizationCapabilities capabilities,
  AnalyticsEngine? analyticsEngine,
  VoidCallback? onChanged,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProductDetailsScreen(
        viewModel: ProductDetailsViewModel(
          catalogRepository,
          purchaseRepository,
          saleRepository,
          product,
          analyticsEngine: analyticsEngine,
          shouldLoadSaleHistory: capabilities.canViewRegisterSessionOrders,
          shouldLoadPurchaseHistory: capabilities.canAccessPurchasing,
        ),
        inventoryRepository: inventoryRepository,
        printingRepository: printingRepository,
        purchaseRepository: purchaseRepository,
        shopSettingsRepository: shopSettingsRepository,
        capabilities: capabilities,
        analyticsEngine: analyticsEngine,
        onChanged: onChanged,
      ),
    ),
  );
}
