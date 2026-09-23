import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../components/components.dart';
import '../design/design.dart';
import '../infinite_scroll_grid.dart';

/// Which columns a [PointyCatalogTable] shows at a width, and how wide each
/// fixed one is.
///
/// The header and every row ask this of the same width, so they always line
/// up. Columns drop out as the pane narrows — the barcode first, then stock,
/// and on a phone the price gives up its spare room — while the product keeps
/// whatever is left, because the name is what a price list is read by.
@immutable
class PointyCatalogTableColumns {
  const PointyCatalogTableColumns._({
    required this.showStock,
    required this.showBarcode,
    required this.priceWidth,
  });

  factory PointyCatalogTableColumns.forWidth(double width) {
    final showStock = width >= stockMinWidth;
    return PointyCatalogTableColumns._(
      showStock: showStock,
      showBarcode: width >= barcodeMinWidth,
      priceWidth: showStock ? 116 : 92,
    );
  }

  static const double stockMinWidth = 440;
  static const double barcodeMinWidth = 700;

  static const double barcodeWidth = 156;
  static const double stockWidth = 84;
  static const double actionWidth = 44;
  static const double gap = 12;

  /// Side insets shared by the header and the rows, so their columns meet.
  static const double startInset = 10;
  static const double endInset = 6;

  final bool showStock;
  final bool showBarcode;

  /// Wide enough for a four-figure price; one that is wider still, such as a
  /// foreign price beside its dinar figure, shrinks to fit rather than wrap.
  final double priceWidth;
}

/// The table alternative to the product card grid in a catalog browser: a
/// pinned header over rows that page in as the list scrolls.
///
/// Only the frame — each row is whatever [itemBuilder] returns, normally a
/// [PointyCatalogRow], so the screen keeps its own tap handling exactly as it
/// has it for cards.
class PointyCatalogTable<T> extends StatelessWidget {
  const PointyCatalogTable({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    this.loadMoreExtent = 480,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Future<void> Function() onLoadMore;
  final bool hasMore;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final WidgetBuilder emptyBuilder;
  final double loadMoreExtent;

  @override
  Widget build(BuildContext context) {
    final isEmpty = items.isEmpty;
    if (isEmpty && !isLoadingInitial) {
      return emptyBuilder(context);
    }
    final colors = context.pointyColors;
    Widget divider(BuildContext context, int index) =>
        Divider(height: 1, color: colors.line);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _CatalogTableHeader(),
        Expanded(
          // The list's own skeleton cannot draw separated rows, so the first
          // load gets its placeholder here, in the table's shape.
          child: isEmpty
              ? PointySkeleton(
                  child: ListView.separated(
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 10,
                    separatorBuilder: divider,
                    itemBuilder: (context, index) =>
                        const PointySkeletonListTile(),
                  ),
                )
              : InfiniteScrollList<T>(
                  items: items,
                  itemBuilder: itemBuilder,
                  onLoadMore: onLoadMore,
                  hasMore: hasMore,
                  isLoadingInitial: isLoadingInitial,
                  isLoadingMore: isLoadingMore,
                  emptyBuilder: emptyBuilder,
                  loadMoreExtent: loadMoreExtent,
                  separatorBuilder: divider,
                ),
        ),
      ],
    );
  }
}

class _CatalogTableHeader extends StatelessWidget {
  const _CatalogTableHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: colors.mutedInk,
      fontWeight: FontWeight.w800,
    );
    Widget label(String text) =>
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = PointyCatalogTableColumns.forWidth(
          constraints.maxWidth,
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.subtleFill,
            borderRadius: BorderRadius.circular(PointyRadii.card - 2),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              PointyCatalogTableColumns.startInset,
              10,
              PointyCatalogTableColumns.endInset,
              10,
            ),
            child: Row(
              children: [
                Expanded(child: label(l10n.productTableProductColumn)),
                if (columns.showBarcode) ...[
                  const SizedBox(width: PointyCatalogTableColumns.gap),
                  SizedBox(
                    width: PointyCatalogTableColumns.barcodeWidth,
                    child: label(l10n.productTableBarcodeColumn),
                  ),
                ],
                if (columns.showStock) ...[
                  const SizedBox(width: PointyCatalogTableColumns.gap),
                  SizedBox(
                    width: PointyCatalogTableColumns.stockWidth,
                    child: label(l10n.productTableStockColumn),
                  ),
                ],
                const SizedBox(width: PointyCatalogTableColumns.gap),
                SizedBox(
                  width: columns.priceWidth,
                  child: label(l10n.productTablePriceColumn),
                ),
                const SizedBox(
                  width:
                      PointyCatalogTableColumns.gap +
                      PointyCatalogTableColumns.actionWidth,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
