import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../view_models/pos_view_model.dart';

class PosCatalogPane extends StatelessWidget {
  const PosCatalogPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.catalogTitle,
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
          if (viewModel.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.sampleCatalogNotice,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          const SizedBox(height: 12),
          ProductQueryControls(
            query: viewModel.query,
            allowAvailabilityFilter: false,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: InfiniteScrollGrid(
              items: viewModel.products,
              onLoadMore: viewModel.loadMoreCatalog,
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
                return CheckoutCapabilityBuilder(
                  capabilities: capabilities,
                  builder: (context, canCheckout) {
                    return ProductTile(
                      product: product,
                      onTap: canCheckout
                          ? () => viewModel.addProduct(product)
                          : null,
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
