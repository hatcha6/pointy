import 'package:flutter/material.dart';

import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';

class QuickAmountBar extends StatelessWidget {
  const QuickAmountBar({
    super.key,
    required this.label,
    required this.amounts,
    required this.onSelected,
  });

  final String label;
  final List<double> amounts;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            for (final entry in amounts.indexed)
              OutlinedButton(
                key: ValueKey(
                  entry.$1 == 0
                      ? 'payment_quick_amount_exact'
                      : 'payment_quick_amount_round_up_${entry.$1 - 1}',
                ),
                onPressed: () => onSelected(entry.$2),
                child: Text(formatMoney(entry.$2)),
              ),
          ],
        ),
      ],
    );
  }
}
