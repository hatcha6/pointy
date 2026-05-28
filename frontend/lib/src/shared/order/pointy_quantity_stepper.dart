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
  });

  final int quantity;
  final String incrementTooltip;
  final String decrementTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;

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
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$quantity',
                maxLines: 1,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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
