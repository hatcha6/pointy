import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../infinite_scroll_grid.dart';
import '../product_tile.dart';
import '../responsive/responsive.dart';

class PointyProductTable extends StatelessWidget {
  const PointyProductTable({
    super.key,
    required this.products,
    required this.onOpenProduct,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    this.selectionMode = false,
    this.selectedIds = const {},
    this.onToggleSelect,
  });

  final List<Product> products;
  final ValueChanged<Product> onOpenProduct;
  final Future<void> Function() onLoadMore;
  final bool hasMore;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final WidgetBuilder emptyBuilder;

  /// When true each row shows a leading checkbox and tapping it toggles
  /// selection instead of opening the product.
  final bool selectionMode;
  final Set<int> selectedIds;
  final ValueChanged<Product>? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTable = constraints.maxWidth >= AppBreakpoints.tabletMin;

        if (isLoadingInitial && products.isEmpty) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(PointyRadii.card),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(PointyRadii.card),
              child: Column(
                children: [
                  if (isTable) const _ProductTableHeader(),
                  Expanded(
                    child: PointySkeleton(
                      child: ListView.separated(
                        physics: const NeverScrollableScrollPhysics(),
                        padding: isTable
                            ? EdgeInsets.zero
                            : const EdgeInsetsDirectional.all(8),
                        itemCount: 12,
                        separatorBuilder: (context, index) => isTable
                            ? Divider(height: 1, color: colors.line)
                            : const SizedBox(height: 8),
                        itemBuilder: (context, index) =>
                            const PointySkeletonListTile(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (products.isEmpty) {
          return emptyBuilder(context);
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.card),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(PointyRadii.card),
            child: Column(
              children: [
                if (isTable) const _ProductTableHeader(),
                Expanded(
                  child: InfiniteScrollList<Product>(
                    items: products,
                    onLoadMore: onLoadMore,
                    hasMore: hasMore,
                    isLoadingInitial: isLoadingInitial,
                    isLoadingMore: isLoadingMore,
                    emptyBuilder: emptyBuilder,
                    padding: isTable
                        ? EdgeInsets.zero
                        : const EdgeInsetsDirectional.all(8),
                    separatorBuilder: (context, index) => isTable
                        ? Divider(height: 1, color: colors.line)
                        : const SizedBox(height: 8),
                    itemBuilder: (context, product) {
                      final tile = ProductTile.catalogRow(
                        key: ValueKey('catalog_product_${product.id}'),
                        product: product,
                        tableLayout: isTable,
                        onTap: selectionMode
                            ? () => onToggleSelect?.call(product)
                            : () => onOpenProduct(product),
                      );
                      if (!selectionMode) {
                        return tile;
                      }
                      return _SelectableRow(
                        selected: selectedIds.contains(product.id),
                        onToggle: () => onToggleSelect?.call(product),
                        child: tile,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProductTableHeader extends StatelessWidget {
  const _ProductTableHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: colors.mutedInk,
      fontWeight: FontWeight.w800,
    );

    return DecoratedBox(
      decoration: BoxDecoration(color: colors.subtleFill),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Text(l10n.productTableProductColumn, style: style),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 124,
              child: Text(l10n.productTableStockColumn, style: style),
            ),
            SizedBox(
              width: 112,
              child: Text(l10n.productTablePriceColumn, style: style),
            ),
            SizedBox(
              width: 176,
              child: Text(l10n.productTableBarcodeColumn, style: style),
            ),
            SizedBox(
              width: 72,
              child: Text(l10n.productTableEditColumn, style: style),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectableRow extends StatelessWidget {
  const _SelectableRow({
    required this.selected,
    required this.onToggle,
    required this.child,
  });

  final bool selected;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ColoredBox(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Checkbox(value: selected, onChanged: (_) => onToggle()),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
