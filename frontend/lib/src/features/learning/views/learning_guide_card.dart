import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../models/learning_guide.dart';
import 'learning_presentation.dart';

/// One guide row in the catalogue.
class LearningGuideCard extends StatelessWidget {
  const LearningGuideCard({
    super.key,
    required this.guide,
    required this.isFinished,
    required this.isSelected,
    required this.onTap,
  });

  final LearningGuide guide;
  final bool isFinished;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);

    return Semantics(
      button: true,
      selected: isSelected,
      label: guide.title,
      child: Material(
        color: isSelected
            ? Color.alphaBlend(
                colors.primaryStrong.withValues(alpha: 0.08),
                colors.surface,
              )
            : colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PointyRadii.card),
              border: Border.all(
                color: isSelected ? colors.primaryStrong : colors.line,
              ),
            ),
            padding: EdgeInsets.all(spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _KindBadge(guide: guide, isFinished: isFinished),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            guide.title,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            guide.summary,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.mutedInk,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PointyDisclosureChevron(),
                  ],
                ),
                SizedBox(height: spacing.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    PointyStatusPill(
                      label: learningTrackLabel(l10n, guide.track),
                      icon: learningTrackIcon(guide.track),
                    ),
                    PointyStatusPill(
                      label: learningLevelLabel(l10n, guide.level),
                      icon: Icons.stairs_outlined,
                      color: colors.mutedInk,
                    ),
                    PointyStatusPill(
                      label: l10n.learningReadingTime(guide.minutes),
                      icon: Icons.schedule_outlined,
                      color: colors.mutedInk,
                    ),
                    if (isFinished)
                      PointyStatusPill(
                        label: l10n.learningFinishedBadge,
                        icon: Icons.check_circle_outline,
                        color: colors.success,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.guide, required this.isFinished});

  final LearningGuide guide;
  final bool isFinished;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final color = isFinished ? colors.success : colors.primaryStrong;

    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.12), colors.surface),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Icon(
        isFinished ? Icons.check : learningKindIcon(guide.kind),
        color: color,
      ),
    );
  }
}
