import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';

class ProductDetailsHero extends StatelessWidget {
  const ProductDetailsHero({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sku = product.effectiveSku.trim();
    final barcode = product.effectiveBarcode.trim();

    return PointyDetailHero(
      icon: Icons.sell_outlined,
      title: product.name,
      value: formatMoney(product.effectiveUnitPrice),
      valueSubtitle: l10n.productPriceTitle,
      pills: [
        if (sku.isNotEmpty)
          PointyHeroPill(label: sku, icon: Icons.tag_outlined),
        if (barcode.isNotEmpty)
          PointyHeroPill(label: barcode, icon: Icons.qr_code_2),
      ],
    );
  }
}
