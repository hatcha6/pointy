import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/detail_section.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_status_pill.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/product_stock_view_model.dart';
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
    required this.capabilities,
    this.onChanged,
  });

  final ProductDetailsViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final AuthorizationCapabilities capabilities;
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
                  onEdit: () => _showProductEditor(context),
                ),
                const SizedBox(height: 12),
                _VariantsSection(
                  variants: viewModel.variants,
                  capabilities: capabilities,
                  onAddVariant: () => _showVariantEditor(context),
                  onGenerateVariants: () => _showVariantGenerator(context),
                  onEditVariant: (variant) =>
                      _showVariantEditor(context, variant: variant),
                  onOpenVariant: (variant) =>
                      _openVariantDetails(context, product, variant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showProductEditor(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.78,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ProductParentEditSheet(
                  viewModel: viewModel,
                  onSaved: () {
                    onChanged?.call();
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showVariantEditor(
    BuildContext context, {
    ProductVariant? variant,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.86,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ProductVariantFormSheet(
                  viewModel: viewModel,
                  variant: variant,
                  onSaved: () {
                    onChanged?.call();
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showVariantGenerator(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ProductVariantGenerationSheet(
                  viewModel: viewModel,
                  onSaved: () {
                    onChanged?.call();
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ),
            ),
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
          ),
          printingRepository: printingRepository,
          capabilities: capabilities,
        ),
      ),
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
      quantityOnHand: variant.quantityOnHand,
      optionValueIds: variant.optionValueIds,
      optionValues: variant.optionValues,
    );
  }
}

class _ParentSummaryCard extends StatelessWidget {
  const _ParentSummaryCard({
    required this.product,
    required this.variantCount,
    required this.capabilities,
    required this.onEdit,
  });

  final Product product;
  final int variantCount;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

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
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  child: Text(product.name.characters.first),
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
    required this.variants,
    required this.capabilities,
    required this.onAddVariant,
    required this.onGenerateVariants,
    required this.onEditVariant,
    required this.onOpenVariant,
  });

  final List<ProductVariant> variants;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onAddVariant;
  final VoidCallback onGenerateVariants;
  final ValueChanged<ProductVariant> onEditVariant;
  final ValueChanged<ProductVariant> onOpenVariant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DetailSection(
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
                    variants: variants,
                    capabilities: capabilities,
                    onEditVariant: onEditVariant,
                    onOpenVariant: onOpenVariant,
                  );
                }
                return Column(
                  children: [
                    for (final variant in variants) ...[
                      _VariantListTile(
                        variant: variant,
                        capabilities: capabilities,
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
    required this.variants,
    required this.capabilities,
    required this.onEditVariant,
    required this.onOpenVariant,
  });

  final List<ProductVariant> variants;
  final AuthorizationCapabilities capabilities;
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
    required this.variant,
    required this.capabilities,
    required this.onEdit,
    required this.onOpen,
  });

  final ProductVariant variant;
  final AuthorizationCapabilities capabilities;
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

class _VariantNameLabel extends StatelessWidget {
  const _VariantNameLabel({required this.variant});

  final ProductVariant variant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            variant.displayLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (variant.isDefault) ...[
          const SizedBox(width: 6),
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(l10n.defaultVariantBadge),
          ),
        ],
      ],
    );
  }
}
