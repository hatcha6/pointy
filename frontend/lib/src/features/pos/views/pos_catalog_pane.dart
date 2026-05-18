import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
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
          _PosProductLookupControls(
            viewModel: viewModel,
            capabilities: capabilities,
          ),
          if (viewModel.barcodeScanStatus != BarcodeScanStatus.idle) ...[
            const SizedBox(height: 8),
            _BarcodeScanStatusLine(viewModel: viewModel),
          ],
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

class _PosProductLookupControls extends StatelessWidget {
  const _PosProductLookupControls({
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        return ProductQueryControls(
          query: viewModel.query,
          allowAvailabilityFilter: false,
          searchHint: l10n.posProductLookupHint,
          searchFieldKey: const ValueKey('product_lookup_field'),
          autofocus: true,
          onSearchChanged: viewModel.updateSearch,
          onOpenCameraScanner:
              canCheckout &&
                  !viewModel.isCheckingOut &&
                  !viewModel.isResolvingBarcode
              ? () => _openCameraScanner(context)
              : null,
          onSearchSubmitted:
              canCheckout &&
                  !viewModel.isCheckingOut &&
                  !viewModel.isResolvingBarcode
              ? viewModel.addProductByBarcode
              : null,
          onQueryChanged: viewModel.applyQuery,
        );
      },
    );
  }

  Future<void> _openCameraScanner(BuildContext context) async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.multiple,
      lookupProduct: _lookupProductByBarcode,
      enableQuantity: true,
    );
    if (entries == null || entries.isEmpty) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    for (final entry in entries) {
      if (viewModel.isCheckingOut) {
        return;
      }
      for (var count = 0; count < entry.quantity; count += 1) {
        viewModel.addProduct(entry.product);
      }
    }
  }

  Future<Product?> _lookupProductByBarcode(String barcode) async {
    final result = await viewModel.catalogRepository.findProductByBarcode(
      barcode,
      activeOnly: true,
    );
    return switch (result) {
      Ok<Product?>(:final value) => value,
      Error<Product?>() => throw Exception('barcode lookup failed'),
    };
  }
}

class _BarcodeScanStatusLine extends StatelessWidget {
  const _BarcodeScanStatusLine({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final status = viewModel.barcodeScanStatus;
    final message = switch (status) {
      BarcodeScanStatus.resolving => l10n.barcodeScanResolving,
      BarcodeScanStatus.found => l10n.barcodeScanAdded(
        viewModel.lastScannedProductName ?? '',
      ),
      BarcodeScanStatus.notFound => l10n.barcodeScanNotFound(
        viewModel.lastScannedBarcode ?? '',
      ),
      BarcodeScanStatus.error => l10n.barcodeScanError,
      BarcodeScanStatus.idle => '',
    };
    final color = switch (status) {
      BarcodeScanStatus.found => colorScheme.primary,
      BarcodeScanStatus.notFound ||
      BarcodeScanStatus.error => colorScheme.error,
      BarcodeScanStatus.resolving ||
      BarcodeScanStatus.idle => colorScheme.onSurfaceVariant,
    };

    return Row(
      children: [
        if (status == BarcodeScanStatus.resolving)
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            status == BarcodeScanStatus.found
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: 18,
            color: color,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        IconButton(
          tooltip: l10n.clearBarcodeStatusTooltip,
          onPressed: viewModel.clearBarcodeScanStatus,
          icon: const Icon(Icons.close),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
