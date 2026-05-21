import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../shared/formatters.dart';

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final quantityControls = _QuantityControls(
          quantity: line.quantity,
          addTooltip: l10n.addOneTooltip,
          removeTooltip: l10n.removeOneTooltip,
          onAdd: onAdd,
          onRemove: onRemove,
        );
        final amount = _LineAmount(amount: line.total);

        if (constraints.maxWidth < 320) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _ProductSummary(line: line)),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: amount,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: quantityControls,
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: _ProductSummary(line: line)),
              const SizedBox(width: 8),
              quantityControls,
              const SizedBox(width: 8),
              SizedBox(width: 88, child: amount),
            ],
          ),
        );
      },
    );
  }
}

class _ProductSummary extends StatelessWidget {
  const _ProductSummary({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.product.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 2),
        Text(
          l10n.unitPriceEach(formatMoney(line.product.effectiveUnitPrice)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _QuantityControls extends StatelessWidget {
  const _QuantityControls({
    required this.quantity,
    required this.addTooltip,
    required this.removeTooltip,
    required this.onAdd,
    required this.onRemove,
  });

  final int quantity;
  final String addTooltip;
  final String removeTooltip;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _QuantityButton(
          tooltip: removeTooltip,
          onPressed: onRemove,
          icon: Icons.remove,
        ),
        SizedBox(
          width: 34,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$quantity',
                maxLines: 1,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ),
        _QuantityButton(tooltip: addTooltip, onPressed: onAdd, icon: Icons.add),
      ],
    );
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(34),
        fixedSize: const Size.square(34),
        padding: EdgeInsets.zero,
      ),
      iconSize: 18,
      icon: Icon(icon),
    );
  }
}

class _LineAmount extends StatelessWidget {
  const _LineAmount({required this.amount});

  final double amount;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          formatMoney(amount),
          maxLines: 1,
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
    );
  }
}
