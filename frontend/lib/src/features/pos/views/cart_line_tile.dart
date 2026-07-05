import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/units.dart';

class CartLineTile extends StatelessWidget {
  const CartLineTile({
    super.key,
    required this.line,
    required this.onAdd,
    required this.onRemove,
    this.onDelete,
    this.onEditQuantity,
    this.onEditNote,
    this.onSwitchUnit,
    this.selected = false,
    this.onSelect,
  });

  final CartLine line;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final VoidCallback? onDelete;

  /// Whether this line is the keyboard-focused line (gets a highlight so the
  /// cashier can see which line +/− and numeric entry will act on).
  final bool selected;

  /// Marks this line as the keyboard-focused one when tapped.
  final VoidCallback? onSelect;

  /// Weighted / multi-unit lines open an entry sheet instead of stepping by one.
  final VoidCallback? onEditQuantity;

  /// Opens the kitchen-note editor for this line. Null hides the affordance.
  final VoidCallback? onEditNote;

  /// Opens the unit switcher for this line. Null when the product has only its
  /// base unit.
  final VoidCallback? onSwitchUnit;

  bool get _showsUnitRow =>
      onSwitchUnit != null || (!line.isBaseUnit && line.unitLabel.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final tile = PointyOrderLineTile(
      title: line.variant.productLabel,
      subtitle: line.variant.variantLabel,
      detail: line.variant.sku,
      // Effective unit price reflects the selected unit and any modifier deltas.
      unitPriceLabel: l10n.unitPriceEach(formatMoney(line.unitPrice)),
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
      // Tap-to-type stays off only for plain whole-piece lines; weighted
      // products and any multi-unit product (egg trays) open the quantity /
      // unit sheet, where fractional entry follows the unit's own rule.
      onQuantityTap:
          (line.variant.unit == 'piece' &&
              line.isBaseUnit &&
              !Product.fromVariant(line.variant).hasSellableUnits)
          ? null
          : onEditQuantity,
    );

    final hasNoteRow = onEditNote != null || line.notes.trim().isNotEmpty;
    final Widget content;
    if (line.modifiers.isEmpty && !hasNoteRow && !_showsUnitRow) {
      content = tile;
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile,
          if (_showsUnitRow)
            _CartLineUnit(line: line, onSwitchUnit: onSwitchUnit),
          if (line.modifiers.isNotEmpty) _CartLineModifiers(line: line),
          if (hasNoteRow) _CartLineNote(line: line, onEditNote: onEditNote),
        ],
      );
    }

    if (onSelect == null && !selected) {
      return content;
    }

    final colors = context.pointyColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer.withOpacity(0.35)
              : null,
          border: BorderDirectional(
            start: BorderSide(
              color: selected ? colors.primaryStrong : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: content,
      ),
    );
  }
}

class _CartLineUnit extends StatelessWidget {
  const _CartLineUnit({required this.line, this.onSwitchUnit});

  final CartLine line;
  final VoidCallback? onSwitchUnit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final unitText = line.unitLabel.isNotEmpty
        ? line.unitLabel
        : unitLabel(l10n, line.variant.unit);
    final tappable = onSwitchUnit != null;

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 12, bottom: 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onSwitchUnit,
            borderRadius: BorderRadius.circular(PointyRadii.chip),
            child: Container(
              decoration: BoxDecoration(
                color: tappable ? colors.primaryContainer : colors.subtleFill,
                borderRadius: BorderRadius.circular(PointyRadii.chip),
                border: Border.all(color: colors.line),
              ),
              padding: const EdgeInsetsDirectional.only(
                start: 10,
                end: 6,
                top: 5,
                bottom: 5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.straighten_outlined,
                    size: 15,
                    color: colors.primaryStrong,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    unitText,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // For a pack unit, show the base-unit equivalent ("= 24 قطعة").
                  if (!line.isBaseUnit) ...[
                    const SizedBox(width: 6),
                    Text(
                      '= ${formatQuantity(line.baseQuantity)} '
                      '${unitLabel(l10n, line.variant.unit)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                  if (tappable) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: colors.primaryStrong,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CartLineModifiers extends StatelessWidget {
  const _CartLineModifiers({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final label = line.modifiers
        .map(
          (modifier) => modifier.quantity > 1
              ? '${modifier.optionName} ×${modifier.quantity}'
              : modifier.optionName,
        )
        .join(' · ');

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 12, bottom: 4),
      child: Row(
        children: [
          Icon(Icons.tune_outlined, size: 16, color: colors.primaryStrong),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
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
    final colors = context.pointyColors;
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
                color: hasNote ? colors.primaryStrong : theme.hintColor,
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
