import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../shared/design/design.dart';
import '../../../shared/date_formatters.dart';
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
    this.onPickBatch,
    this.selected = false,
    this.onSelect,
    this.onEditPrice,
    this.unitCost,
    this.isLoadingCost = false,
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

  /// Opens the lot picker for this line. Null for everything that is not
  /// lot-tracked — which is every product in most shops.
  final VoidCallback? onPickBatch;

  /// Opens the reprice sheet. Null for anybody without
  /// `sales.override_line_price`, and for a top-up, whose price is computed
  /// from the provider's live quote and is not the shop's to set.
  final VoidCallback? onEditPrice;

  /// What one unit cost the shop, when cost is revealed (F9) and the caller
  /// may see it. Null hides the whole row, which is the state a till is in
  /// nearly all the time.
  final double? unitCost;

  /// Cost has been asked for and has not arrived yet.
  final bool isLoadingCost;

  /// Whether this line has an identity worth printing on the row: a handset's
  /// IMEI, or the lot a pharmacy is required to name.
  bool get _showsIdentityRow =>
      line.stockUnitCode.isNotEmpty ||
      line.stockBatchCode.isNotEmpty ||
      onPickBatch != null;

  bool get _showsUnitRow =>
      onSwitchUnit != null || (!line.isBaseUnit && line.unitLabel.isNotEmpty);

  /// Whether there is anything to SAY about this line's money.
  ///
  /// Doing — repricing — is no longer in here: it moved onto the per-unit
  /// price itself, because a lone pencil on a row of its own spent a whole row
  /// offering one action. Which also fixed the bug that put it here: gating
  /// the row on having a cost had hidden the pencil on every product the shop
  /// has never bought, and on every line while cost was hidden.
  bool get _showsMoneyRow =>
      unitCost != null || isLoadingCost || line.isRepriced;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // A top-up line has to say whose card it is for. The cashier is about to
    // take money for a number they typed, and the customer's card is the one
    // thing on this line nobody can check afterwards from the SKU.
    final recharge = line.integration;

    final tile = PointyOrderLineTile(
      title: line.variant.productLabel,
      subtitle: recharge == null
          ? line.variant.variantLabel
          : l10n.rechargeCartLineSubtitle(
              ltrIsolated(recharge.subscriberRef),
              recharge.months > 0
                  ? l10n.rechargeMonths(recharge.months)
                  : recharge.optionLabel,
            ),
      detail: recharge == null ? line.variant.sku : null,
      // Effective unit price reflects the selected unit and any modifier deltas.
      unitPriceLabel: l10n.unitPriceEach(formatMoney(line.unitPrice)),
      // Tap the per-unit price to change it. A pencil on a row of its own cost
      // a whole row to offer one action, on a screen where rows are how many
      // cart lines a cashier can see at once.
      onUnitPriceTap: onEditPrice,
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
      // Every line's quantity is tap-to-type editable so the cashier can enter a
      // fraction of any product; which sheet opens depends on the product's
      // units (weight entry, or the unit + quantity picker).
      // One article is one article: a serialized line has no quantity to edit,
      // and offering the sheet would be offering something the cart refuses.
      onQuantityTap: line.allowsQuantityEdit ? onEditQuantity : null,
    );

    final hasNoteRow = onEditNote != null || line.notes.trim().isNotEmpty;
    final Widget content;
    if (line.modifiers.isEmpty &&
        !hasNoteRow &&
        !_showsUnitRow &&
        !_showsMoneyRow &&
        !_showsIdentityRow) {
      content = tile;
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile,
          if (_showsIdentityRow)
            _CartLineIdentity(line: line, onPickBatch: onPickBatch),
          if (_showsUnitRow || _showsMoneyRow)
            _CartLineMeta(
              line: line,
              onSwitchUnit: _showsUnitRow ? onSwitchUnit : null,
              showsUnit: _showsUnitRow,
              unitCost: unitCost,
              isLoadingCost: isLoadingCost,
              onEditPrice: onEditPrice,
            ),
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
              ? colors.primaryContainer.withValues(alpha: 0.35)
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

/// Everything about a line that is not its name, quantity or total: the unit
/// it sells in, what it cost, the margin, and whether somebody repriced it.
///
/// ONE wrapping row, deliberately. These were two — a unit chip alone on a row
/// with most of it empty, then cost and repricing on another — which made an
/// ordinary cart line three rows tall on a till where vertical space is how
/// many lines a cashier can see at once. They wrap together now and fit on one
/// row in the common case.
///
/// Cost appears only when it has been revealed (F9) AND the person is allowed
/// to see it, which is why the row so often carries just a unit chip.
class _CartLineMeta extends StatelessWidget {
  const _CartLineMeta({
    required this.line,
    required this.showsUnit,
    required this.unitCost,
    required this.isLoadingCost,
    this.onSwitchUnit,
    this.onEditPrice,
  });

  final CartLine line;
  final bool showsUnit;
  final double? unitCost;
  final bool isLoadingCost;
  final VoidCallback? onSwitchUnit;
  final VoidCallback? onEditPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final cost = unitCost;
    final margin = cost == null ? null : line.unitPrice - cost;
    // Below cost is the thing a cashier must not miss while deciding, so it is
    // the one state that gets a colour rather than a shade of grey.
    final marginColor = margin == null
        ? colors.mutedInk
        : (margin < 0 ? colors.danger : colors.success);

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 12, bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (showsUnit) _CartLineUnit(line: line, onSwitchUnit: onSwitchUnit),
          if (isLoadingCost && cost == null)
            Text(
              '…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            )
          else if (cost != null)
            // Cost and margin as one run rather than two chips. They are read
            // together — "it cost this, I make that" — and on a 340px cart
            // pane two separate items plus a unit chip wrapped the row onto a
            // second line, which is the height this whole row exists to save.
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: l10n.cartLineCostLabel(formatMoney(cost)),
                    style: TextStyle(color: colors.mutedInk),
                  ),
                  TextSpan(
                    text: '  ·  ',
                    style: TextStyle(color: colors.line),
                  ),
                  TextSpan(
                    // Below cost is the one state a cashier must not miss
                    // while deciding, so it is the only thing here with a
                    // colour rather than a shade of grey.
                    text: l10n.cartLineMarginLabel(formatMoney(margin!)),
                    style: TextStyle(
                      color: marginColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          if (line.isRepriced)
            Container(
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(PointyRadii.chip),
              ),
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              child: Text(
                // The old price beside the badge, because "changed" without
                // "from what" is not something a manager can check later.
                '${l10n.cartLineRepricedBadge} · '
                '${formatMoney(line.listUnitPrice)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.warning,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The unit chip, as a chip rather than a row.
///
/// It used to own a whole row of its own and left most of it empty, with cost
/// and repricing stacked underneath in a third. A cart line is a dense thing
/// on a till; one wrapping row of chips says the same in two thirds the height.
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

    return Material(
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
              const Spacer(),
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

/// The identity this line rings up: the article's own number, or the lot it was
/// drawn from and when that lot expires.
///
/// A serialized code is text — there is nothing to choose, the cashier scanned
/// *this* handset. A lot is a chip the cashier can tap, because a customer who
/// asks for a longer expiry is asking for a different lot, and refusing them
/// would mean voiding the line and starting again.
class _CartLineIdentity extends StatelessWidget {
  const _CartLineIdentity({required this.line, this.onPickBatch});

  final CartLine line;
  final VoidCallback? onPickBatch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final unitCode = line.stockUnitCode.trim();
    final batchCode = line.stockBatchCode.trim();
    final expiry = line.stockBatchExpiry;

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 12, bottom: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (unitCode.isNotEmpty)
            _IdentityChip(
              icon: Icons.tag_outlined,
              label: unitCode,
              tone: colors.primaryStrong,
            ),
          if (batchCode.isNotEmpty || onPickBatch != null)
            InkWell(
              onTap: onPickBatch,
              borderRadius: BorderRadius.circular(8),
              child: _IdentityChip(
                icon: Icons.inventory_2_outlined,
                label: batchCode.isNotEmpty
                    ? l10n.posCartLineBatchBadge(batchCode)
                    : l10n.posCartLineBatchAuto,
                tone: batchCode.isNotEmpty
                    ? colors.primaryStrong
                    : theme.hintColor,
                trailing: onPickBatch == null ? null : Icons.expand_more,
              ),
            ),
          if (expiry != null)
            _IdentityChip(
              icon: Icons.event_outlined,
              label: l10n.posCartLineExpiryBadge(formatExpiry(expiry)),
              tone: _expiryTone(context, expiry),
            ),
        ],
      ),
    );
  }

  /// Red inside a month, amber inside three, ordinary after that. The cashier
  /// is the last person who can catch a pack that is about to turn, and a date
  /// that reads the same as every other date is a date nobody reads.
  Color _expiryTone(BuildContext context, DateTime expiry) {
    final colors = context.pointyColors;
    final now = DateTime.now();
    final days = DateTime(
      expiry.year,
      expiry.month,
      expiry.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days < 30) {
      return colors.danger;
    }
    if (days < 90) {
      return colors.warning;
    }
    return colors.primaryStrong;
  }
}

class _IdentityChip extends StatelessWidget {
  const _IdentityChip({
    required this.icon,
    required this.label,
    required this.tone,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: tone),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: tone,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (trailing != null) Icon(trailing, size: 14, color: tone),
      ],
    );
  }
}
