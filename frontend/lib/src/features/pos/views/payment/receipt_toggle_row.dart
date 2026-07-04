import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/order/order.dart';

/// On/off preference card for the post-payment receipt actions (print / share).
/// A tappable bordered surface with the brand checkbox, label, and a one-line
/// explanation — on-brand with the rest of the checkout.
class ReceiptToggleRow extends StatelessWidget {
  const ReceiptToggleRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.tooltip,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final String tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: value
            ? Color.alphaBlend(
                colors.primaryStrong.withOpacity(0.06),
                colors.surface,
              )
            : colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: InkWell(
          key: const ValueKey('payment_receipt_toggle'),
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(PointyRadii.card),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PointyRadii.card),
              border: Border.all(
                color: value ? colors.primaryStrong : colors.line,
                width: value ? 1.5 : 1,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PointyCheckBox(value: value),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
