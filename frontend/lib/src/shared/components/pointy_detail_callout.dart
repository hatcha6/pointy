import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// Tone of a [PointyDetailCallout], driving its accent colour.
enum PointyCalloutTone { primary, success, warning, danger, neutral }

/// A highlighted plain-language callout — the "translate the data into a
/// sentence" house pattern first introduced on the discount details page.
///
/// Renders a tinted, bordered surface carrying an [icon], a bold [title]
/// sentence, an optional supporting [message], and an optional [trailing]
/// widget (typically a [PointyStatusPill]). Use it to make an abstract figure
/// legible at a glance — "You owe this supplier 1,250.00", "Margin is 42% at
/// the latest cost", and so on.
class PointyDetailCallout extends StatelessWidget {
  const PointyDetailCallout({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.trailing,
    this.tone = PointyCalloutTone.primary,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? trailing;
  final PointyCalloutTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    final accent = switch (tone) {
      PointyCalloutTone.primary => colors.primaryStrong,
      PointyCalloutTone.success => colors.success,
      PointyCalloutTone.warning => colors.warning,
      PointyCalloutTone.danger => colors.danger,
      PointyCalloutTone.neutral => colors.mutedInk,
    };
    final titleColor = tone == PointyCalloutTone.primary
        ? colors.primaryDark
        : accent;
    final background = Color.alphaBlend(
      accent.withOpacity(0.10),
      colors.surface,
    );

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: accent.withOpacity(0.20)),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Row(
        children: [
          Icon(icon, color: accent),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (message != null && message!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!.trim(),
                    style: textTheme.bodySmall?.copyWith(color: accent),
                  ),
                ],
              ],
            ),
          ),
          if (trailing case final trailing?) ...[
            SizedBox(width: spacing.sm),
            trailing,
          ],
        ],
      ),
    );
  }
}
