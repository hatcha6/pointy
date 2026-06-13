import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';

class CartLineTile extends StatelessWidget {
  const CartLineTile({
    super.key,
    required this.line,
    required this.onAdd,
    required this.onRemove,
    this.onDelete,
    this.onEditQuantity,
  });

  final CartLine line;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final VoidCallback? onDelete;

  /// Weighted lines open a weight-entry dialog instead of stepping by one.
  final VoidCallback? onEditQuantity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyOrderLineTile(
      title: line.variant.productLabel,
      subtitle: line.variant.variantLabel,
      detail: line.variant.sku,
      unitPriceLabel: l10n.unitPriceEach(formatMoney(line.variant.unitPrice)),
      totalLabel: formatMoney(line.total),
      quantity: line.quantity,
      imageUrl:
          line.variant.primaryImage?.contentUrl ??
          line.variant.productDetail?.primaryImage?.contentUrl,
      incrementTooltip: l10n.addOneTooltip,
      decrementTooltip: l10n.removeOneTooltip,
      removeTooltip: l10n.removeCartLineTooltip,
      onIncrement: onAdd,
      onDecrement: onRemove,
      onRemove: onDelete,
      onQuantityTap: line.variant.unit == 'piece' ? null : onEditQuantity,
    );
  }
}
