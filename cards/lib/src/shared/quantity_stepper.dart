import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../l10n/generated/app_localizations.dart';
import '../design/cards_tokens.dart';
import 'haptics.dart';

/// − n + in a capsule, 44 px targets, a tick on each change, and the number
/// rolling to its new value.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.max = 10,
  });

  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    void change(int next) {
      Haptics.select();
      onChanged(next);
    }

    Widget button(IconData icon, String tooltip, VoidCallback? onPressed) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 20),
        );

    return Container(
      height: CardsSizes.button,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(CardsRadii.pill),
      ),
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // Right to left: minus on the right, plus on the left.
        children: [
          button(
            Icons.remove_rounded,
            l10n.decreaseQuantity,
            value > 1 ? () => change(value - 1) : null,
          ),
          SizedBox(
            width: 28,
            child: AnimatedSwitcher(
              duration: CardsMotion.fast,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: 0.7, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                '$value',
                key: ValueKey(value),
                textAlign: TextAlign.center,
                style: PointyTypography.numeric(theme.textTheme.titleMedium!)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          button(
            Icons.add_rounded,
            l10n.increaseQuantity,
            value < max ? () => change(value + 1) : null,
          ),
        ],
      ),
    );
  }
}
