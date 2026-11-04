import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../view_models/bulk_tracking_view_model.dart';

/// The sticky bottom bar: the apply button, then — while a run is under way —
/// its progress, and after a network failure the way to carry on.
class BulkTrackingFooter extends StatelessWidget {
  const BulkTrackingFooter({
    super.key,
    required this.viewModel,
    required this.onApply,
  });

  final BulkTrackingViewModel viewModel;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    if (viewModel.isApplying || viewModel.applyInterrupted) {
      final interrupted = viewModel.applyInterrupted;
      return PointyStickyActionFooter(
        primaryAction: interrupted
            ? FilledButton.icon(
                key: const ValueKey('bulk_tracking_resume'),
                onPressed: viewModel.apply,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.bulkTrackingResume),
              )
            : FilledButton.icon(
                onPressed: null,
                icon: const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                ),
                label: Text(l10n.bulkTrackingSending),
              ),
        summary: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyProgressBar(
              key: const ValueKey('bulk_tracking_progress_bar'),
              value: viewModel.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 6),
            Text(
              interrupted
                  ? l10n.bulkTrackingInterrupted(
                      viewModel.sentCount,
                      viewModel.totalToApply,
                      viewModel.remainingCount,
                    )
                  : l10n.bulkTrackingProgress(
                      viewModel.sentCount,
                      viewModel.totalToApply,
                    ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: interrupted ? colors.danger : colors.mutedInk,
              ),
            ),
          ],
        ),
      );
    }

    final fresh = viewModel.isPreviewFresh;
    final count = viewModel.idsToApply.length;
    final String label;
    if (!viewModel.isComplete) {
      label = l10n.bulkTrackingApplyIncomplete;
    } else if (!fresh) {
      label = l10n.bulkTrackingApplyWaiting;
    } else if (count == 0) {
      label = l10n.bulkTrackingApplyNothing;
    } else {
      label = l10n.bulkTrackingApplyButton(count);
    }
    return PointyStickyActionFooter(
      primaryAction: FilledButton.icon(
        key: const ValueKey('bulk_tracking_apply'),
        onPressed: viewModel.canApply ? onApply : null,
        icon: const Icon(Icons.event_available_outlined),
        label: Text(label),
      ),
    );
  }
}

/// What a finished run did: counts, and every product the server could not
/// change, by name and with its reason.
class BulkTrackingResultCard extends StatelessWidget {
  const BulkTrackingResultCard({super.key, required this.viewModel});

  final BulkTrackingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final result = viewModel.result;
    return PointyDetailSection(
      title: l10n.bulkTrackingResultTitle,
      icon: Icons.task_alt_outlined,
      child: Column(
        key: const ValueKey('bulk_tracking_result'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyInlineMessage.success(
            message: l10n.bulkTrackingResultDone(result.done),
          ),
          if (result.blocked > 0) ...[
            const SizedBox(height: 6),
            PointyInlineMessage.warning(
              message: l10n.bulkTrackingResultBlocked(result.blocked),
            ),
          ],
          if (result.failures.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              l10n.bulkTrackingFailuresTitle(result.failures.length),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: colors.danger,
              ),
            ),
            for (final failure in result.failures)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${viewModel.nameFor(failure.product)}: ${failure.message}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
