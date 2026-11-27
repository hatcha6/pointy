import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../design/cards_tokens.dart';
import '../../shared/money_text.dart';
import '../../shared/quantity_stepper.dart';

/// The frosted bar under the thumb on a brand's (or a bundle's) page: the
/// total, how many, and the one button.
/// The frosted bar: the total on one side, the quantity and the button on the
/// other — the way a booking bar is laid out.
class BuyBar extends StatelessWidget {
  const BuyBar({
    super.key,
    required this.total,
    required this.quantity,
    required this.enabled,
    required this.onQuantity,
    required this.onBuy,
    this.webOnly = false,
    this.floating = false,
    this.note,
    this.actionLabel,
  });

  final Money total;
  final int quantity;
  final bool enabled;

  /// Bought on the website only: the bar says so, with no way to pay.
  final bool webOnly;
  final ValueChanged<int> onQuantity;
  final VoidCallback onBuy;

  /// A glass panel floating over the page (beside the card on a wide
  /// screen), rather than a bar across the bottom edge.
  final bool floating;

  /// In place of the card count and the quantity: where a top-up goes.
  final String? note;

  /// In place of «اشترِ».
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final row = webOnly
        ? const WebOnlyNote()
        : Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        formatMoney(l10n, total),
                        style: PointyTypography.numeric(
                          theme.textTheme.titleLarge!,
                        ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: CardsMotion.fast,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [...previous, ?current],
                      ),
                      child: Text(
                        note ?? l10n.cardCount(quantity),
                        key: ValueKey(note),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (note == null) ...[
                QuantityStepper(value: quantity, onChanged: onQuantity),
                const SizedBox(width: CardsSpace.sm),
              ],
              SizedBox(
                width: 112,
                child: FilledButton(
                  onPressed: enabled ? onBuy : null,
                  child: Text(actionLabel ?? l10n.buyNow),
                ),
              ),
            ],
          );
    final glass = theme.colorScheme.surface.withValues(alpha: 0.86);
    if (floating) {
      final radius = BorderRadius.circular(CardsRadii.sheet);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          MediaQuery.paddingOf(context).bottom + CardsSpace.lg,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: CardsShadows.hero,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: glass,
                  borderRadius: radius,
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    CardsSpace.xl,
                    CardsSpace.md,
                    CardsSpace.md,
                    CardsSpace.md,
                  ),
                  child: row,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: glass,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline, width: 0.8),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.md,
                CardsSpace.gutter,
                CardsSpace.md,
              ),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// In place of the buy button on a card bought on the website only: where
/// to find it, and nothing to tap.
class WebOnlyNote extends StatelessWidget {
  const WebOnlyNote({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.language_rounded,
              size: 20,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.webOnlyTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.webOnlyBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
