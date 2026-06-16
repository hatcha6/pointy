import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
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
import 'modifier_sheet.dart';
import 'pos_variant_picker_sheet.dart';
import 'unit_quantity_sheet.dart';
import 'weight_entry_sheet.dart';

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

    return PointyCatalogPane(
      title: l10n.catalogTitle,
      isLoading: viewModel.isLoading,
      resultCount: viewModel.isLoading && viewModel.products.isEmpty
          ? null
          : viewModel.products.length,
      hasMoreResults: viewModel.hasMoreProducts,
      notice: viewModel.errorMessage != null
          ? PointyInlineMessage.warning(message: l10n.sampleCatalogNotice)
          : null,
      search: _PosProductLookupControls(
        viewModel: viewModel,
        capabilities: capabilities,
      ),
      categoryStrip: QuickAccessCategoryStrip(
        catalogRepository: viewModel.catalogRepository,
        selectedCategories: viewModel.query.categories,
        allLabel: l10n.posAllProductsFilterLabel,
        onSelectAll: () {
          viewModel.applyQuery(viewModel.query.copyWith(categories: const []));
        },
        onSelectCategory: (category) {
          viewModel.applyQuery(
            viewModel.query.copyWith(categories: [category]),
          );
        },
      ),
      statusLine: viewModel.barcodeScanStatus != BarcodeScanStatus.idle
          ? _BarcodeScanStatusLine(viewModel: viewModel)
          : null,
      grid: _PosCatalogGrid(
        viewModel: viewModel,
        capabilities: capabilities,
        emptyMessage: l10n.emptyCatalog,
        cartQuantities: _cartQuantitiesByProduct(viewModel.cart),
      ),
    );
  }

  /// Sums cart quantities per product so each catalog card can show how many
  /// of that product are already in the open sale.
  static Map<int, double> _cartQuantitiesByProduct(List<CartLine> cart) {
    final quantities = <int, double>{};
    for (final line in cart) {
      quantities.update(
        line.variant.productId,
        (value) => value + line.quantity,
        ifAbsent: () => line.quantity,
      );
    }
    return quantities;
  }
}

class _PosCatalogGrid extends StatelessWidget {
  const _PosCatalogGrid({
    required this.viewModel,
    required this.capabilities,
    required this.emptyMessage,
    required this.cartQuantities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final String emptyMessage;
  final Map<int, double> cartQuantities;

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
              loadMoreExtent: PointyProductCardGrid.loadMoreExtent,
              emptyBuilder: (context) =>
                  _PosCatalogEmptyState(message: emptyMessage),
              gridDelegate: PointyProductCardGrid.delegateFor(
                width: constraints.maxWidth,
                spacing: spacing.gutter,
              ),
              itemBuilder: (context, product) {
                return ProductTile(
                  key: ValueKey(product.id),
                  product: product,
                  cartQuantity: cartQuantities[product.id] ?? 0,
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

  Future<void> _addWeighedVariant(
    BuildContext context,
    Product product,
    ProductVariant variant, {
    required String source,
  }) async {
    final weight = await showWeightEntrySheet(context, variant: variant);
    if (weight == null || !context.mounted) {
      return;
    }
    if (product.modifierGroups.isEmpty) {
      viewModel.addVariant(variant, quantity: weight, source: source);
      return;
    }
    final modifiers = await showModifierSheet(
      context,
      product: product,
      variant: variant,
    );
    if (modifiers != null && context.mounted) {
      viewModel.addVariant(
        variant,
        quantity: weight,
        modifiers: modifiers,
        source: source,
      );
    }
  }

  Future<void> _addWithModifiers(
    BuildContext context,
    Product product,
    ProductVariant variant, {
    required String source,
  }) async {
    final modifiers = await showModifierSheet(
      context,
      product: product,
      variant: variant,
    );
    if (modifiers != null && context.mounted) {
      viewModel.addVariant(variant, modifiers: modifiers, source: source);
    }
  }

  Future<void> _addWithUnit(
    BuildContext context,
    Product product,
    ProductVariant variant, {
    required String source,
  }) async {
    final selection = await showUnitQuantitySheet(
      context,
      product: product,
      variant: variant,
    );
    if (selection == null || !context.mounted) {
      return;
    }
    if (product.modifierGroups.isEmpty) {
      viewModel.addVariant(
        variant,
        quantity: selection.quantity,
        unit: selection.unit,
        source: source,
      );
      return;
    }
    final modifiers = await showModifierSheet(
      context,
      product: product,
      variant: variant,
    );
    if (modifiers != null && context.mounted) {
      viewModel.addVariant(
        variant,
        quantity: selection.quantity,
        unit: selection.unit,
        modifiers: modifiers,
        source: source,
      );
    }
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
      case PosProductSelectionStatus.weighVariant:
        final weighed = result.weighedVariant;
        if (weighed != null && context.mounted) {
          await _addWeighedVariant(
            context,
            product,
            weighed,
            source: 'product_tile',
          );
        }
      case PosProductSelectionStatus.chooseModifiers:
        final variant = result.modifierVariant;
        if (variant != null && context.mounted) {
          await _addWithModifiers(
            context,
            product,
            variant,
            source: 'product_tile',
          );
        }
      case PosProductSelectionStatus.chooseUnit:
        final variant = result.unitVariant;
        final unitProduct = result.unitProduct;
        if (variant != null && unitProduct != null && context.mounted) {
          await _addWithUnit(
            context,
            unitProduct,
            variant,
            source: 'product_tile',
          );
        }
      case PosProductSelectionStatus.chooseVariant:
        final variant = await showPosVariantPickerSheet(
          context,
          product: product,
          variants: result.variants,
        );
        if (variant != null && context.mounted) {
          if (product.hasSellableUnits) {
            await _addWithUnit(
              context,
              product,
              variant,
              source: 'variant_picker',
            );
          } else if (variant.unit != 'piece') {
            await _addWeighedVariant(
              context,
              product,
              variant,
              source: 'variant_picker',
            );
          } else if (product.modifierGroups.isNotEmpty) {
            await _addWithModifiers(
              context,
              product,
              variant,
              source: 'variant_picker',
            );
          } else {
            viewModel.addVariant(variant, source: 'variant_picker');
          }
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
      viewModel.addVariant(
        entry.variant,
        quantity: entry.quantity.toDouble(),
        source: 'camera_scanner',
      );
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
    final colors = context.pointyColors;
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
      BarcodeScanStatus.found => colors.primaryStrong,
      BarcodeScanStatus.notFound || BarcodeScanStatus.error => colors.danger,
      BarcodeScanStatus.resolving || BarcodeScanStatus.idle => colors.mutedInk,
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
