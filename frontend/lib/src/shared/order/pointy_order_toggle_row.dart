import 'package:flutter/material.dart';

import '../design/design.dart';

/// Compact, on-brand on/off row used in the order footers (print receipt,
/// receive immediately). A custom square check keeps it tighter and more on
/// brand than a Material [Checkbox] in the cramped sticky footer, and the whole
/// row is the tap target.
class PointyOrderToggleRow extends StatelessWidget {
  const PointyOrderToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(PointyRadii.button),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          vertical: 6,
          horizontal: 4,
        ),
        child: Row(
          children: [
            PointyCheckBox(value: value, enabled: enabled),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: enabled ? colors.ink : colors.mutedInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square, brand-tinted checkbox: a filled primary tile with a check when on,
/// an outlined tile when off.
class PointyCheckBox extends StatelessWidget {
  const PointyCheckBox({super.key, required this.value, this.enabled = true});

  final bool value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final Color background;
    final Color border;
    if (!enabled) {
      background = colors.subtleFill;
      border = colors.line;
    } else if (value) {
      background = colors.primaryStrong;
      border = colors.primaryStrong;
    } else {
      background = colors.surface;
      border = colors.lineStrong;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 1.5),
      ),
      child: value ? Icon(Icons.check, size: 15, color: colors.surface) : null,
    );
  }
}
