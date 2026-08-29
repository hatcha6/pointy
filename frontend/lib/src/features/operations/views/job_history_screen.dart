import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/job_history_view_model.dart';
import 'operations_ui.dart';

/// Finished work, on its own page.
///
/// The board is for what is in front of the shop today; everything it has ever
/// done belongs here, as a searchable list that pages rather than a fourth
/// filter state on the board.
class JobHistoryScreen extends StatefulWidget {
  const JobHistoryScreen({
    super.key,
    required this.viewModel,
    required this.onOpenJob,
  });

  final JobHistoryViewModel viewModel;
  final void Function(OperationsJob job) onOpenJob;

  @override
  State<JobHistoryScreen> createState() => _JobHistoryScreenState();
}

class _JobHistoryScreenState extends State<JobHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.viewModel.load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        final spacing = AdaptiveSpacing.of(context);

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.jobsHistoryTitle),
            isLoading: viewModel.isLoading,
            reserveLoadingSlot: false,
          ),
          body: viewModel.hasLoadError && viewModel.jobs.isEmpty
              ? PointyErrorState(
                  title: l10n.jobsLoadError,
                  icon: Icons.history,
                  action: FilledButton.icon(
                    onPressed: viewModel.load,
                    icon: const Icon(Icons.sync),
                    label: Text(l10n.retryButton),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        spacing.pageHorizontal,
                        spacing.sm,
                        spacing.pageHorizontal,
                        spacing.xs,
                      ),
                      child: AdaptiveMaxWidth(
                        width: AppContentWidth.list,
                        child: _Filters(viewModel: viewModel),
                      ),
                    ),
                    Expanded(child: _list(context, l10n)),
                  ],
                ),
        );
      },
    );
  }

  Widget _list(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    return InfiniteScrollList<OperationsJob>(
      items: viewModel.jobs,
      padding: spacing.pagePadding,
      isLoadingInitial: viewModel.isLoading && viewModel.jobs.isEmpty,
      isLoadingMore: viewModel.isLoadingMore,
      hasMore: viewModel.hasMore,
      onLoadMore: viewModel.loadMore,
      itemBuilder: (context, job) => AdaptiveMaxWidth(
        width: AppContentWidth.detail,
        child: Padding(
          padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
          child: _HistoryCard(job: job, onTap: () => widget.onOpenJob(job)),
        ),
      ),
      emptyBuilder: (context) => QueryEmptyState(
        icon: Icons.history,
        search: viewModel.searchQuery,
        hasFilters: viewModel.hasActiveFilters,
        emptyTitle: l10n.jobsHistoryEmptyTitle,
        emptyMessage: l10n.jobsHistoryEmptyMessage,
        onClear: viewModel.clearFilters,
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.viewModel});

  final JobHistoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DebouncedSearchField(
          value: viewModel.searchQuery,
          hintText: l10n.jobSearchHint,
          clearTooltip: l10n.clearSearchTooltip,
          onChanged: (value) => viewModel.searchQuery = value,
        ),
        SizedBox(height: spacing.sm),
        SegmentedButton<OperationsJobStatus>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: OperationsJobStatus.completed,
              label: Text(l10n.jobStatusCompleted),
            ),
            ButtonSegment(
              value: OperationsJobStatus.cancelled,
              label: Text(l10n.jobStatusCancelled),
            ),
          ],
          selected: {viewModel.statusFilter},
          onSelectionChanged: (selection) {
            viewModel.statusFilter = selection.first;
          },
        ),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.job, required this.onTap});

  final OperationsJob job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final visual = JobStatusVisual.of(context, job.status);
    final finishedAt = job.completedAt ?? job.cancelledAt ?? job.createdAt;
    final subtitle = [
      if (job.customerName.trim().isNotEmpty) job.customerName.trim(),
      if (job.diagnosis.trim().isNotEmpty)
        job.diagnosis.trim()
      else if (job.symptoms.trim().isNotEmpty)
        job.symptoms.trim(),
    ].join(' · ');

    return Material(
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
          child: Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OperationsIconBadge(
                  icon: jobTypeIcon(job.jobType),
                  color: visual.color,
                ),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              job.jobNumber,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PointyTypography.numeric(
                                textTheme.titleSmall ?? const TextStyle(),
                              ).copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          if (job.orderBalanceDue != null &&
                              job.orderBalanceDue! > 0)
                            PointyStatusPill(
                              label: l10n.jobSettlementCreditOpen,
                              icon: Icons.schedule,
                              color: colors.warning,
                            )
                          else
                            PointyStatusPill(
                              label: visual.label,
                              icon: visual.icon,
                              color: visual.color,
                            ),
                        ],
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                      SizedBox(height: spacing.xs),
                      Row(
                        children: [
                          if (finishedAt != null)
                            Text(
                              formatDate(finishedAt),
                              style: textTheme.bodySmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                            ),
                          const Spacer(),
                          if (job.orderReceiptNumber.trim().isNotEmpty)
                            Text(
                              formatMoney(job.billableTotal),
                              style: PointyTypography.numeric(
                                textTheme.bodySmall ?? const TextStyle(),
                              ).copyWith(fontWeight: FontWeight.w700),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
