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
    this.onEditNote,
  });

  final CartLine line;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final VoidCallback? onDelete;

  /// Weighted lines open a weight-entry dialog instead of stepping by one.
  final VoidCallback? onEditQuantity;

  /// Opens the kitchen-note editor for this line. Null hides the affordance.
  final VoidCallback? onEditNote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final tile = PointyOrderLineTile(
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

    if (onEditNote == null && line.notes.trim().isEmpty) {
      return tile;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [tile, _CartLineNote(line: line, onEditNote: onEditNote)],
    );
  }
}

class _CartLineNote extends StatelessWidget {
  const _CartLineNote({required this.line, required this.onEditNote});

  final CartLine line;
  final VoidCallback? onEditNote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final note = line.notes.trim();
    final hasNote = note.isNotEmpty;

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 12, bottom: 8),
      child: InkWell(
        onTap: onEditNote,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              Icon(
                hasNote
                    ? Icons.sticky_note_2_outlined
                    : Icons.note_add_outlined,
                size: 16,
                color: hasNote ? theme.colorScheme.primary : theme.hintColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasNote ? note : l10n.cartLineNoteAdd,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: hasNote
                        ? theme.textTheme.bodyMedium?.color
                        : theme.hintColor,
                    fontStyle: hasNote ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
