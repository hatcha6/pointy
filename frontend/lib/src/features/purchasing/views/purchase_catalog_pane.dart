import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_quick_product_sheet.dart';

class PurchaseCatalogPane extends StatelessWidget {
  const PurchaseCatalogPane({super.key, required this.viewModel});

  final PurchaseViewModel viewModel;

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
                l10n.purchaseCatalogTitle,
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
            catalogRepository: viewModel.catalogRepository,
            allowAvailabilityFilter: false,
            searchHint: l10n.purchaseProductLookupHint,
            searchFieldKey: const ValueKey('purchase_product_lookup_field'),
            autofocus:
                AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index,
            onSearchChanged: viewModel.updateSearch,
            onOpenCameraScanner: viewModel.isSubmitting
                ? null
                : () => _openCameraScanner(context),
            onSearchSubmitted: viewModel.isSubmitting
                ? null
                : (barcode) => _addBarcode(context, barcode),
            onQueryChanged: viewModel.applyQuery,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: InfiniteScrollGrid(
              items: viewModel.variants,
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
              itemBuilder: (context, variant) {
                return ProductTile.variant(
                  variant: variant,
                  showPrice: false,
                  onTap: viewModel.isSubmitting
                      ? null
                      : () => unawaited(viewModel.addVariant(variant)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _addBarcode(BuildContext context, String barcode) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    ProductVariant? variant;
    try {
      variant = await resolveOrCreatePurchaseVariant(
        context,
        viewModel: viewModel,
        barcode: barcode,
      );
    } on Exception {
      if (!context.mounted) {
        return false;
      }
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.barcodeScanError)));
      return false;
    }
    if (variant == null) {
      return false;
    }
    await viewModel.addVariant(variant);
    return true;
  }

  Future<void> _openCameraScanner(BuildContext context) async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.multiple,
      lookupVariant: viewModel.findVariantByBarcode,
      createMissingVariant: (barcode) {
        return showPurchaseQuickProductSheet(
          context,
          barcode: barcode,
          viewModel: viewModel,
        );
      },
      enableQuantity: true,
    );
    if (entries == null || entries.isEmpty) {
      return;
    }
    for (final entry in entries) {
      await viewModel.addVariant(entry.variant, quantity: entry.quantity);
    }
  }
}
