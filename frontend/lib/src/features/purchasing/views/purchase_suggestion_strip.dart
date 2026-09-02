import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../data/models/purchase_suggestion.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/units.dart';
import '../view_models/purchase_view_model.dart';

/// A single row of chips above the catalog grid: the products this shop
/// habitually buys next from the chosen supplier, each one tap from being a
/// draft line at its usual quantity.
///
/// The strip is decoration and behaves like it. It renders nothing at all when
/// there is nothing confident to say — no empty state, no placeholder, no
/// reserved band that shifts the grid — it never takes focus, and it keeps
/// showing the previous answer while a new one loads rather than blinking.
class PurchaseSuggestionStrip extends StatelessWidget {
  const PurchaseSuggestionStrip({super.key, required this.viewModel});

  final PurchaseViewModel viewModel;

  /// The strip's slot in the catalog pane, or null when it has nothing to show.
  /// Returning null (rather than a zero-height box) is what keeps the grid from
  /// moving when suggestions arrive or run out.
  static Widget? maybeBuild(PurchaseViewModel viewModel) {
    final controller = viewModel.suggestions;
    if (!controller.isVisible || !controller.hasAnything) {
      return null;
    }
    return PurchaseSuggestionStrip(viewModel: viewModel);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final controller = viewModel.suggestions;
    final basket = controller.usualBasket;
    final items = controller.items;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.only(end: spacing.sm),
          child: Icon(
            Icons.auto_awesome_outlined,
            size: 18,
            color: colors.mutedInk,
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: items.length + (basket.available ? 1 : 0),
              separatorBuilder: (_, _) => SizedBox(width: spacing.sm),
              itemBuilder: (context, index) {
                if (basket.available && index == 0) {
                  return _UsualBasketChip(viewModel: viewModel);
                }
                final item = items[index - (basket.available ? 1 : 0)];
                return _SuggestionChip(viewModel: viewModel, suggestion: item);
              },
            ),
          ),
        ),
        IconButton(
          tooltip: l10n.purchaseSuggestionsHideTooltip,
          onPressed: controller.collapse,
          icon: const Icon(Icons.close),
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: colors.mutedInk,
        ),
      ],
    );
  }
}

/// One suggested product. Tapping adds the line; long-pressing offers to stop
/// suggesting it. The trailing quantity appears only when the shop's history
/// actually supports one — a chip with no quantity still saves the lookup.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.viewModel, required this.suggestion});

  final PurchaseViewModel viewModel;
  final PurchaseSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final enabled = !viewModel.isSubmitting;

    return Tooltip(
      message: _reasonText(context),
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        onTap: enabled ? () => _accept(context) : null,
        onLongPress: enabled ? () => _mute(context) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 16, color: colors.primaryStrong),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  suggestion.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (suggestion.hasQuantity) ...[
                const SizedBox(width: 8),
                Text(
                  _quantityLabel(context),
                  maxLines: 1,
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _quantityLabel(BuildContext context) {
    final quantity = formatQuantity(suggestion.suggestedQuantity ?? 0);
    final unit = unitLabel(AppLocalizations.of(context)!, suggestion.unitCode);
    return '× $quantity $unit';
  }

  /// The chip's own justification, in the buyer's words. A suggestion nobody
  /// can account for is one nobody should act on.
  String _reasonText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (suggestion.reason) {
      case PurchaseSuggestionReason.oftenWith:
        final anchorId = suggestion.anchorVariantId;
        final anchor = anchorId == null
            ? null
            : viewModel.draft
                  .where((line) => line.variant.id == anchorId)
                  .firstOrNull;
        if (anchor != null) {
          return l10n.purchaseSuggestionReasonOftenWith(
            anchor.variant.productLabel,
          );
        }
        return l10n.purchaseSuggestionReasonUsual;
      case PurchaseSuggestionReason.dueAgain:
        return l10n.purchaseSuggestionReasonDueAgain(
          suggestion.daysSinceLast ?? 0,
        );
      case PurchaseSuggestionReason.usualForSupplier:
        return l10n.purchaseSuggestionReasonUsual;
    }
  }

  Future<void> _accept(BuildContext context) async {
    await viewModel.acceptSuggestion(suggestion);
    // Focus goes back to search once the line lands, exactly as a catalog tap
    // does — the buyer's next move is a scan or a lookup either way.
    viewModel.requestSearchFocus();
  }

  void _mute(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    viewModel.suggestions.mute(suggestion.variantId);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.purchaseSuggestionMutedMessage(suggestion.productName),
          ),
        ),
      );
  }
}

/// Fills the draft with this supplier's recurring order in one tap, with a
/// single Undo. A bulk add the buyer cannot take back in one gesture would be
/// an imposition, which is the one thing this feature must never be.
class _UsualBasketChip extends StatelessWidget {
  const _UsualBasketChip({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final basket = viewModel.suggestions.usualBasket;
    final enabled = !viewModel.isSubmitting;

    return InkWell(
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      onTap: enabled ? () => _fill(context) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          border: Border.all(color: colors.primaryStrong),
          borderRadius: BorderRadius.circular(PointyRadii.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add, size: 16, color: colors.primaryDark),
            const SizedBox(width: 6),
            Text(
              l10n.purchaseUsualBasketChip(basket.lineCount),
              maxLines: 1,
              style: textTheme.labelLarge?.copyWith(
                color: colors.primaryDark,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fill(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final added = await viewModel.fillUsualBasket();
    if (added.isEmpty) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.purchaseUsualBasketFilledMessage(added.length)),
          action: SnackBarAction(
            label: l10n.undoButton,
            onPressed: () {
              for (final variantId in added) {
                viewModel.removeLine(
                  variantId,
                  source: 'purchase_suggestion_basket_undo',
                );
              }
            },
          ),
        ),
      );
    viewModel.requestSearchFocus();
  }
}

/// The "usual 12" chip on a draft line: the quantity this shop repeatedly buys
/// this product in, one tap from being the line's quantity.
///
/// Deliberately not auto-filled. A purchase quantity becomes stock and becomes
/// cost basis, so it gets a tap — and the chip vanishes the moment the buyer
/// types a quantity of their own.
class PurchaseQuantityHintChip extends StatelessWidget {
  const PurchaseQuantityHintChip({
    super.key,
    required this.viewModel,
    required this.line,
  });

  final PurchaseViewModel viewModel;
  final PurchaseDraftLine line;

  /// The chip, or null when this shop's history has no quantity to offer for
  /// this line. Null rather than an empty box: a line with no hint has to be
  /// exactly as tall as it was before this feature existed.
  static Widget? maybeBuild({
    required PurchaseViewModel viewModel,
    required PurchaseDraftLine line,
  }) {
    if (viewModel.isSubmitting || viewModel.quantityHintFor(line) == null) {
      return null;
    }
    return PurchaseQuantityHintChip(viewModel: viewModel, line: line);
  }

  @override
  Widget build(BuildContext context) {
    final hint = viewModel.quantityHintFor(line);
    if (hint == null || viewModel.isSubmitting) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final quantity = formatQuantity(hint.suggestedQuantity ?? 0);
    final unit = unitLabel(l10n, hint.unitCode);

    return Tooltip(
      message: l10n.purchaseSuggestionQuantityHintTooltip(quantity, unit),
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => viewModel.applySuggestedQuantity(line, hint),
          child: Padding(
            // A real tap target for a finger on a delivery bay, not a badge.
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history, size: 15, color: colors.primaryDark),
                const SizedBox(width: 5),
                Text(
                  // Carries the unit: "12" alone is the difference between a
                  // dozen bottles and twelve cartons of them.
                  l10n.purchaseSuggestionQuantityHint(quantity, unit),
                  maxLines: 1,
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.primaryDark,
                    fontWeight: FontWeight.w700,
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
