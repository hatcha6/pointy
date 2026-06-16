import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../data/models/workflow.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// Where a job sits in its workflow: the zero-based [index] of the current
/// stage and the [total] number of stages. Null when the template/stage can't
/// be resolved (e.g. the board hasn't loaded templates yet).
({int index, int total})? jobStagePosition(
  OperationsJob job,
  List<WorkflowTemplate> templates,
) {
  WorkflowTemplate? template;
  for (final candidate in templates) {
    if (candidate.id == job.workflowTemplate) {
      template = candidate;
      break;
    }
  }
  if (template == null || template.stages.isEmpty) {
    return null;
  }
  final index = template.stages.indexWhere((s) => s.id == job.currentStage);
  if (index < 0) {
    return null;
  }
  return (index: index, total: template.stages.length);
}

/// Cross-screen building blocks for the operations route so the board, the job
/// details, the intake wizard, and recipes share one visual language.

// -- label / icon helpers ----------------------------------------------------

String jobTypeLabel(AppLocalizations l10n, OperationsJobType type) {
  return switch (type) {
    OperationsJobType.repair => l10n.jobTypeRepair,
    OperationsJobType.production => l10n.jobTypeProduction,
    OperationsJobType.kitchen => l10n.jobTypeKitchen,
    OperationsJobType.workOrder => l10n.jobTypeWorkOrder,
  };
}

String jobPriorityLabel(AppLocalizations l10n, OperationsJobPriority priority) {
  return switch (priority) {
    OperationsJobPriority.low => l10n.jobPriorityLow,
    OperationsJobPriority.normal => l10n.jobPriorityNormal,
    OperationsJobPriority.high => l10n.jobPriorityHigh,
    OperationsJobPriority.urgent => l10n.jobPriorityUrgent,
  };
}

String jobStatusLabel(AppLocalizations l10n, OperationsJobStatus status) {
  return switch (status) {
    OperationsJobStatus.open => l10n.jobStatusOpen,
    OperationsJobStatus.completed => l10n.jobStatusCompleted,
    OperationsJobStatus.cancelled => l10n.jobStatusCancelled,
  };
}

IconData jobTypeIcon(OperationsJobType type) {
  return switch (type) {
    OperationsJobType.repair => Icons.build_outlined,
    OperationsJobType.production => Icons.precision_manufacturing_outlined,
    OperationsJobType.kitchen => Icons.restaurant_outlined,
    OperationsJobType.workOrder => Icons.assignment_outlined,
  };
}

// -- status / priority visuals ------------------------------------------------

/// Status as a localized label + semantic color + icon (text + shape, never
/// color alone).
class JobStatusVisual {
  const JobStatusVisual(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;

  static JobStatusVisual of(BuildContext context, OperationsJobStatus status) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return switch (status) {
      OperationsJobStatus.open => JobStatusVisual(
        l10n.jobStatusOpen,
        colors.primaryStrong,
        Icons.timelapse_outlined,
      ),
      OperationsJobStatus.completed => JobStatusVisual(
        l10n.jobStatusCompleted,
        colors.success,
        Icons.check_circle_outline,
      ),
      OperationsJobStatus.cancelled => JobStatusVisual(
        l10n.jobStatusCancelled,
        colors.mutedInk,
        Icons.cancel_outlined,
      ),
    };
  }
}

/// Priority color/icon, or null for the everyday "normal" priority (no badge).
({Color color, IconData icon})? jobPriorityVisual(
  BuildContext context,
  OperationsJobPriority priority,
) {
  final colors = context.pointyColors;
  return switch (priority) {
    OperationsJobPriority.normal => null,
    OperationsJobPriority.low => (
      color: colors.mutedInk,
      icon: Icons.flag_outlined,
    ),
    OperationsJobPriority.high => (
      color: colors.warning,
      icon: Icons.flag_outlined,
    ),
    OperationsJobPriority.urgent => (
      color: colors.danger,
      icon: Icons.priority_high_rounded,
    ),
  };
}

class JobPriorityBadge extends StatelessWidget {
  const JobPriorityBadge({super.key, required this.priority});

  final OperationsJobPriority priority;

  @override
  Widget build(BuildContext context) {
    final visual = jobPriorityVisual(context, priority);
    if (visual == null) {
      return const SizedBox.shrink();
    }
    return PointyStatusPill(
      label: jobPriorityLabel(AppLocalizations.of(context)!, priority),
      icon: visual.icon,
      color: visual.color,
    );
  }
}

// -- icon badge ---------------------------------------------------------------

/// A soft, tinted circular icon badge used across the operations surfaces.
class OperationsIconBadge extends StatelessWidget {
  const OperationsIconBadge({
    super.key,
    required this.icon,
    this.color,
    this.size = 44,
    this.iconSize,
    this.onDark = false,
  });

  final IconData icon;
  final Color? color;
  final double size;
  final double? iconSize;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tint = color ?? colors.primaryStrong;
    final background = onDark
        ? colors.surface.withValues(alpha: 0.14)
        : tint.withValues(alpha: 0.12);
    final foreground = onDark ? colors.surface : tint;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, color: foreground, size: iconSize ?? size * 0.5),
    );
  }
}

// -- stage progress -----------------------------------------------------------

/// A compact "how far through the workflow" indicator: a segmented rail plus a
/// "stage n of m" caption. [currentIndex] is zero-based. [onDark] flips the
/// palette for use on a dark focus header.
class JobStageProgressBar extends StatelessWidget {
  const JobStageProgressBar({
    super.key,
    required this.currentIndex,
    required this.total,
    this.label,
    this.onDark = false,
  });

  final int currentIndex;
  final int total;
  final String? label;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final strong = onDark ? colors.surface : colors.ink;
    final muted = onDark
        ? colors.surface.withValues(alpha: 0.72)
        : colors.mutedInk;
    final track = onDark
        ? colors.surface.withValues(alpha: 0.18)
        : colors.surfaceSunken;
    final fill = onDark ? colors.surface : PointyColors.primary;
    final safeTotal = total <= 0 ? 1 : total;
    final reached = (currentIndex + 1).clamp(1, safeTotal);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (label != null)
              Expanded(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelLarge?.copyWith(
                    color: strong,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 8),
            Text(
              l10n.jobStageProgress(reached, safeTotal),
              style: textTheme.labelMedium?.copyWith(
                color: muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < safeTotal; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < reached ? fill : track,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
