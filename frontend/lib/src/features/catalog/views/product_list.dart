import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_query.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_details_view_model.dart';
import 'product_details_screen.dart';

class ProductList extends StatelessWidget {
  const ProductList({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    required this.capabilities,
    required this.onBarcodeSubmitted,
    required this.onOpenCameraScanner,
    required this.onCreateProduct,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final AuthorizationCapabilities capabilities;
  final FutureOr<bool> Function(String barcode) onBarcodeSubmitted;
  final VoidCallback onOpenCameraScanner;
  final VoidCallback onCreateProduct;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

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
                : null,
          ),
          if (viewModel.errorMessage == 'catalog_load_error') ...[
            SizedBox(height: spacing.sm),
            Text(
              l10n.catalogLoadError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          SizedBox(height: spacing.sm),
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
          SizedBox(height: spacing.md),
          Expanded(
            child: PointyProductTable(
              products: viewModel.products,
              onLoadMore: viewModel.loadMoreProducts,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.inventory_2_outlined,
                title: l10n.emptyCatalog,
              ),
              onOpenProduct: (product) => _openProduct(context, product),
            ),
          ),
        ],
      ),
    );
  }

  void _openProduct(BuildContext context, Product product) {
    openProductDetails(
      context,
      product: product,
      catalogRepository: viewModel.catalogRepository,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      capabilities: capabilities,
      onChanged: viewModel.loadProducts,
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
  required AuthorizationCapabilities capabilities,
  VoidCallback? onChanged,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProductDetailsScreen(
        viewModel: ProductDetailsViewModel(catalogRepository, product),
        inventoryRepository: inventoryRepository,
        printingRepository: printingRepository,
        purchaseRepository: purchaseRepository,
        capabilities: capabilities,
        onChanged: onChanged,
      ),
    ),
  );
}
