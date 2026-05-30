import 'package:flutter/material.dart';

import '../design/design.dart';
import 'pointy_product_image_frame.dart';

class PointyProductCard extends StatelessWidget {
  const PointyProductCard({
    super.key,
    required this.title,
    required this.priceLabel,
    required this.imageUrl,
    required this.fallbackText,
    this.sku,
    this.status,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String priceLabel;
  final String? imageUrl;
  final String fallbackText;
  final String? sku;
  final Widget? status;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final resolvedSku = sku?.trim() ?? '';
    final resolvedPrice = priceLabel.trim();

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
          child: Opacity(
            opacity: enabled ? 1 : 0.58,
            child: Material(
              color: colors.surface,
              elevation: enabled ? 1 : 0,
              shadowColor: colors.ink.withValues(alpha: 0.08),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PointyRadii.card),
                side: BorderSide(color: colors.line.withValues(alpha: 0.88)),
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
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
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
                            const SizedBox(width: 8),
                            _ProductCardActionCue(enabled: enabled),
                          ],
                        ),
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

class _ProductCardBadge extends StatelessWidget {
  const _ProductCardBadge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.line.withValues(alpha: 0.72)),
      ),
      child: child,
    );
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
