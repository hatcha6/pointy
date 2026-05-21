import 'package:flutter/material.dart';

import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import 'formatters.dart';
import 'product_status_pill.dart';

class ProductTile extends StatelessWidget {
  ProductTile({
    super.key,
    required Product product,
    required this.onTap,
    this.showPrice = true,
  }) : title = product.sellableName,
       sku = product.effectiveSku,
       unitPrice = product.effectiveUnitPrice,
       isActive = product.isActive;

  ProductTile.variant({
    super.key,
    required ProductVariant variant,
    required this.onTap,
    this.showPrice = true,
  }) : title = variant.displayLabel,
       sku = variant.sku,
       unitPrice = variant.unitPrice,
       isActive = variant.isSellable;

  final VoidCallback? onTap;
  final bool showPrice;
  final String title;
  final String sku;
  final double unitPrice;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  ProductStatusPill(isActive: isActive, compact: true),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (showPrice) ...[
                const SizedBox(height: 10),
                Text(
                  formatMoney(unitPrice),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
