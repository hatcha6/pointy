import 'package:flutter/material.dart';

import '../design/design.dart';

class PointyQuantityStepper extends StatelessWidget {
  const PointyQuantityStepper({
    super.key,
    required this.quantity,
    required this.incrementTooltip,
    required this.decrementTooltip,
    this.onIncrement,
    this.onDecrement,
    this.onQuantityTap,
  });

  final double quantity;
  final String incrementTooltip;
  final String decrementTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;

  /// Tap-to-type entry for weighted lines; null keeps the text static.
  final VoidCallback? onQuantityTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepperButton(
          tooltip: decrementTooltip,
          icon: Icons.remove,
          onPressed: onDecrement,
        ),
        SizedBox(
          width: 38,
          child: InkWell(
            onTap: onQuantityTap,
            borderRadius: BorderRadius.circular(6),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formatSaleQuantity(quantity),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    decoration: onQuantityTap == null
                        ? null
                        : TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),
        ),
        _StepperButton(
          tooltip: incrementTooltip,
          icon: Icons.add,
          onPressed: onIncrement,
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(PointyDimensions.iconButton),
        minimumSize: const Size.square(PointyDimensions.iconButton),
        padding: EdgeInsets.zero,
        shape: PointyComponentStyles.shape(PointyRadii.button),
      ),
      iconSize: 18,
      icon: Icon(icon),
    );
  }
}

/// Whole counts render bare ("2"); weights keep up to three places ("1.250").
String formatSaleQuantity(double quantity) {
  if (quantity == quantity.roundToDouble()) {
    return quantity.toStringAsFixed(0);
  }
  return quantity.toStringAsFixed(3);
}
