import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import 'pointy_progress.dart';

/// Status of one row in a [PointyStageTimeline].
enum PointyStageStatus { pending, running, done, failed, skipped }

/// One stage of a long job.
class PointyStageEntry {
  const PointyStageEntry({
    required this.label,
    required this.status,
    this.detail = '',
    this.percent = 0,
  });

  final String label;
  final PointyStageStatus status;

  /// What is happening right now, in the user's words — "الجدول 34 من 61".
  final String detail;
  final int percent;
}

/// A checklist of what a long job is doing, has done, and has yet to do.
///
/// Built for jobs measured in minutes rather than seconds. A single percentage
/// is not enough there: at twenty minutes "62%" and "hung" look identical, and
/// the person watching has no way to tell whether it is safe to walk away. A
/// list of named stages, each with its own live detail line, answers that
/// without them having to ask.
///
/// The running stage gets a determinate bar when it can report a percentage and
/// a spinner when it cannot — a bar that does not move is worse than no bar.
class PointyStageTimeline extends StatelessWidget {
  const PointyStageTimeline({super.key, required this.stages});

  final List<PointyStageEntry> stages;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < stages.length; index++)
          Padding(
            padding: EdgeInsets.only(
              bottom: index == stages.length - 1 ? 0 : spacing.sm,
            ),
            child: _StageRow(
              stage: stages[index],
              isLast: index == stages.length - 1,
            ),
          ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.isLast});

  final PointyStageEntry stage;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final running = stage.status == PointyStageStatus.running;
    final pending = stage.status == PointyStageStatus.pending;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StageMarker(status: stage.status),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stage.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: running ? FontWeight.w700 : FontWeight.w500,
                  color: pending ? colors.mutedInk : colors.ink,
                ),
              ),
              if (stage.detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  stage.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: stage.status == PointyStageStatus.failed
                        ? colors.danger
                        : colors.mutedInk,
                  ),
                ),
              ],
              if (running) ...[
                const SizedBox(height: 8),
                PointyProgressBar(
                  // A stage that cannot say how far along it is gets an
                  // indeterminate bar rather than one frozen at zero.
                  value: stage.percent > 0 ? stage.percent / 100 : null,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StageMarker extends StatelessWidget {
  const _StageMarker({required this.status});

  final PointyStageStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return SizedBox(
      width: 22,
      height: 22,
      child: switch (status) {
        PointyStageStatus.done => Icon(
          Icons.check_circle,
          size: 20,
          color: colors.success,
        ),
        PointyStageStatus.failed => Icon(
          Icons.error,
          size: 20,
          color: colors.danger,
        ),
        PointyStageStatus.skipped => Icon(
          Icons.remove_circle_outline,
          size: 20,
          color: colors.mutedInk,
        ),
        PointyStageStatus.running => Padding(
          padding: const EdgeInsets.all(2),
          child: PointySpinner(strokeWidth: 2.5, color: colors.primaryStrong),
        ),
        PointyStageStatus.pending => Icon(
          Icons.circle_outlined,
          size: 20,
          color: colors.line,
        ),
      },
    );
  }
}
