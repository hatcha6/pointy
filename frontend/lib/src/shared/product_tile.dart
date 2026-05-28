import 'package:flutter/material.dart';

import '../core/analytics_interaction_tracker.dart';
import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import 'formatters.dart';
import 'catalog/catalog.dart';
import 'product_status_pill.dart';

class ProductTile extends StatelessWidget {
  ProductTile({
    super.key,
    required Product product,
    required this.onTap,
    this.showPrice = true,
  }) : title = product.name,
       sku = product.effectiveSku,
       unitPrice = product.effectiveUnitPrice,
       isActive = product.isActive,
       imageUrl = product.primaryImage?.contentUrl;

  ProductTile.variant({
    super.key,
    required ProductVariant variant,
    required this.onTap,
    this.showPrice = true,
  }) : title = variant.displayLabel,
       sku = variant.sku,
       unitPrice = variant.unitPrice,
       isActive = variant.isSellable,
       imageUrl =
           variant.primaryImage?.contentUrl ??
           variant.productDetail?.primaryImage?.contentUrl;

  final VoidCallback? onTap;
  final bool showPrice;
  final String title;
  final String sku;
  final double unitPrice;
  final bool isActive;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
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
