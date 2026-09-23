import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/voucher_availability.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// The denominations of a provider's card — Libyana 5, 10, 30… — to pick one.
///
/// Opens at once on the variants the catalog already holds and asks the
/// provider in the background ([checkAvailability]) whether each is still in
/// stock: a card that sold out since the last sweep disappears while the
/// cashier is still choosing, and nothing about the tap waits on the network.
Future<ProductVariant?> showPosVoucherPickerSheet(
  BuildContext context, {
  required Product product,
  required List<ProductVariant> variants,
  required Future<VoucherAvailability?> Function() checkAvailability,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant>(
    context: context,
    builder: (sheetContext) => PosVoucherPicker(
      product: product,
      variants: variants,
      checkAvailability: checkAvailability,
      onPicked: (variant) => Navigator.of(sheetContext).pop(variant),
    ),
  );
}

/// Public, and callback-driven, so the preview harness and widget tests can
/// render every state without a view model behind it.
class PosVoucherPicker extends StatefulWidget {
  const PosVoucherPicker({
    super.key,
    required this.product,
    required this.variants,
    required this.checkAvailability,
    required this.onPicked,
  });

  final Product product;
  final List<ProductVariant> variants;
  final Future<VoucherAvailability?> Function() checkAvailability;
  final ValueChanged<ProductVariant> onPicked;

  @override
  State<PosVoucherPicker> createState() => _PosVoucherPickerState();
}

class _PosVoucherPickerState extends State<PosVoucherPicker> {
  VoucherAvailability? _live;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    VoucherAvailability? live;
    try {
      live = await widget.checkAvailability();
    } on Object {
      live = null;
    }
    if (!mounted) return;
    setState(() {
      _live = (live?.ok ?? false) ? live : null;
      _checking = false;
    });
  }

  /// The cards on offer: the catalog's, less anything the provider says it no
  /// longer has, cheapest first, priced as checkout will price them.
  List<({ProductVariant variant, double price, double? cost})> get _cards {
    final live = _live;
    final cards = <({ProductVariant variant, double price, double? cost})>[];
    for (final variant in widget.variants) {
      final fresh = live?.cardFor(variant.id);
      if (live != null && (fresh == null || !fresh.isAvailable)) {
        continue;
      }
      cards.add((
        variant: variant,
        price: fresh?.price ?? variant.unitPrice,
        cost: fresh?.cost,
      ));
    }
    cards.sort((a, b) => a.price.compareTo(b.price));
    return cards;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final cards = _cards;
    final balance = _live?.balance;
    final withdrawn = _live != null && cards.length < widget.variants.length;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(spacing.md, 0, spacing.md, spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.confirmation_number_outlined,
                  color: colors.primaryStrong,
                ),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: Text(
                    widget.product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium,
                  ),
                ),
                if (_checking)
                  Tooltip(
                    message: l10n.posVoucherChecking,
                    child: const SizedBox.square(
                      dimension: 16,
                      child: PointySpinner(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.posVoucherPickerHint,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            if (withdrawn) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage(
                message: l10n.posVoucherSomeSoldOut,
                icon: Icons.inventory_2_outlined,
                compact: true,
              ),
            ],
            SizedBox(height: spacing.sm),
            if (cards.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: spacing.lg),
                child: PointyEmptyState(
                  title: l10n.posVoucherNoneLeft,
                  icon: Icons.remove_shopping_cart_outlined,
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const minTile = 132.0;
                      final gap = spacing.sm;
                      final perRow =
                          ((constraints.maxWidth + gap) / (minTile + gap))
                              .floor()
                              .clamp(2, 6);
                      final tileWidth =
                          (constraints.maxWidth - gap * (perRow - 1)) / perRow;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final card in cards)
                            SizedBox(
                              width: tileWidth,
                              child: _VoucherTile(
                                label: card.variant.displayName.isNotEmpty
                                    ? card.variant.displayName
                                    : card.variant.pickerLabel,
                                price: card.price,
                                // Warned, not refused: the figure is as old as
                                // the last read, and the owner may have topped
                                // up in the provider's own app since.
                                beyondFloat:
                                    balance != null &&
                                    card.cost != null &&
                                    card.cost! > balance,
                                onTap: () => widget.onPicked(card.variant),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            if (balance != null) ...[
              SizedBox(height: spacing.sm),
              Text(
                l10n.posVoucherFloat(formatMoney(balance)),
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VoucherTile extends StatelessWidget {
  const _VoucherTile({
    required this.label,
    required this.price,
    required this.beyondFloat,
    required this.onTap,
  });

  final String label;
  final double price;
  final bool beyondFloat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: beyondFloat ? colors.warning : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: spacing.xs),
              Text(
                formatMoney(price),
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.primaryStrong,
                ),
              ),
              if (beyondFloat) ...[
                SizedBox(height: spacing.xs),
                Text(
                  l10n.posVoucherBeyondFloat,
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(color: colors.warning),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
