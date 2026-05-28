import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';

class PointyKeypad extends StatelessWidget {
  const PointyKeypad({
    super.key,
    required this.label,
    required this.backspaceTooltip,
    required this.clearTooltip,
    required this.onDigit,
    required this.onDecimal,
    required this.onBackspace,
    required this.onClear,
  });

  final String label;
  final String backspaceTooltip;
  final String clearTooltip;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimal;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final buttons = <_KeypadButtonData>[
      for (final digit in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
        _KeypadButtonData.digit(digit),
      _KeypadButtonData.action(
        key: const ValueKey('payment_keypad_decimal'),
        label: '.',
        onPressed: onDecimal,
      ),
      _KeypadButtonData.digit('0'),
      _KeypadButtonData.action(
        key: const ValueKey('payment_keypad_backspace'),
        icon: Icons.backspace_outlined,
        tooltip: backspaceTooltip,
        onPressed: onBackspace,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              key: const ValueKey('payment_keypad_clear'),
              tooltip: clearTooltip,
              onPressed: onClear,
              icon: const Icon(Icons.clear),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.8,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final button in buttons)
              _KeypadButton(button: button, onDigit: onDigit),
          ],
        ),
      ],
    );
  }
}

class _KeypadButtonData {
  const _KeypadButtonData({
    required this.key,
    this.label,
    this.icon,
    this.tooltip,
    this.onPressed,
  });

  factory _KeypadButtonData.digit(String digit) {
    return _KeypadButtonData(
      key: ValueKey('payment_keypad_digit_$digit'),
      label: digit,
    );
  }

  factory _KeypadButtonData.action({
    required Key key,
    String? label,
    IconData? icon,
    String? tooltip,
    required VoidCallback onPressed,
  }) {
    return _KeypadButtonData(
      key: key,
      label: label,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  final Key key;
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback? onPressed;

  bool get isDigit => onPressed == null;
}

class _KeypadButton extends StatelessWidget {
  const _KeypadButton({required this.button, required this.onDigit});

  final _KeypadButtonData button;
  final ValueChanged<String> onDigit;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final label = button.label;
    final child = button.icon == null
        ? Text(
            label ?? '',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          )
        : Icon(button.icon);

    return Tooltip(
      message: button.tooltip ?? label ?? '',
      child: OutlinedButton(
        key: button.key,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.ink,
          side: BorderSide(color: colors.line),
          shape: PointyComponentStyles.shape(PointyRadii.button),
        ),
        onPressed: button.isDigit
            ? () {
                if (label != null) {
                  onDigit(label);
                }
              }
            : button.onPressed,
        child: child,
      ),
    );
  }
}
