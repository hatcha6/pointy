import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/formatters.dart';
import '../../../shared/units.dart';

Future<ProductVariant?> showPosVariantPickerSheet(
  BuildContext context, {
  required Product product,
  required List<ProductVariant> variants,
}) {
  return showModalBottomSheet<ProductVariant>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      return _PosVariantPickerSheet(product: product, variants: variants);
    },
  );
}

class _PosVariantPickerSheet extends StatelessWidget {
  const _PosVariantPickerSheet({required this.product, required this.variants});

  final Product product;
  final List<ProductVariant> variants;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.style_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.posVariantPickerTitle(product.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: variants.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final variant = variants[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    variant.pickerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (variant.sku.isNotEmpty) variant.sku,
                      l10n.posVariantPickerStock(
                        formatQuantity(variant.quantityOnHand),
                      ),
                      formatMoney(variant.unitPrice),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.add_circle_outline),
                  onTap: () => Navigator.of(context).pop(variant),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
