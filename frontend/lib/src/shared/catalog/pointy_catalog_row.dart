import 'package:flutter/material.dart';

import '../design/design.dart';
import 'pointy_catalog_table.dart';
import 'pointy_product_card.dart';
import 'pointy_product_image_frame.dart';

/// One product as a row of a [PointyCatalogTable] — the table's counterpart of
/// [PointyProductCard]. The same facts and the same in-order treatment (a
/// tint and a quantity badge), laid out to be read down a column instead of
/// scanned across a grid.
class PointyCatalogRow extends StatelessWidget {
  const PointyCatalogRow({
    super.key,
    required this.title,
    required this.priceLabel,
    required this.imageUrl,
    this.sku,
    this.barcode,
    this.stock,
    this.status,
    this.onTap,
    this.enabled = true,
    this.cartQuantity = 0,
  });

  final String title;
  final String priceLabel;
  final String? imageUrl;
  final String? sku;
  final String? barcode;

  /// The stock cell. Null for a product that keeps no stock — a service, a
  /// dish made to order — which shows a dash rather than a misleading zero.
  final Widget? stock;

  /// An exception flag beside the name (an inactive product), like the card's.
  final Widget? status;
  final VoidCallback? onTap;
  final bool enabled;

  /// Quantity of this product already in the open order. Above zero the row
  /// is tinted and its add cue becomes a count.
  final double cartQuantity;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final resolvedSku = sku?.trim() ?? '';
    final resolvedBarcode = barcode?.trim() ?? '';
    final inCart = cartQuantity > 0;
    final muted = textTheme.bodyMedium?.copyWith(color: colors.mutedInk);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = PointyCatalogTableColumns.forWidth(
          constraints.maxWidth,
        );

        return Semantics(
          button: onTap != null,
          enabled: enabled,
          selected: inCart,
          child: Opacity(
            opacity: enabled ? 1 : 0.58,
            child: Material(
              color: inCart
                  ? Color.alphaBlend(
                      colors.primaryStrong.withValues(alpha: 0.07),
                      colors.surface,
                    )
                  : colors.surface,
              child: InkWell(
                onTap: enabled ? onTap : null,
                overlayColor: PointyComponentStyles.inkOverlay(
                  colors.primaryStrong,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      PointyCatalogTableColumns.startInset,
                      8,
                      PointyCatalogTableColumns.endInset,
                      8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _ProductCell(
                            title: title,
                            sku: resolvedSku,
                            imageUrl: imageUrl,
                            status: status,
                          ),
                        ),
                        if (columns.showBarcode) ...[
                          const SizedBox(width: PointyCatalogTableColumns.gap),
                          SizedBox(
                            width: PointyCatalogTableColumns.barcodeWidth,
                            child: Text(
                              resolvedBarcode.isEmpty ? '—' : resolvedBarcode,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PointyTypography.numeric(
                                muted ?? const TextStyle(),
                              ),
                            ),
                          ),
                        ],
                        if (columns.showStock) ...[
                          const SizedBox(width: PointyCatalogTableColumns.gap),
                          SizedBox(
                            width: PointyCatalogTableColumns.stockWidth,
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: stock ?? Text('—', style: muted),
                            ),
                          ),
                        ],
                        const SizedBox(width: PointyCatalogTableColumns.gap),
                        SizedBox(
                          width: columns.priceWidth,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              priceLabel,
                              maxLines: 1,
                              style:
                                  PointyTypography.numeric(
                                    textTheme.titleSmall ?? const TextStyle(),
                                  ).copyWith(
                                    color: colors.primaryStrong,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(width: PointyCatalogTableColumns.gap),
                        SizedBox(
                          width: PointyCatalogTableColumns.actionWidth,
                          child: Center(
                            child: inCart
                                ? PointyCartQuantityBadge(
                                    quantity: cartQuantity,
                                  )
                                : PointyAddToOrderCue(enabled: enabled),
                          ),
                        ),
                      ],
                    ),
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

class _ProductCell extends StatelessWidget {
  const _ProductCell({
    required this.title,
    required this.sku,
    required this.imageUrl,
    required this.status,
  });

  final String title;
  final String sku;
  final String? imageUrl;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        PointyProductImageFrame(
          imageUrl: imageUrl,
          fallbackText: title,
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(4),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                  ),
                  if (status != null) ...[const SizedBox(width: 6), status!],
                ],
              ),
              if (sku.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  sku,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
