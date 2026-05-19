import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order_line_tile.dart';

class CartLineTile extends StatelessWidget {
  const CartLineTile({
    super.key,
    required this.line,
    required this.onAdd,
    required this.onRemove,
  });

  final CartLine line;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return OrderLineTile(
      product: line.product,
      quantity: line.quantity,
      totalAmount: line.total,
      unitLabel: l10n.unitPriceEach(formatMoney(line.product.unitPrice)),
      addTooltip: l10n.addOneTooltip,
      removeTooltip: l10n.removeOneTooltip,
      onAdd: onAdd,
      onRemove: onRemove,
    );
  }
}
