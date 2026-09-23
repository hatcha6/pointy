import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/bought_together_product.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/product_status_pill.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/units.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/product_stock_view_model.dart';
import 'barcode_label_print_action.dart';
import 'change_prices_dialog.dart';
import 'product_document_history_section.dart';
import 'product_parent_edit_sheet.dart';
import 'product_variant_details_screen.dart';
import 'product_variant_form_sheet.dart';
import 'product_variant_generation_sheet.dart';
import 'variant_cost_metrics.dart';

class ProductDetailsScreen extends StatelessWidget {
  const ProductDetailsScreen({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    this.warehouseRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.analyticsEngine,
    this.onChanged,
  });

  final ProductDetailsViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  /// Optional: without it the stock panel simply shows the total and no
  /// per-place breakdown, which is the right answer for a shop with one
  /// place anyway.
  final WarehouseRepository? warehouseRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.productDetailsTitle),
        actions: [
          // Rebuilt with the product: a system product arrives read-only, and
          // the edit button must not be offered for one even for a moment.
          ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) => ProductChangeGuard(
              capabilities: capabilities.forProduct(
                isSystem: viewModel.product.isSystem,
              ),
              child: IconButton(
                tooltip: l10n.editProductButton,
                onPressed: () =>
                    showProductParentEditor(context, viewModel, onChanged),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ProductDetailsView(
          viewModel: viewModel,
          inventoryRepository: inventoryRepository,
          printingRepository: printingRepository,
          purchaseRepository: purchaseRepository,
          warehouseRepository: warehouseRepository,
          shopSettingsRepository: shopSettingsRepository,
          capabilities: capabilities,
          analyticsEngine: analyticsEngine,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Embeddable product details body: used by [ProductDetailsScreen] as a pushed
/// route on compact widths, and by the catalog master-detail pane on desktop.
class ProductDetailsView extends StatelessWidget {
  const ProductDetailsView({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    this.warehouseRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.analyticsEngine,
    this.onChanged,
  });

  final ProductDetailsViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  /// Optional: without it the stock panel simply shows the total and no
  /// per-place breakdown, which is the right answer for a shop with one
  /// place anyway.
  final WarehouseRepository? warehouseRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final product = viewModel.product;
        // A system product is written by the feature that owns it and by
        // nobody else: every change affordance below disappears for it.
        final capabilities = this.capabilities.forProduct(
          isSystem: product.isSystem,
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (viewModel.isLoading) ...[
              const PointyProgressBar(),
              const SizedBox(height: 12),
            ],
            if (product.isSystem) ...[
              PointyInlineMessage(
                message: product.isVoucher
                    ? l10n.systemProductVoucherNotice
                    : l10n.systemProductNotice,
                icon: Icons.lock_outline,
              ),
              const SizedBox(height: 12),
            ],
            if (viewModel.errorMessage == 'product_detail_load_error') ...[
              Text(
                l10n.productDetailLoadError,
                style: TextStyle(color: context.pointyColors.danger),
              ),
              const SizedBox(height: 12),
            ],
            _ParentSummaryCard(
              product: product,
              variantCount: viewModel.variants.length,
              capabilities: capabilities,
              printingRepository: printingRepository,
              analyticsEngine: analyticsEngine,
              onEdit: () =>
                  showProductParentEditor(context, viewModel, onChanged),
              onArchive: () => _confirmArchive(context, l10n),
              onRestore: () => _restore(context, l10n),
            ),
            if (capabilities.canAccessPurchasing) ...[
              const SizedBox(height: 12),
              _PricingAndCostSection(
                viewModel: viewModel,
                capabilities: capabilities,
                onChangePrices: () =>
                    showChangePricesDialog(context, viewModel),
              ),
            ],
            const SizedBox(height: 12),
            _VariantsSection(
              product: product,
              variants: viewModel.variants,
              capabilities: capabilities,
              printingRepository: printingRepository,
              analyticsEngine: analyticsEngine,
              onAddVariant: () => _showVariantEditor(context),
              onGenerateVariants: () => _showVariantGenerator(context),
              onEditVariant: (variant) =>
                  _showVariantEditor(context, variant: variant),
              onOpenVariant: (variant) =>
                  _openVariantDetails(context, product, variant),
            ),
            if (viewModel.boughtTogether.isNotEmpty) ...[
              const SizedBox(height: 12),
              _BoughtTogetherSection(
                items: viewModel.boughtTogether,
                onOpenProduct: (item) =>
                    _openBoughtTogetherProduct(context, item),
              ),
            ],
            if (capabilities.canViewRegisterSessionOrders ||
                capabilities.canAccessPurchasing) ...[
              const SizedBox(height: 12),
              ProductDocumentHistorySection(
                viewModel: viewModel,
                purchaseRepository: purchaseRepository,
                printingRepository: printingRepository,
                shopSettingsRepository: shopSettingsRepository,
                capabilities: capabilities,
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _showVariantEditor(
    BuildContext context, {
    ProductVariant? variant,
  }) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.92,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ProductVariantFormSheet(
            viewModel: viewModel,
            variant: variant,
            onSaved: () {
              onChanged?.call();
              Navigator.of(sheetContext).pop();
            },
          ),
        );
      },
    );
  }

  Future<void> _showVariantGenerator(BuildContext context) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.94,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ProductVariantGenerationSheet(
            viewModel: viewModel,
            onSaved: () {
              onChanged?.call();
              Navigator.of(sheetContext).pop();
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmArchive(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.archiveProductConfirmTitle),
          content: Text(
            l10n.archiveProductConfirmMessage(viewModel.product.name),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.archiveProductAction),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    final success = await viewModel.archiveProduct();
    if (success) {
      onChanged?.call();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.archiveProductSuccess : l10n.archiveProductError,
        ),
      ),
    );
  }

  Future<void> _restore(BuildContext context, AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.of(context);
    final success = await viewModel.restoreProduct();
    if (success) {
      onChanged?.call();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.restoreProductSuccess : l10n.restoreProductError,
        ),
      ),
    );
  }

  Future<void> _openVariantDetails(
    BuildContext context,
    Product product,
    ProductVariant variant,
  ) {
    final detailProduct = Product.fromVariant(
      _variantWithParentFallback(product, variant),
    );
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductVariantDetailsScreen(
          viewModel: ProductStockViewModel(
            inventoryRepository,
            purchaseRepository,
            detailProduct,
            warehouseRepository: warehouseRepository,
            analyticsEngine: analyticsEngine,
          ),
          printingRepository: printingRepository,
          capabilities: capabilities.forProduct(
            isSystem: viewModel.product.isSystem,
          ),
          analyticsEngine: analyticsEngine,
        ),
      ),
    );
  }

  /// Opens the full product detail for a "bought together" suggestion. Only the
  /// id/name are known here, so the new view model is seeded with a stub and
  /// immediately refetches the product in full (see [ProductDetailsViewModel]).
  Future<void> _openBoughtTogetherProduct(
    BuildContext context,
    BoughtTogetherProduct item,
  ) {
    final seed = Product(
      id: item.productId,
      name: item.name,
      quantityOnHand: 0,
      primaryImage: item.primaryImage,
    );
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductDetailsScreen(
          viewModel: ProductDetailsViewModel(
            viewModel.catalogRepository,
            purchaseRepository,
            viewModel.saleRepository,
            seed,
            analyticsEngine: analyticsEngine,
            pricingOptions: viewModel.pricingOptions,
            shouldLoadSaleHistory: capabilities.canViewRegisterSessionOrders,
            shouldLoadPurchaseHistory: capabilities.canAccessPurchasing,
          ),
          inventoryRepository: inventoryRepository,
          printingRepository: printingRepository,
          purchaseRepository: purchaseRepository,
          warehouseRepository: warehouseRepository,
          shopSettingsRepository: shopSettingsRepository,
          capabilities: capabilities,
          analyticsEngine: analyticsEngine,
        ),
      ),
    );
  }
}

/// Opens the parent-product edit form on the adaptive form surface.
Future<void> showProductParentEditor(
  BuildContext context,
  ProductDetailsViewModel viewModel,
  VoidCallback? onChanged,
) {
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.9,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: ProductParentEditSheet(
          viewModel: viewModel,
          onSaved: () {
            onChanged?.call();
            Navigator.of(sheetContext).pop();
          },
        ),
      );
    },
  );
}

ProductVariant _variantWithParentFallback(
  Product product,
  ProductVariant variant,
) {
  if (variant.productDetail != null && variant.productName.isNotEmpty) {
    return variant;
  }
  return ProductVariant(
    id: variant.id,
    productId: product.id,
    productName: product.name,
    productDetail: product,
    name: variant.name,
    displayName: variant.displayName,
    fullName: variant.fullName,
    sku: variant.sku,
    barcode: variant.barcode,
    unitPrice: variant.unitPrice,
    isActive: variant.isActive,
    isDefault: variant.isDefault,
    tracksExpiry: variant.tracksExpiry || product.tracksExpiry,
    quantityOnHand: variant.quantityOnHand,
    optionValueIds: variant.optionValueIds,
    optionValues: variant.optionValues,
    primaryImage: variant.primaryImage ?? product.primaryImage,
    imageAttachments: variant.imageAttachments.isNotEmpty
        ? variant.imageAttachments
        : product.imageAttachments,
  );
}

class _ParentSummaryCard extends StatelessWidget {
  const _ParentSummaryCard({
    required this.product,
    required this.variantCount,
    required this.capabilities,
    required this.printingRepository,
    this.analyticsEngine,
    required this.onEdit,
    required this.onArchive,
    required this.onRestore,
  });

  final Product product;
  final int variantCount;
  final AuthorizationCapabilities capabilities;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: context.pointyColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ProductImageThumbnail(
                  imageUrl: product.primaryImage?.contentUrl,
                  fallbackText: product.name,
                  size: 56,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      ProductStatusPill(
                        isActive: product.isActive,
                        isArchived: product.isArchived,
                      ),
                    ],
                  ),
                ),
                BarcodeLabelPrintButton(
                  label: BarcodeLabelDraft.fromProduct(product),
                  printingRepository: printingRepository,
                  productId: product.id,
                  productName: product.name,
                  variantId: product.variantId,
                  entityType: 'product',
                  entityId: product.id,
                  source: 'product_detail_parent',
                  tracksExpiry:
                      product.tracksExpiry ||
                      (product.defaultVariant?.tracksExpiry ?? false),
                  analyticsEngine: analyticsEngine,
                  style: BarcodeLabelPrintButtonStyle.icon,
                  tooltip: l10n.barcodeLabelPrintProductTooltip,
                ),
                ProductChangeGuard(
                  capabilities: capabilities,
                  child: IconButton(
                    tooltip: l10n.editProductButton,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
                ProductChangeGuard(
                  capabilities: capabilities,
                  child: product.isArchived
                      ? IconButton(
                          tooltip: l10n.restoreProductAction,
                          onPressed: onRestore,
                          icon: const Icon(Icons.unarchive_outlined),
                        )
                      : IconButton(
                          tooltip: l10n.archiveProductAction,
                          onPressed: onArchive,
                          icon: const Icon(Icons.archive_outlined),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              product.description.isEmpty
                  ? l10n.noDescription
                  : product.description,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SummaryChip(
                  icon: Icons.inventory_2_outlined,
                  label: l10n.productTotalStockLabel,
                  value: '${product.quantityOnHand}',
                ),
                _SummaryChip(
                  icon: Icons.tune_outlined,
                  label: l10n.productVariantsTitle,
                  value: '$variantCount',
                ),
                _SummaryChip(
                  icon: Icons.sell_outlined,
                  label: l10n.productPriceTitle,
                  value: formatMoney(product.effectiveUnitPrice),
                ),
              ],
            ),
            const SizedBox(height: 14),
            product.categories.isEmpty
                ? Text(l10n.productNoCategories)
                : Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final category in product.categories)
                        Chip(label: Text(category.displayPath)),
                    ],
                  ),
            const SizedBox(height: 14),
            Text(
              l10n.productVariantOptionsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            product.variantOptions.isEmpty
                ? Text(l10n.productVariantOptionsEmpty)
                : Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final option in product.variantOptions)
                        Chip(label: Text(option.displayLabel)),
                    ],
                  ),
          ],
        ),
      ),
    );
  }
}

/// "Pricing & cost" overview: product-level lowest/highest/last/average cost
/// (aggregated across variants from purchase history) plus a "Change prices"
/// action that opens the per-variant repricing dialog.
class _PricingAndCostSection extends StatelessWidget {
  const _PricingAndCostSection({
    required this.viewModel,
    required this.capabilities,
    required this.onChangePrices,
  });

  final ProductDetailsViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onChangePrices;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summaries = viewModel.costSummaries;
    final hasAnyCost = summaries.any((summary) => summary.hasCost);

    return PointyDetailSection(
      title: l10n.productPricingAndCostTitle,
      icon: Icons.payments_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (viewModel.isLoadingCostSummary && summaries.isEmpty)
            const Center(child: PointySpinner())
          else if (viewModel.hasCostSummaryError && summaries.isEmpty)
            PointyInlineMessage.error(message: l10n.changePricesLoadError)
          else if (!hasAnyCost)
            Text(
              l10n.noCostDataLabel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            )
          else
            VariantCostMetrics.aggregate(
              summaries,
              currentPrice: viewModel.product.effectiveUnitPrice,
            ),
          const SizedBox(height: 14),
          ProductChangeGuard(
            capabilities: capabilities,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: viewModel.isSavingPrices ? null : onChangePrices,
                icon: const Icon(Icons.price_change_outlined),
                label: Text(l10n.changePricesButton),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: colors.primaryStrong),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 8),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _VariantsSection extends StatelessWidget {
  const _VariantsSection({
    required this.product,
    required this.variants,
    required this.capabilities,
    required this.printingRepository,
    this.analyticsEngine,
    required this.onAddVariant,
    required this.onGenerateVariants,
    required this.onEditVariant,
    required this.onOpenVariant,
  });

  final Product product;
  final List<ProductVariant> variants;
  final AuthorizationCapabilities capabilities;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback onAddVariant;
  final VoidCallback onGenerateVariants;
  final ValueChanged<ProductVariant> onEditVariant;
  final ValueChanged<ProductVariant> onOpenVariant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.productVariantsTitle,
      icon: Icons.view_list_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ProductVariantCreateGuard(
              capabilities: capabilities,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onGenerateVariants,
                    icon: const Icon(Icons.auto_awesome_motion_outlined),
                    label: Text(l10n.generateVariantsButton),
                  ),
                  OutlinedButton.icon(
                    onPressed: onAddVariant,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addVariantButton),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (variants.isEmpty)
            Text(l10n.noVariants)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 720) {
                  return _VariantDataTable(
                    product: product,
                    variants: variants,
                    capabilities: capabilities,
                    printingRepository: printingRepository,
                    analyticsEngine: analyticsEngine,
                    onEditVariant: onEditVariant,
                    onOpenVariant: onOpenVariant,
                  );
                }
                return Column(
                  children: [
                    for (final variant in variants) ...[
                      _VariantListTile(
                        product: product,
                        variant: variant,
                        capabilities: capabilities,
                        printingRepository: printingRepository,
                        analyticsEngine: analyticsEngine,
                        onEdit: () => onEditVariant(variant),
                        onOpen: () => onOpenVariant(variant),
                      ),
                      if (variant != variants.last) const Divider(height: 1),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _VariantDataTable extends StatelessWidget {
  const _VariantDataTable({
    required this.product,
    required this.variants,
    required this.capabilities,
    required this.printingRepository,
    this.analyticsEngine,
    required this.onEditVariant,
    required this.onOpenVariant,
  });

  final Product product;
  final List<ProductVariant> variants;
  final AuthorizationCapabilities capabilities;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;
  final ValueChanged<ProductVariant> onEditVariant;
  final ValueChanged<ProductVariant> onOpenVariant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Fill the section when the columns fit, and only scroll sideways when
    // they genuinely overflow — a table that hugs its content leaves a dead
    // gap down the side of the card.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            columnSpacing: 20,
            columns: [
              DataColumn(label: Text(l10n.variantNameColumn)),
              DataColumn(label: Text(l10n.variantStockColumn), numeric: true),
              DataColumn(label: Text(l10n.variantPriceColumn)),
              DataColumn(label: Text(l10n.variantSkuColumn)),
              DataColumn(label: Text(l10n.variantBarcodeColumn)),
              DataColumn(label: Text(l10n.variantStatusColumn)),
              DataColumn(label: Text(l10n.actionsColumn)),
            ],
            rows: [
              for (final variant in variants)
                DataRow(
                  onSelectChanged: (_) => onOpenVariant(variant),
                  cells: [
                    DataCell(_VariantNameLabel(variant: variant)),
                    DataCell(Text('${variant.quantityOnHand}')),
                    DataCell(Text(formatMoney(variant.unitPrice))),
                    DataCell(Text(variant.sku)),
                    DataCell(
                      Text(
                        variant.barcode.isEmpty
                            ? l10n.noBarcode
                            : variant.barcode,
                      ),
                    ),
                    DataCell(ProductStatusPill(isActive: variant.isSellable)),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _VariantBarcodeLabelPrintButton(
                            product: product,
                            variant: variant,
                            printingRepository: printingRepository,
                            analyticsEngine: analyticsEngine,
                          ),
                          IconButton(
                            tooltip: l10n.openVariantDetailsTooltip,
                            onPressed: () => onOpenVariant(variant),
                            icon: const Icon(Icons.open_in_new),
                          ),
                          ProductVariantChangeGuard(
                            capabilities: capabilities,
                            child: IconButton(
                              tooltip: l10n.editVariantTitle,
                              onPressed: () => onEditVariant(variant),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VariantListTile extends StatelessWidget {
  const _VariantListTile({
    required this.product,
    required this.variant,
    required this.capabilities,
    required this.printingRepository,
    this.analyticsEngine,
    required this.onEdit,
    required this.onOpen,
  });

  final Product product;
  final ProductVariant variant;
  final AuthorizationCapabilities capabilities;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: _VariantNameLabel(variant: variant),
      subtitle: Text(
        [
          variant.sku,
          formatMoney(variant.unitPrice),
          l10n.stockMovementQuantityValue(
            formatQuantity(variant.quantityOnHand),
          ),
          if (variant.barcode.isNotEmpty) variant.barcode,
        ].join(' / '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          _VariantBarcodeLabelPrintButton(
            product: product,
            variant: variant,
            printingRepository: printingRepository,
            analyticsEngine: analyticsEngine,
          ),
          IconButton(
            tooltip: l10n.openVariantDetailsTooltip,
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new),
          ),
          ProductVariantChangeGuard(
            capabilities: capabilities,
            child: IconButton(
              tooltip: l10n.editVariantTitle,
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
          ),
        ],
      ),
      onTap: onOpen,
    );
  }
}

class _VariantBarcodeLabelPrintButton extends StatelessWidget {
  const _VariantBarcodeLabelPrintButton({
    required this.product,
    required this.variant,
    required this.printingRepository,
    this.analyticsEngine,
  });

  final Product product;
  final ProductVariant variant;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final labelVariant = _variantWithParentFallback(product, variant);
    return BarcodeLabelPrintButton(
      label: BarcodeLabelDraft.fromVariant(labelVariant),
      printingRepository: printingRepository,
      productId: product.id,
      productName: product.name,
      variantId: variant.id,
      entityType: 'product_variant',
      entityId: variant.id,
      source: 'product_detail_variants',
      tracksExpiry: labelVariant.tracksExpiry,
      analyticsEngine: analyticsEngine,
      style: BarcodeLabelPrintButtonStyle.icon,
      tooltip: l10n.barcodeLabelPrintVariantTooltip,
    );
  }
}

class _VariantNameLabel extends StatelessWidget {
  const _VariantNameLabel({required this.variant});

  final ProductVariant variant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            variant.displayLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (variant.isDefault)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(l10n.defaultVariantBadge),
          ),
      ],
    );
  }
}

/// "Frequently bought together" — products that recur in the same paid orders
/// as the one being viewed, ranked by how often they co-occur. Rendered as a
/// horizontally scrolling strip of tappable cards.
class _BoughtTogetherSection extends StatelessWidget {
  const _BoughtTogetherSection({
    required this.items,
    required this.onOpenProduct,
  });

  final List<BoughtTogetherProduct> items;
  final ValueChanged<BoughtTogetherProduct> onOpenProduct;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailSection(
      title: l10n.productBoughtTogetherTitle,
      icon: Icons.add_shopping_cart_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.productBoughtTogetherSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return _BoughtTogetherCard(
                  item: item,
                  onTap: () => onOpenProduct(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BoughtTogetherCard extends StatelessWidget {
  const _BoughtTogetherCard({required this.item, required this.onTap});

  final BoughtTogetherProduct item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return SizedBox(
      width: 136,
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ProductImageThumbnail(
                    imageUrl: item.primaryImage?.contentUrl,
                    fallbackText: item.name,
                    size: 64,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  formatMoney(item.unitPrice),
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.primaryStrong,
                  ),
                ),
                const Spacer(),
                Text(
                  l10n.productBoughtTogetherOrders('${item.ordersTogether}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
