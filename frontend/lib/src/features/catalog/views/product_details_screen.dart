import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/product_status_pill.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/product_stock_view_model.dart';
import 'barcode_label_print_action.dart';
import 'product_document_history_section.dart';
import 'product_parent_edit_sheet.dart';
import 'product_variant_details_screen.dart';
import 'product_variant_form_sheet.dart';
import 'product_variant_generation_sheet.dart';

class ProductDetailsScreen extends StatelessWidget {
  const ProductDetailsScreen({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.analyticsEngine,
    this.onChanged,
  });

  final ProductDetailsViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
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
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.productDetailsTitle),
            actions: [
              ProductChangeGuard(
                capabilities: capabilities,
                child: IconButton(
                  tooltip: l10n.editProductButton,
                  onPressed: () => _showProductEditor(context),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (viewModel.isLoading) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                ],
                if (viewModel.errorMessage == 'product_detail_load_error') ...[
                  Text(
                    l10n.productDetailLoadError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _ParentSummaryCard(
                  product: product,
                  variantCount: viewModel.variants.length,
                  capabilities: capabilities,
                  printingRepository: printingRepository,
                  analyticsEngine: analyticsEngine,
                  onEdit: () => _showProductEditor(context),
                ),
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
            ),
          ),
        );
      },
    );
  }

  Future<void> _showProductEditor(BuildContext context) {
    return showAdaptiveModalBottomSheet<void>(
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

  Future<void> _showVariantEditor(
    BuildContext context, {
    ProductVariant? variant,
  }) {
    return showAdaptiveModalBottomSheet<void>(
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
    return showAdaptiveModalBottomSheet<void>(
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
            analyticsEngine: analyticsEngine,
          ),
          printingRepository: printingRepository,
          capabilities: capabilities,
          analyticsEngine: analyticsEngine,
        ),
      ),
    );
  }
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
  });

  final Product product;
  final int variantCount;
  final AuthorizationCapabilities capabilities;
  final PrintingRepository printingRepository;
  final AnalyticsEngine? analyticsEngine;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Colors.white,
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
                      ProductStatusPill(isActive: product.isActive),
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
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: colorScheme.primary),
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

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
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
                    variant.barcode.isEmpty ? l10n.noBarcode : variant.barcode,
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
          l10n.stockMovementQuantityValue(variant.quantityOnHand),
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
