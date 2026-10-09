import 'package:flutter/material.dart';

/// One side of a [PointyChoiceButtons].
class PointyChoiceOption<T> {
  const PointyChoiceOption({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

/// A short either/or as equal-width buttons: the chosen one filled with a
/// check, the others outlined. Clearer to a cashier than a segmented toggle,
/// whose selected side is easy to misread.
class PointyChoiceButtons<T> extends StatelessWidget {
  const PointyChoiceButtons({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<PointyChoiceOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < options.length; index++) ...[
          if (index > 0) const SizedBox(width: 8),
          Expanded(
            child: _ChoiceButton(
              key: ValueKey('choice_${options[index].value}'),
              option: options[index],
              selected: options[index].value == value,
              onPressed: enabled ? () => onChanged(options[index].value) : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _ChoiceButton<T> extends StatelessWidget {
  const _ChoiceButton({
    super.key,
    required this.option,
    required this.selected,
    required this.onPressed,
  });

  final PointyChoiceOption<T> option;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(selected ? Icons.check_rounded : option.icon);
    final label = Text(
      option.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      selected: selected,
      child: selected
          ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label)
          : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label),
    );
  }
}
