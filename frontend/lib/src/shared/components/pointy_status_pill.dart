import 'package:flutter/material.dart';

import '../design/design.dart';

class PointyStatusPill extends StatelessWidget {
  const PointyStatusPill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.compact = true,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final resolvedColor = color ?? colors.primaryStrong;
    final backgroundColor = Color.alphaBlend(
      resolvedColor.withValues(alpha: 0.10),
      colors.surface,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: resolvedColor.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 5 : 7,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 15 : 17, color: resolvedColor),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (compact
                            ? Theme.of(context).textTheme.labelMedium
                            : Theme.of(context).textTheme.labelLarge)
                        ?.copyWith(
                          color: resolvedColor,
                          fontWeight: FontWeight.w700,
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
