import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/ai_chat.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// The assistant's checklist for a multi-step task, ticked off as it works —
/// so a ten-tool job reads as progress rather than a spinner.
class AiPlanChecklist extends StatelessWidget {
  const AiPlanChecklist({super.key, required this.steps, required this.active});

  final List<AiPlanStep> steps;

  /// Whether the turn is still running; a finished turn shows no spinner.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final done = steps.where((s) => s.status == AiPlanStatus.completed).length;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 18, color: colors.mutedInk),
              SizedBox(width: spacing.xs),
              Expanded(
                child: Text(
                  l10n.aiAssistantPlanTitle,
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                l10n.aiAssistantPlanProgress(done, steps.length),
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
          SizedBox(height: spacing.xs),
          for (final step in steps) _StepRow(step: step, active: active),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.active});

  final AiPlanStep step;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final completed = step.status == AiPlanStatus.completed;
    final current = step.status == AiPlanStatus.inProgress;

    final Widget icon;
    if (completed) {
      icon = Icon(Icons.check_circle_rounded, size: 18, color: colors.success);
    } else if (current && active) {
      icon = SizedBox.square(
        dimension: 18,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: PointySpinner(strokeWidth: 2, color: colors.primaryStrong),
        ),
      );
    } else {
      icon = Icon(
        current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: current ? colors.primaryStrong : colors.lineStrong,
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSwitcher(
            duration: PointyMotion.fast,
            child: KeyedSubtree(key: ValueKey(step.status), child: icon),
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              step.step,
              style: textTheme.bodyMedium?.copyWith(
                color: completed ? colors.mutedInk : colors.ink,
                fontWeight: current ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
