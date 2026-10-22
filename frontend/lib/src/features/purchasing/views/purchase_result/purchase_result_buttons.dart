import 'package:flutter/material.dart';

/// One button of a purchase result's footer.
class PurchaseResultButton {
  const PurchaseResultButton({
    required this.name,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  /// Becomes the button's key, `purchase_result_<name>`.
  final String name;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

/// A result's next steps: the one it expects, filled and focused so Enter
/// takes it, and beside it the way out. [below] sits under the pair — a
/// quieter third choice, or a word on what the main one will ask.
class PurchaseResultButtons extends StatelessWidget {
  const PurchaseResultButtons({
    super.key,
    required this.primary,
    this.secondary,
    this.below,
    this.focusPrimary = true,
    this.wrapPrimary,
  });

  final PurchaseResultButton primary;
  final PurchaseResultButton? secondary;
  final Widget? below;

  /// False where Enter must not be the answer — a cost the server doubts is
  /// confirmed by a deliberate tap, never by the key the buyer was typing with.
  final bool focusPrimary;

  /// Wraps the primary button, for a lesson that points at it.
  final Widget Function(Widget button)? wrapPrimary;

  @override
  Widget build(BuildContext context) {
    final secondary = this.secondary;
    final primaryButton = FilledButton.icon(
      key: ValueKey('purchase_result_${primary.name}'),
      autofocus: focusPrimary,
      style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
      onPressed: primary.onPressed,
      icon: Icon(primary.icon),
      label: FittedBox(fit: BoxFit.scaleDown, child: Text(primary.label)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (secondary != null) ...[
              Expanded(
                child: OutlinedButton.icon(
                  key: ValueKey('purchase_result_${secondary.name}'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                  ),
                  onPressed: secondary.onPressed,
                  icon: Icon(secondary.icon),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(secondary.label),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              flex: secondary == null ? 1 : 2,
              child: wrapPrimary?.call(primaryButton) ?? primaryButton,
            ),
          ],
        ),
        if (below != null) ...[const SizedBox(height: 6), below!],
      ],
    );
  }
}
