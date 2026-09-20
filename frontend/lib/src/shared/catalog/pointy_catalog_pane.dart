import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import '../components/pointy_progress.dart';

/// Shared chrome for the POS and purchasing catalog browsers.
///
/// Both surfaces are "search / filter / pick a product into the open order",
/// so they share one scaffold: an adaptive page, a header with a live result
/// count, a search slot, the quick-access category chips, an optional status
/// line (barcode feedback), and a framed product grid. Each screen supplies its
/// own search controls, category strip, and grid; everything else is identical
/// so the two stay visually in lock-step.
class PointyCatalogPane extends StatelessWidget {
  const PointyCatalogPane({
    super.key,
    required this.title,
    required this.search,
    required this.grid,
    this.isLoading = false,
    this.resultCount,
    this.hasMoreResults = false,
    this.notice,
    this.categoryStrip,
    this.suggestionStrip,
    this.statusLine,
    this.headerAction,
  });

  /// Section title (e.g. "Products").
  final String title;

  /// Search + scan + filter controls.
  final Widget search;

  /// The scrolling product grid that fills the remaining height.
  final Widget grid;

  final bool isLoading;

  /// Number of products currently loaded; rendered as a pill beside the title.
  final int? resultCount;

  /// Whether more results can still be paged in (adds a "+" to the count).
  final bool hasMoreResults;

  /// Optional inline notice shown under the header (e.g. sample-data warning).
  final Widget? notice;

  /// Optional quick-access category chip strip.
  final Widget? categoryStrip;

  /// Optional strip of one-tap suggestions between the categories and the grid.
  /// Null — not an empty box — when there is nothing to suggest, so the grid
  /// never shifts under the buyer as suggestions arrive or run out.
  final Widget? suggestionStrip;

  /// Optional status line shown above the grid (e.g. barcode scan feedback).
  final Widget? statusLine;

  /// Optional action at the end of the header row (e.g. "new product"). It
  /// sits beside the title rather than in the search row so it never eats the
  /// width a scanner-driven lookup field needs.
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.compactPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CatalogHeader(
            title: title,
            resultCount: resultCount,
            hasMoreResults: hasMoreResults,
            isLoading: isLoading,
            action: headerAction,
          ),
          if (notice != null) ...[SizedBox(height: spacing.sm), notice!],
          SizedBox(height: spacing.md),
          search,
          if (categoryStrip != null) ...[
            SizedBox(height: spacing.sm),
            categoryStrip!,
          ],
          if (suggestionStrip != null) ...[
            SizedBox(height: spacing.sm),
            suggestionStrip!,
          ],
          if (statusLine != null) ...[
            SizedBox(height: spacing.sm),
            statusLine!,
          ],
          SizedBox(height: spacing.md),
          Expanded(child: _CatalogGridSurface(child: grid)),
        ],
      ),
    );
  }
}

class _CatalogHeader extends StatelessWidget {
  const _CatalogHeader({
    required this.title,
    required this.resultCount,
    required this.hasMoreResults,
    required this.isLoading,
    this.action,
  });

  final String title;
  final int? resultCount;
  final bool hasMoreResults;
  final bool isLoading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    // Title and count are one group that hugs the start; the action belongs at
    // the far end. Getting there needs the group to be the flexible one.
    //
    // It used to be `Flexible(title) … Spacer() … action`, and both of those
    // carry flex 1 — so they split the free space in half, the title used only
    // what it needed, and the leftover collected *after* the action. That left
    // the button stranded mid-header with empty space beyond it, on this pane
    // and on purchasing's.
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleLarge?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (resultCount != null) ...[
                const SizedBox(width: 10),
                _CountPill(count: resultCount!, hasMore: hasMoreResults),
              ],
            ],
          ),
        ),
        ?action,
        if (isLoading)
          const Padding(
            padding: EdgeInsetsDirectional.only(start: 8),
            child: SizedBox.square(
              dimension: 18,
              child: PointySpinner(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.hasMore});

  final int count;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Text(
          hasMore ? '$count+' : '$count',
          style: PointyTypography.numeric(
            textTheme.labelMedium ?? const TextStyle(),
          ).copyWith(color: colors.mutedInk, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// The framed white surface that holds the product grid, lifting it off the
/// warm page background.
class _CatalogGridSurface extends StatelessWidget {
  const _CatalogGridSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.all(spacing.sm),
        child: child,
      ),
    );
  }
}
