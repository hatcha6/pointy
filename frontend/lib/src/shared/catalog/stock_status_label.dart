import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import '../formatters.dart';
import '../units.dart';

class StockStatusLabel extends StatelessWidget {
  const StockStatusLabel({
    super.key,
    required this.quantity,
    required this.isActive,
    this.lowStockThreshold = 5,
    this.compact = false,
  }) : _showCount = false;

  /// The on-hand count in place of the status word, which becomes its tooltip
  /// — for a table column already headed "stock", where the number is the
  /// answer. Only a low or empty count takes the status colour, so a column
  /// of healthy stock reads as plain numbers and the short ones stand out.
  const StockStatusLabel.count({
    super.key,
    required this.quantity,
    required this.isActive,
    this.lowStockThreshold = 5,
  }) : compact = true,
       _showCount = true;

  final double quantity;
  final bool isActive;
  final int lowStockThreshold;
  final bool compact;
  final bool _showCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final status = _StockStatus.resolve(
      quantity: quantity,
      isActive: isActive,
      lowStockThreshold: lowStockThreshold,
    );
    final color = switch (status) {
      _StockStatus.available => colors.success,
      _StockStatus.low => colors.warning,
      _StockStatus.out || _StockStatus.inactive => colors.danger,
    };
    final label = switch (status) {
      _StockStatus.available => l10n.stockStatusAvailable,
      _StockStatus.low => l10n.stockStatusLow,
      _StockStatus.out => l10n.stockStatusOut,
      _StockStatus.inactive => l10n.inactiveStatus,
    };

    final labelStyle =
        (compact
                ? Theme.of(context).textTheme.labelMedium
                : Theme.of(context).textTheme.bodyMedium)
            ?.copyWith(color: color, fontWeight: FontWeight.w700);
    final quantityStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.mutedInk);
    final dot = DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 8),
    );

    if (_showCount) {
      return Tooltip(
        message: label,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot,
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                ltrIsolated(formatQuantity(quantity)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    PointyTypography.numeric(
                      Theme.of(context).textTheme.labelLarge ??
                          const TextStyle(),
                    ).copyWith(
                      color: status == _StockStatus.available
                          ? colors.ink
                          : color,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 6),
          Text('$quantity', maxLines: 1, style: quantityStyle),
        ],
      ],
    );
  }
}

enum _StockStatus {
  available,
  low,
  out,
  inactive;

  static _StockStatus resolve({
    required double quantity,
    required bool isActive,
    required int lowStockThreshold,
  }) {
    if (!isActive) {
      return _StockStatus.inactive;
    }
    if (quantity <= 0) {
      return _StockStatus.out;
    }
    if (quantity <= lowStockThreshold) {
      return _StockStatus.low;
    }
    return _StockStatus.available;
  }
}
