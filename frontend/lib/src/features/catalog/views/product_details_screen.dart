import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../shared/detail_section.dart';
import '../../../shared/product_status_pill.dart';
import 'product_details_hero.dart';

class ProductDetailsScreen extends StatelessWidget {
  const ProductDetailsScreen({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.productDetailsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ProductDetailsHero(product: product),
            const SizedBox(height: 16),
            DetailSection(
              title: l10n.productAvailabilityTitle,
              icon: product.isActive
                  ? Icons.check_circle_outline
                  : Icons.pause_circle_outline,
              child: Row(
                children: [
                  ProductStatusPill(isActive: product.isActive),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      product.isActive
                          ? l10n.productAvailableForSale
                          : l10n.productUnavailableForSale,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DetailSection(
              title: l10n.productIdentifierTitle,
              icon: Icons.qr_code_2,
              child: Column(
                children: [
                  DetailRow(label: l10n.skuLabel, value: product.sku),
                  const Divider(height: 20),
                  DetailRow(
                    label: l10n.barcodeLabel,
                    value: product.barcode.isEmpty
                        ? l10n.noBarcode
                        : product.barcode,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DetailSection(
              title: l10n.productDescriptionTitle,
              icon: Icons.notes_outlined,
              child: Text(
                product.description.isEmpty
                    ? l10n.noDescription
                    : product.description,
              ),
            ),
          ],
        ),
      ),
      backgroundColor: colorScheme.surface,
    );
  }
}
