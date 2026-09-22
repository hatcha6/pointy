import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../shared/components/pointy_progress.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/units.dart';

/// The resting surface of a counting session: the search itself.
///
/// It used to be a welcome card with a "search" button that opened a modal
/// sheet. A counter reaches for the search between every pair of items — most
/// of what is on a shelf has no barcode worth scanning — so the dialog cost two
/// taps, a route transition, and a fresh empty list every single time. The
/// field lives here instead, always focused, so a wedge scan and a typed name
/// land in the same place.
///
/// Pure (no view model) so it renders in previews and widget tests.
class StockCountSearchPanel extends StatefulWidget {
  const StockCountSearchPanel({
    super.key,
    required this.term,
    required this.results,
    required this.onSearch,
    required this.onPick,
    this.onSubmit,
    this.isLoading = false,
    this.hasError = false,
    this.hasMore = false,
    this.onLoadMore,
    this.onRetry,
    this.onCamera,
    this.countedQuantityFor,
    this.autofocus = true,
    this.searchFocusNode,
  });

  final String term;
  final List<ProductVariant> results;
  final ValueChanged<String> onSearch;

  /// Enter on the field: resolve the term and take its best match. The caller
  /// is what says so when nothing matched.
  final Future<void> Function(String term)? onSubmit;
  final ValueChanged<ProductVariant> onPick;
  final bool isLoading;
  final bool hasError;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetry;
  final VoidCallback? onCamera;

  /// What this counter has already entered for a variant, so a row they have
  /// done reads as done. Blind-safe: it is their own number, never the
  /// system's.
  final double? Function(int variantId)? countedQuantityFor;

  /// Whether the field takes focus on open. True on the counting screen (the
  /// scanner types into it, exactly as the till's catalog search does) and
  /// false in the board preview, where four panels would fight over the caret.
  final bool autofocus;
  final FocusNode? searchFocusNode;

  @override
  State<StockCountSearchPanel> createState() => _StockCountSearchPanelState();
}

class _StockCountSearchPanelState extends State<StockCountSearchPanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || widget.isLoading || !widget.hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      widget.onLoadMore?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.lg,
            spacing.md,
            spacing.lg,
            spacing.sm,
          ),
          child: AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Row(
              children: [
                Expanded(
                  child: DebouncedSearchField(
                    key: const ValueKey('stock_count_search_field'),
                    value: widget.term,
                    hintText: l10n.stockCountSearchHint,
                    clearTooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    autofocus: widget.autofocus,
                    focusNode: widget.searchFocusNode,
                    onChanged: widget.onSearch,
                    // Enter takes the best match and moves on. Returning
                    // false keeps the term in the field: a miss should leave
                    // the word there to be corrected, not wipe it — and a hit
                    // has already replaced this whole surface.
                    onSubmitted: widget.onSubmit == null
                        ? null
                        : (term) async {
                            await widget.onSubmit!(term);
                            return false;
                          },
                  ),
                ),
                if (widget.onCamera != null) ...[
                  SizedBox(width: spacing.sm),
                  IconButton.filledTonal(
                    tooltip: l10n.stockCountCameraScan,
                    onPressed: widget.onCamera,
                    icon: const Icon(Icons.document_scanner_outlined),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(child: _results(context, l10n)),
      ],
    );
  }

  Widget _results(BuildContext context, AppLocalizations l10n) {
    if (widget.hasError) {
      return _CenteredNote(
        icon: Icons.error_outline,
        message: l10n.stockCountSearchLoadError,
        action: widget.onRetry == null
            ? null
            : TextButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryButton),
              ),
      );
    }
    if (widget.results.isEmpty) {
      if (widget.isLoading) {
        return const Center(child: PointySpinner());
      }
      return _CenteredNote(
        icon: widget.term.isEmpty
            ? Icons.qr_code_scanner_rounded
            : Icons.search_off,
        message: widget.term.isEmpty
            ? l10n.stockCountScanPrompt
            : l10n.stockCountSearchEmpty,
        secondary: widget.term.isEmpty ? l10n.stockCountScanHint : null,
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    final trailingRows = widget.hasMore || widget.isLoading ? 1 : 0;
    return AdaptiveMaxWidth(
      width: AppContentWidth.detail,
      child: ListView.separated(
        controller: _scrollController,
        padding: EdgeInsetsDirectional.fromSTEB(
          spacing.lg,
          spacing.xs,
          spacing.lg,
          spacing.lg,
        ),
        itemCount: widget.results.length + trailingRows,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          if (index >= widget.results.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: PointySpinner()),
            );
          }
          final variant = widget.results[index];
          return StockCountSearchRow(
            variant: variant,
            countedQuantity: widget.countedQuantityFor?.call(variant.id),
            onTap: () => widget.onPick(variant),
          );
        },
      ),
    );
  }
}

/// One item on the search list. Shared with the unknown-scan picker sheet so
/// both surfaces read the same.
class StockCountSearchRow extends StatelessWidget {
  const StockCountSearchRow({
    super.key,
    required this.variant,
    required this.onTap,
    this.countedQuantity,
  });

  final ProductVariant variant;
  final VoidCallback onTap;

  /// This counter's own entry for the item, when they have already counted it.
  final double? countedQuantity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final counted = countedQuantity;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: Row(
            children: [
              ProductImageThumbnail(
                imageUrl: variant.primaryImage?.contentUrl,
                fallbackText: variant.displayLabel,
                size: 44,
                borderRadius: 10,
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      variant.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (variant.sku.isNotEmpty)
                      Text(
                        variant.sku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              if (counted != null)
                _CountedBadge(
                  label: l10n.stockCountAlreadyCounted(formatQuantity(counted)),
                )
              else
                Icon(Icons.add_circle_outline, color: colors.primaryStrong),
            ],
          ),
        ),
      ),
    );
  }
}

/// "You counted N" — the counter's own answer, coming back to them.
class _CountedBadge extends StatelessWidget {
  const _CountedBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 14, color: colors.success),
          const SizedBox(width: 4),
          Text(
            label,
            style: PointyTypography.numeric(
              textTheme.labelSmall ?? const TextStyle(),
            ).copyWith(color: colors.success, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _CenteredNote extends StatelessWidget {
  const _CenteredNote({
    required this.icon,
    required this.message,
    this.secondary,
    this.action,
  });

  final IconData icon;
  final String message;
  final String? secondary;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final detail = secondary;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.lineStrong),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.titleSmall?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
