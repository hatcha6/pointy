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

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 10, 0),
                child: PointyProductImageFrame(
                  imageUrl: imageUrl,
                  fallbackText: fallbackText,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (resolvedSku.isNotEmpty) ...[
                    Text(
                      resolvedSku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (resolvedPrice.isNotEmpty || status != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: resolvedPrice.isEmpty
                              ? const SizedBox.shrink()
                              : Text(
                                  resolvedPrice,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: colors.primaryStrong,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                        if (status != null) ...[
                          const SizedBox(width: 8),
                          Flexible(child: status!),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
