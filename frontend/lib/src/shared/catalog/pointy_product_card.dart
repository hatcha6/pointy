import 'package:flutter/material.dart';

import '../design/design.dart';
import 'pointy_product_image_frame.dart';

/// Catalog tile used across the POS and purchasing catalogs.
///
/// The card is built for fast, touch-first scanning: a large product image,
/// the name, and one decision-critical line — the **price** at the POS, the
/// **stock status** when restocking. When the product is already in the open
/// order it gains a quantity badge and a selected border so the operator can
/// see what they have added without looking away at the cart.
class PointyProductCard extends StatelessWidget {
  const PointyProductCard({
    super.key,
    required this.title,
    required this.priceLabel,
    required this.imageUrl,
    required this.fallbackText,
    this.sku,
    this.status,
    this.stockLabel,
    this.onTap,
    this.enabled = true,
    this.cartQuantity = 0,
  });

  final String title;
  final String priceLabel;
  final String? imageUrl;
  final String fallbackText;
  final String? sku;
  final Widget? status;

  /// Secondary information shown in place of the price when [priceLabel] is
  /// empty (used by purchasing to surface stock instead of a sale price).
  final Widget? stockLabel;
  final VoidCallback? onTap;
  final bool enabled;

  /// Quantity of this product already in the open cart/draft. When greater
  /// than zero the card shows a badge and a selected treatment.
  final double cartQuantity;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final resolvedSku = sku?.trim() ?? '';
    final resolvedPrice = priceLabel.trim();
    final inCart = cartQuantity > 0;
    final inCartFill = Color.alphaBlend(
      colors.primaryStrong.withValues(alpha: 0.07),
      colors.surface,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isCompact = width < 190;
        final cardPadding = isCompact ? 8.0 : 10.0;
        final contentGap = isCompact ? 6.0 : 8.0;
        final imagePadding = isCompact ? 8.0 : 12.0;

        return Semantics(
          button: onTap != null,
          enabled: enabled,
          selected: inCart,
          child: Opacity(
            opacity: enabled ? 1 : 0.58,
            child: Material(
              color: inCart ? inCartFill : colors.surface,
              elevation: enabled ? 1 : 0,
              shadowColor: colors.ink.withValues(alpha: 0.08),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PointyRadii.card),
                side: BorderSide(
                  color: inCart
                      ? colors.primaryStrong
                      : colors.line.withValues(alpha: 0.88),
                  width: inCart ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: enabled ? onTap : null,
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.pressed)) {
                    return colors.primaryStrong.withValues(alpha: 0.10);
                  }
                  if (states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)) {
                    return colors.primaryStrong.withValues(alpha: 0.05);
                  }
                  return null;
                }),
                child: Padding(
                  padding: EdgeInsetsDirectional.all(cardPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: PointyProductImageFrame(
                                imageUrl: imageUrl,
                                fallbackText: fallbackText,
                                padding: EdgeInsets.all(imagePadding),
                                backgroundColor: Color.alphaBlend(
                                  colors.primaryStrong.withValues(alpha: 0.035),
                                  colors.subtleFill,
                                ),
                                border: Border.all(
                                  color: colors.line.withValues(alpha: 0.52),
                                ),
                              ),
                            ),
                            if (status != null)
                              PositionedDirectional(
                                top: 8,
                                start: 8,
                                child: _ProductCardBadge(child: status!),
                              ),
                            if (inCart)
                              PositionedDirectional(
                                top: 8,
                                end: 8,
                                child: _CartQuantityBadge(
                                  quantity: cartQuantity,
                                ),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: contentGap),
                      if (resolvedSku.isNotEmpty) ...[
                        Text(
                          resolvedSku,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.mutedInk,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: isCompact ? 3 : 4),
                      ],
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (isCompact
                                    ? theme.textTheme.titleSmall
                                    : theme.textTheme.titleMedium)
                                ?.copyWith(
                                  color: colors.ink,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                ),
                      ),
                      if (resolvedPrice.isNotEmpty) ...[
                        SizedBox(height: contentGap),
                        _CardFooterRow(
                          enabled: enabled,
                          child: Text(
                            resolvedPrice,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colors.primaryStrong,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ] else if (stockLabel != null) ...[
                        SizedBox(height: contentGap),
                        _CardFooterRow(enabled: enabled, child: stockLabel!),
                      ] else if (onTap != null) ...[
                        SizedBox(height: contentGap),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: _ProductCardActionCue(enabled: enabled),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A bottom row pairing a primary label (price/stock) with the add-to-order
/// action cue, kept on one baseline so every card lines up.
class _CardFooterRow extends StatelessWidget {
  const _CardFooterRow({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: child),
        const SizedBox(width: 8),
        _ProductCardActionCue(enabled: enabled),
      ],
    );
  }
}

class _ProductCardBadge extends StatelessWidget {
  const _ProductCardBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        border: Border.all(color: colors.line.withValues(alpha: 0.72)),
      ),
      child: child,
    );
  }
}

/// Filled badge showing how many of this product are already in the order.
class _CartQuantityBadge extends StatelessWidget {
  const _CartQuantityBadge({required this.quantity});

  final double quantity;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: colors.primaryStrong,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        border: Border.all(color: colors.surface, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: colors.ink.withValues(alpha: 0.16),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        _formatQuantity(quantity),
        maxLines: 1,
        style: PointyTypography.numeric(
          theme.textTheme.labelMedium ?? const TextStyle(),
        ).copyWith(color: colors.surface, fontWeight: FontWeight.w900),
      ),
    );
  }

  static String _formatQuantity(double quantity) {
    if (quantity == quantity.roundToDouble()) {
      return quantity.toInt().toString();
    }
    return quantity.toStringAsFixed(quantity < 10 ? 1 : 0);
  }
}

class _ProductCardActionCue extends StatelessWidget {
  const _ProductCardActionCue({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final cueColor = enabled ? colors.primaryStrong : colors.mutedInk;

    return SizedBox.square(
      dimension: 30,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cueColor.withValues(alpha: enabled ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(PointyRadii.card),
          border: Border.all(color: cueColor.withValues(alpha: 0.12)),
        ),
        child: Icon(
          Icons.add_shopping_cart_outlined,
          size: 17,
          color: cueColor,
        ),
      ),
    );
  }
}
