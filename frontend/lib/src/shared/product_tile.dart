import 'package:flutter/material.dart';

import '../core/analytics_interaction_tracker.dart';
import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import 'formatters.dart';
import 'catalog/pointy_product_card.dart';
import 'catalog/pointy_product_row.dart';
import 'product_status_pill.dart';

class ProductTile extends StatelessWidget {
  ProductTile({
    super.key,
    required Product product,
    required this.onTap,
    this.showPrice = true,
  }) : title = product.name,
       sku = product.effectiveSku,
       barcode = product.effectiveBarcode,
       unitPrice = product.effectiveUnitPrice,
       quantityOnHand = product.effectiveQuantityOnHand,
       isActive = product.isActive,
       imageUrl = product.primaryImage?.contentUrl,
       _product = product,
       _presentation = _ProductTilePresentation.card,
       _tableLayout = false;

  ProductTile.variant({
    super.key,
    required ProductVariant variant,
    required this.onTap,
    this.showPrice = true,
  }) : title = variant.displayLabel,
       sku = variant.sku,
       barcode = variant.barcode,
       unitPrice = variant.unitPrice,
       quantityOnHand = variant.quantityOnHand,
       isActive = variant.isSellable,
       imageUrl =
           variant.primaryImage?.contentUrl ??
           variant.productDetail?.primaryImage?.contentUrl,
       _product = null,
       _presentation = _ProductTilePresentation.card,
       _tableLayout = false;

  ProductTile.catalogRow({
    super.key,
    required Product product,
    required this.onTap,
    required bool tableLayout,
  }) : title = product.name,
       sku = product.effectiveSku,
       barcode = product.effectiveBarcode,
       unitPrice = product.effectiveUnitPrice,
       quantityOnHand = product.effectiveQuantityOnHand,
       isActive = product.isActive,
       imageUrl = product.primaryImage?.contentUrl,
       showPrice = true,
       _product = product,
       _presentation = _ProductTilePresentation.catalogRow,
       _tableLayout = tableLayout;

  final VoidCallback? onTap;
  final bool showPrice;
  final String title;
  final String sku;
  final String barcode;
  final double unitPrice;
  final int quantityOnHand;
  final bool isActive;
  final String? imageUrl;
  final Product? _product;
  final _ProductTilePresentation _presentation;
  final bool _tableLayout;

  @override
  Widget build(BuildContext context) {
    final product = _product;
    if (_presentation == _ProductTilePresentation.catalogRow &&
        product != null) {
      return PointyProductRow(
        product: product,
        onTap: () => _handleTap(context),
        tableLayout: _tableLayout,
      );
    }

    return PointyProductCard(
      title: title,
      sku: sku,
      priceLabel: showPrice ? formatMoney(unitPrice) : '',
      imageUrl: imageUrl,
      fallbackText: title,
      status: ProductStatusPill(isActive: isActive, compact: true),
      enabled: onTap != null,
      onTap: () => _handleTap(context),
    );
  }

  void _handleTap(BuildContext context) {
    AnalyticsInteractionTracker.track(
      context,
      action: 'product_tile_selected',
      target: 'product_tile',
      attributes: {if (sku.isNotEmpty) 'sku': sku, 'is_active': isActive},
      metrics: {'unit_price': unitPrice},
    );
    onTap?.call();
  }
}

enum _ProductTilePresentation { card, catalogRow }
