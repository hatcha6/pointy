import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'job_decline_sheet.dart';

/// The shelf of declined devices still waiting for their owners.
///
/// These jobs are finished, so they have no column on the board — but the
/// phones are physically in the shop, and when the customer walks in with
/// their receipt this is where the counter has to find them. Hidden when the
/// shelf is empty.
class JobAwaitingHandBackStrip extends StatelessWidget {
  const JobAwaitingHandBackStrip({
    super.key,
    required this.jobs,
    required this.onOpenJob,
  });

  final List<OperationsJob> jobs;
  final ValueChanged<OperationsJob> onOpenJob;

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final accent = colors.warning;

    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.08), colors.surface),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      padding: EdgeInsets.all(spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.symmetric(horizontal: spacing.xs),
            child: Row(
              children: [
                Icon(Icons.assignment_return_outlined, size: 20, color: accent),
                SizedBox(width: spacing.xs),
                Expanded(
                  child: Text(
                    l10n.jobsAwaitingHandBackTitle,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                PointyStatusPill(label: '${jobs.length}', color: accent),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.xs,
              2,
              spacing.xs,
              spacing.sm,
            ),
            child: Text(
              l10n.jobsAwaitingHandBackHint,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final job in jobs)
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: spacing.sm),
                    child: _AwaitingCard(job: job, onTap: () => onOpenJob(job)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AwaitingCard extends StatelessWidget {
  const _AwaitingCard({required this.job, required this.onTap});

  final OperationsJob job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final reason = job.cancelReason;
    final device = job.assets
        .map((link) => link.assetDetails?.displayName.trim() ?? '')
        .firstWhere((name) => name.isNotEmpty, orElse: () => '');
    final subtitle = [
      if (job.customerName.trim().isNotEmpty) job.customerName.trim(),
      if (device.isNotEmpty) device,
    ].join(' · ');

    return SizedBox(
      width: 250,
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(PointyRadii.card),
          child: Ink(
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(PointyRadii.card),
            ),
            padding: EdgeInsets.all(spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.jobNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PointyTypography.numeric(
                    textTheme.titleSmall ?? const TextStyle(),
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
                SizedBox(height: spacing.xs),
                Wrap(
                  spacing: spacing.xs,
                  runSpacing: spacing.xs / 2,
                  children: [
                    if (reason != null)
                      PointyStatusPill(
                        label: jobDeclineReasonLabel(l10n, reason),
                        color: colors.mutedInk,
                      ),
                    if (job.owesDeclineFee)
                      PointyStatusPill(
                        label: l10n.jobDeclineFeeDueBadge(
                          formatMoney(job.declineFee!),
                        ),
                        icon: Icons.payments_outlined,
                        color: colors.warning,
                      ),
                  ],
                ),
                if (job.cancelledAt != null) ...[
                  SizedBox(height: spacing.xs),
                  Text(
                    formatDateTime(job.cancelledAt!),
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
