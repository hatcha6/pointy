import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/product_query_controls.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_stock_view_model.dart';
import 'product_details_screen.dart';

class ProductList extends StatelessWidget {
  const ProductList({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.capabilities,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                l10n.productListTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              if (viewModel.isLoading)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (viewModel.errorMessage == 'catalog_load_error') ...[
            const SizedBox(height: 8),
            Text(
              l10n.catalogLoadError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          ProductQueryControls(
            query: viewModel.query,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: InfiniteScrollGrid(
              items: viewModel.products,
              onLoadMore: viewModel.loadMoreProducts,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              emptyBuilder: (context) => Center(child: Text(l10n.emptyCatalog)),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 156,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (context, product) {
                return ProductTile(
                  product: product,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ProductDetailsScreen(
                          viewModel: ProductStockViewModel(
                            inventoryRepository,
                            product,
                          ),
                          capabilities: capabilities,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
