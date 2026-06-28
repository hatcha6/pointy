import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../formatters.dart';
import 'pointy_product_image_frame.dart';
import 'stock_status_label.dart';

class PointyProductRow extends StatelessWidget {
  const PointyProductRow({
    super.key,
    required this.product,
    required this.onTap,
    this.tableLayout = false,
  });

  final Product product;
  final VoidCallback? onTap;
  final bool tableLayout;

  @override
  Widget build(BuildContext context) {
    return tableLayout
        ? _ProductTableRow(product: product, onTap: onTap)
        : _ProductCompactRow(product: product, onTap: onTap);
  }
}

class _ProductCompactRow extends StatelessWidget {
  const _ProductCompactRow({required this.product, required this.onTap});

  final Product product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final barcode = product.effectiveBarcode.trim();

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(10),
          child: Row(
            children: [
              PointyProductImageFrame(
                imageUrl: product.primaryImage?.contentUrl,
                fallbackText: product.name,
                width: 64,
                height: 64,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _categoryLabel(l10n, product),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatMoney(product.effectiveUnitPrice),
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: colors.primaryStrong,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        StockStatusLabel(
                          quantity: product.effectiveQuantityOnHand,
                          isActive: product.isActive,
                          compact: true,
                        ),
                        Text(
                          barcode.isEmpty ? l10n.noBarcode : barcode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.mutedInk),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const PointyDisclosureChevron(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductTableRow extends StatelessWidget {
  const _ProductTableRow({required this.product, required this.onTap});

  final Product product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final barcode = product.effectiveBarcode.trim();

    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      PointyProductImageFrame(
                        imageUrl: product.primaryImage?.contentUrl,
                        fallbackText: product.name,
                        width: 56,
                        height: 56,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              product.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _categoryLabel(l10n, product),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.mutedInk),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 124,
                  child: StockStatusLabel(
                    quantity: product.effectiveQuantityOnHand,
                    isActive: product.isActive,
                  ),
                ),
                SizedBox(
                  width: 112,
                  child: Text(
                    formatMoney(product.effectiveUnitPrice),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(
                  width: 176,
                  child: Text(
                    barcode.isEmpty ? l10n.noBarcode : barcode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: colors.ink),
                  ),
                ),
                const SizedBox(
                  width: 40,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: PointyDisclosureChevron(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _categoryLabel(AppLocalizations l10n, Product product) {
  final categories = [
    for (final category in product.categories)
      if (category.name.trim().isNotEmpty) category.name.trim(),
  ];
  if (categories.isEmpty) {
    return l10n.productNoCategories;
  }
  return categories.join(' / ');
}
