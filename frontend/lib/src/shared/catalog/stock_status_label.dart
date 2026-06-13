import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';

class StockStatusLabel extends StatelessWidget {
  const StockStatusLabel({
    super.key,
    required this.quantity,
    required this.isActive,
    this.lowStockThreshold = 5,
    this.compact = false,
  });

  final double quantity;
  final bool isActive;
  final int lowStockThreshold;
  final bool compact;

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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox.square(dimension: 8),
        ),
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
