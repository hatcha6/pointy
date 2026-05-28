import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/product_query_controls.dart';
import '../../../shared/product_tile.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_view_model.dart';
import 'pos_variant_picker_sheet.dart';

const _catalogTileMinWidth = 168.0;
const _catalogTileMainExtent = 236.0;
const _catalogLoadMoreExtent = 720.0;
const _catalogMaxColumnCount = 5;

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
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: spacing.compactPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PointySectionHeader(
            title: l10n.catalogTitle,
            trailing: viewModel.isLoading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
          ),
          if (viewModel.errorMessage != null) ...[
            Text(
              l10n.sampleCatalogNotice,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
            SizedBox(height: spacing.sm),
          ],
          _PosProductLookupControls(
            viewModel: viewModel,
            capabilities: capabilities,
          ),
          SizedBox(height: spacing.sm),
          PointyCategoryStrip<int>(
            allLabel: l10n.posAllProductsFilterLabel,
            items: [
              for (final category in viewModel.query.categories)
                if (category.name.trim().isNotEmpty)
                  PointyCategoryStripItem(
                    value: category.id,
                    label: category.name,
                  ),
            ],
            selectedValues: {
              for (final category in viewModel.query.categories) category.id,
            },
            onSelectAll: () {
              viewModel.applyQuery(
                viewModel.query.copyWith(categories: const []),
              );
            },
            onSelected: (categoryId) {
              final category = viewModel.query.categories.firstWhere(
                (category) => category.id == categoryId,
              );
              viewModel.applyQuery(
                viewModel.query.copyWith(categories: [category]),
              );
            },
          ),
          if (viewModel.barcodeScanStatus != BarcodeScanStatus.idle) ...[
            SizedBox(height: spacing.sm),
            _BarcodeScanStatusLine(viewModel: viewModel),
          ],
          SizedBox(height: spacing.md),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(PointyRadii.card),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.all(spacing.sm),
                child: _PosCatalogGrid(
                  viewModel: viewModel,
                  capabilities: capabilities,
                  emptyMessage: l10n.emptyCatalog,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosCatalogGrid extends StatelessWidget {
  const _PosCatalogGrid({
    required this.viewModel,
    required this.capabilities,
    required this.emptyMessage,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final products = viewModel.products;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final spacing = AdaptiveSpacing.of(context);
            return InfiniteScrollGrid<Product>(
              items: products,
              onLoadMore: viewModel.loadMoreCatalog,
              hasMore: viewModel.hasMoreProducts,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              loadMoreExtent: _catalogLoadMoreExtent,
              emptyBuilder: (context) =>
                  _PosCatalogEmptyState(message: emptyMessage),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _catalogColumnCountFor(
                  constraints.maxWidth,
                  spacing.gutter,
                ),
                mainAxisExtent: _catalogTileMainExtent,
                crossAxisSpacing: spacing.gutter,
                mainAxisSpacing: spacing.gutter,
              ),
              itemBuilder: (context, product) {
                return ProductTile(
                  key: ValueKey(product.id),
                  product: product,
                  onTap: canCheckout
                      ? () => _selectProduct(context, product)
                      : null,
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _selectProduct(BuildContext context, Product product) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final result = await viewModel.selectProductForSale(product);
    if (!context.mounted) {
      return;
    }
    switch (result.status) {
      case PosProductSelectionStatus.added:
        return;
      case PosProductSelectionStatus.chooseVariant:
        final variant = await showPosVariantPickerSheet(
          context,
          product: product,
          variants: result.variants,
        );
        if (variant != null && context.mounted) {
          viewModel.addVariant(variant);
        }
      case PosProductSelectionStatus.unavailable:
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.posProductHasNoActiveVariants)),
          );
      case PosProductSelectionStatus.error:
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.catalogLoadError)));
    }
  }

  int _catalogColumnCountFor(double width, double spacing) {
    if (!width.isFinite || width <= 0) {
      return 1;
    }

    final count = ((width + spacing) / (_catalogTileMinWidth + spacing))
        .floor();
    return count.clamp(1, _catalogMaxColumnCount);
  }
}

class _PosCatalogEmptyState extends StatelessWidget {
  const _PosCatalogEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PointyEmptyState(icon: Icons.inventory_2_outlined, title: message);
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
          catalogRepository: viewModel.catalogRepository,
          allowAvailabilityFilter: false,
          searchHint: l10n.posProductLookupHint,
          searchFieldKey: const ValueKey('product_lookup_field'),
          autofocus:
              AppBreakpoints.of(context).index >= AppBreakpoint.tablet.index,
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
              ? viewModel.addVariantByBarcode
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
      lookupVariant: _lookupVariantByBarcode,
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
      viewModel.addVariant(entry.variant, quantity: entry.quantity);
    }
  }

  Future<ProductVariant?> _lookupVariantByBarcode(String barcode) async {
    final result = await viewModel.catalogRepository
        .findProductVariantByBarcode(barcode, activeOnly: true);
    return switch (result) {
      Ok<ProductVariant?>(:final value) => value,
      Error<ProductVariant?>() => throw Exception('barcode lookup failed'),
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
