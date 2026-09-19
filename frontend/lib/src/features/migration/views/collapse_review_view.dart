import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/migration_collapse.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/collapse_view_model.dart';
import 'collapse_candidate_sheet.dart';
import 'collapse_reasons.dart';
import 'migration_formatting.dart';

/// §12's screen: a shop's own catalogue, folding.
///
/// Built around one sentence — «٣٤٠ صنفًا ← ١٢ منتجًا · ٣١ خيارًا · ٣٤٠ وحدة» —
/// because that sentence is the argument. Everything below it exists so the
/// owner can check it: the products it proposes, the rows it is least sure
/// about, and the ones it deliberately left alone.
class CollapseReviewView extends StatelessWidget {
  const CollapseReviewView({super.key, required this.viewModel});

  final CollapseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) => CollapseReviewBody(
        plan: viewModel.plan,
        clusters: viewModel.clusters,
        candidates: viewModel.candidates,
        filter: viewModel.filter,
        stemKeyFilter: viewModel.stemKeyFilter,
        isLoading: viewModel.isLoading,
        isProposing: viewModel.isProposing,
        isApproving: viewModel.isApproving,
        isLoadingCandidates: viewModel.isLoadingCandidates,
        errorMessage: viewModel.errorMessage,
        onPropose: () => unawaited(viewModel.propose()),
        onFilter: (value) => unawaited(viewModel.setFilter(value)),
        onShowCluster: (stemKey) => unawaited(viewModel.showCluster(stemKey)),
        onSearch: (value) => unawaited(viewModel.setSearch(value)),
        onApprove: () => unawaited(viewModel.approve()),
        onEdit: (candidate, changes) =>
            unawaited(viewModel.editCandidate(candidate, changes)),
        onRename: (stemKey, stem) =>
            unawaited(viewModel.renameCluster(stemKey, stem)),
      ),
    );
  }
}

/// The screen as a pure function of its state, so the preview harness and the
/// tests can render any of it without a backend.
class CollapseReviewBody extends StatelessWidget {
  const CollapseReviewBody({
    super.key,
    required this.plan,
    required this.clusters,
    required this.candidates,
    required this.filter,
    this.stemKeyFilter = '',
    this.isLoading = false,
    this.isProposing = false,
    this.isApproving = false,
    this.isLoadingCandidates = false,
    this.errorMessage,
    this.onPropose,
    this.onFilter,
    this.onShowCluster,
    this.onSearch,
    this.onApprove,
    this.onEdit,
    this.onRename,
  });

  final CollapsePlan? plan;
  final List<CollapseCluster> clusters;
  final List<CollapseCandidate> candidates;
  final CollapseFilter filter;
  final String stemKeyFilter;
  final bool isLoading;
  final bool isProposing;
  final bool isApproving;
  final bool isLoadingCandidates;
  final String? errorMessage;
  final VoidCallback? onPropose;
  final ValueChanged<CollapseFilter>? onFilter;
  final ValueChanged<String>? onShowCluster;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onApprove;
  final void Function(CollapseCandidate, Map<String, Object?>)? onEdit;
  final void Function(String stemKey, String stem)? onRename;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final current = plan;

    if (isLoading) {
      return const PointyLoadingArea();
    }
    if (current == null) {
      return _Intro(isProposing: isProposing, onPropose: onPropose);
    }
    if (current.isBuilding) {
      return _Building(plan: current);
    }
    if (current.isFailed) {
      return PointyErrorState(
        title: l10n.collapseFailedTitle,
        message: current.errorMessage,
        action: OutlinedButton(
          onPressed: onPropose,
          child: Text(l10n.collapseRebuildButton),
        ),
      );
    }
    if (current.stats.units == 0) {
      return PointyEmptyState(
        icon: Icons.inventory_2_outlined,
        title: l10n.collapseTitle,
        message: l10n.collapseNothingToCollapse,
        action: OutlinedButton(
          onPressed: onPropose,
          child: Text(l10n.collapseRebuildButton),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorMessage != null) ...[
          PointyInlineMessage.error(message: errorMessage!),
          SizedBox(height: spacing.sm),
        ],
        _Headline(plan: current),
        SizedBox(height: spacing.md),
        if (current.isApproved || current.isApplied) ...[
          PointyDetailCallout(
            icon: Icons.verified_outlined,
            title: current.isApplied
                ? l10n.collapseAppliedTitle
                : l10n.collapseApprovedTitle,
            message: current.isApplied
                ? l10n.collapseWillEnableSerialized
                : l10n.collapseApprovedBody,
          ),
          SizedBox(height: spacing.md),
        ],
        _Clusters(
          clusters: clusters,
          selected: stemKeyFilter,
          onShow: onShowCluster,
          onRename: current.isEditable ? onRename : null,
        ),
        SizedBox(height: spacing.md),
        _ReviewList(
          plan: current,
          candidates: candidates,
          filter: filter,
          isLoading: isLoadingCandidates,
          onFilter: onFilter,
          onSearch: onSearch,
          onEdit: current.isEditable ? onEdit : null,
        ),
        if (current.isReady) ...[
          SizedBox(height: spacing.lg),
          PointyInlineMessage.warning(
            message: l10n.collapseWillEnableSerialized,
          ),
          SizedBox(height: spacing.sm),
          FilledButton.icon(
            onPressed: isApproving ? null : onApprove,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(l10n.collapseApproveButton),
          ),
        ],
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.isProposing, this.onPropose});

  final bool isProposing;
  final VoidCallback? onPropose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.call_merge_outlined,
          title: l10n.collapseIntroTitle,
          description: l10n.collapseIntroBody,
        ),
        SizedBox(height: spacing.md),
        FilledButton.icon(
          onPressed: isProposing ? null : onPropose,
          icon: const Icon(Icons.search_outlined),
          label: Text(l10n.collapseProposeButton),
        ),
      ],
    );
  }
}

class _Building extends StatelessWidget {
  const _Building({required this.plan});

  final CollapsePlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.hourglass_top_outlined,
          title: l10n.collapseBuildingTitle,
          description: l10n.collapseBuildingBody,
        ),
        SizedBox(height: spacing.md),
        if (plan.stages.isEmpty)
          const PointyProgressBar(value: null)
        else
          PointyStageTimeline(
            stages: [
              for (final stage in plan.stages)
                PointyStageEntry(
                  label: stage.label,
                  status: switch (stage.status) {
                    'running' => PointyStageStatus.running,
                    'done' => PointyStageStatus.done,
                    'failed' => PointyStageStatus.failed,
                    'skipped' => PointyStageStatus.skipped,
                    _ => PointyStageStatus.pending,
                  },
                  detail: stage.detail,
                  percent: stage.percent,
                ),
            ],
          ),
      ],
    );
  }
}

/// The sentence the screen exists to say, and the numbers under it.
class _Headline extends StatelessWidget {
  const _Headline({required this.plan});

  final CollapsePlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final stats = plan.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.call_merge_outlined,
          title: l10n.collapseTitle,
          value: l10n.collapseHeadline(
            formatCount(stats.sourceProducts),
            formatCount(stats.units),
          ),
          valueSubtitle: l10n.collapseUnitsSplit(
            formatCount(stats.unitsInStock),
            formatCount(stats.unitsSold),
          ),
          pills: [
            if (plan.assetTypeName.isNotEmpty)
              PointyHeroPill(
                label: plan.assetTypeName,
                icon: Icons.devices_other_outlined,
              ),
            PointyHeroPill(
              label: l10n.collapseNeedsReviewCount(stats.needsReview),
              icon: Icons.rate_review_outlined,
            ),
          ],
        ),
        SizedBox(height: spacing.md),
        PointyMetricGrid(
          metrics: [
            // The source count is already the first half of the headline; a
            // tile repeating it would make the grid five, which wraps to a
            // lone card.
            PointyMetricGridItem(
              label: l10n.collapseProducts,
              value: formatCount(stats.products),
              icon: Icons.category_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.collapseVariants,
              value: formatCount(stats.variants),
              icon: Icons.tune_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.collapseUnits,
              value: formatCount(stats.units),
              icon: Icons.qr_code_2_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.collapseKept,
              value: formatCount(stats.kept),
              icon: Icons.do_not_touch_outlined,
            ),
          ],
          minTileWidth: 150,
          maxColumns: 3,
          gap: PointyMetricGridGap.compact,
        ),
      ],
    );
  }
}

class _Clusters extends StatelessWidget {
  const _Clusters({
    required this.clusters,
    required this.selected,
    this.onShow,
    this.onRename,
  });

  final List<CollapseCluster> clusters;
  final String selected;
  final ValueChanged<String>? onShow;
  final void Function(String stemKey, String stem)? onRename;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    if (clusters.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.collapseProposedProductsTitle),
        SizedBox(height: spacing.sm),
        for (final cluster in clusters)
          Padding(
            padding: EdgeInsets.only(bottom: spacing.xs),
            child: Material(
              color: cluster.stemKey == selected
                  ? colors.primaryContainer
                  : colors.subtleFill,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onShow == null ? null : () => onShow!(cluster.stemKey),
                child: Padding(
                  padding: EdgeInsets.all(spacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cluster.stem,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l10n.collapseClusterSummary(
                                formatCount(cluster.units),
                                formatCount(cluster.variants),
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                            ),
                            if (cluster.displayOptions.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final value in cluster.displayOptions)
                                    _OptionChip(label: value),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (cluster.needsReview > 0)
                        Padding(
                          padding: EdgeInsetsDirectional.only(end: spacing.xs),
                          child: Icon(
                            Icons.error_outline,
                            size: 18,
                            color: colors.warning,
                          ),
                        ),
                      if (onRename != null)
                        IconButton(
                          tooltip: l10n.collapseRenameClusterTitle,
                          icon: const Icon(Icons.drive_file_rename_outline),
                          onPressed: () => _rename(context, cluster),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, CollapseCluster cluster) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => PointyTextEntryDialog(
        title: l10n.collapseRenameClusterTitle,
        fieldLabel: l10n.collapseEditProductName,
        confirmLabel: l10n.collapseEditSave,
        initialValue: cluster.stem,
        message: l10n.collapseEditProductNameHelp,
        icon: Icons.drive_file_rename_outline,
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    onRename?.call(cluster.stemKey, name.trim());
  }
}

class _ReviewList extends StatelessWidget {
  const _ReviewList({
    required this.plan,
    required this.candidates,
    required this.filter,
    required this.isLoading,
    this.onFilter,
    this.onSearch,
    this.onEdit,
  });

  final CollapsePlan plan;
  final List<CollapseCandidate> candidates;
  final CollapseFilter filter;
  final bool isLoading;
  final ValueChanged<CollapseFilter>? onFilter;
  final ValueChanged<String>? onSearch;
  final void Function(CollapseCandidate, Map<String, Object?>)? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: spacing.xs,
          runSpacing: spacing.xs,
          children: [
            for (final value in CollapseFilter.values)
              FilterChip(
                label: Text(_filterLabel(l10n, value)),
                selected: filter == value,
                onSelected: onFilter == null ? null : (_) => onFilter!(value),
              ),
          ],
        ),
        SizedBox(height: spacing.sm),
        if (onSearch != null)
          TextField(
            decoration: InputDecoration(
              hintText: l10n.collapseSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
            onSubmitted: onSearch,
          ),
        SizedBox(height: spacing.sm),
        if (isLoading)
          const PointySkeletonListTile()
        else if (candidates.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.md),
            child: Text(
              l10n.collapseRowsEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
          )
        else
          for (final candidate in candidates)
            Padding(
              padding: EdgeInsets.only(bottom: spacing.xs),
              child: CollapseCandidateTile(
                candidate: candidate,
                lowConfidence: plan.lowConfidence,
                onTap: onEdit == null ? null : () => _edit(context, candidate),
              ),
            ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, CollapseCandidate candidate) async {
    final changes = await showCollapseCandidateSheet(
      context,
      candidate: candidate,
    );
    if (changes == null || changes.isEmpty) return;
    onEdit?.call(candidate, changes);
  }

  String _filterLabel(AppLocalizations l10n, CollapseFilter value) =>
      switch (value) {
        CollapseFilter.needsReview => l10n.collapseFilterNeedsReview,
        CollapseFilter.collapsing => l10n.collapseFilterCollapsing,
        CollapseFilter.kept => l10n.collapseFilterKept,
      };
}

/// One legacy row: what it was called, and what it becomes.
class CollapseCandidateTile extends StatelessWidget {
  const CollapseCandidateTile({
    super.key,
    required this.candidate,
    required this.lowConfidence,
    this.onTap,
  });

  final CollapseCandidate candidate;
  final double lowConfidence;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final uncertain =
        candidate.isCollapsing && candidate.confidence < lowConfidence;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(spacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: uncertain ? colors.warning : colors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                candidate.sourceName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: spacing.xs),
              if (!candidate.isCollapsing)
                Text(
                  l10n.collapseStaysProduct,
                  style: theme.textTheme.titleSmall,
                )
              else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_left,
                      size: 16,
                      color: colors.mutedInk,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        candidate.stem,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    PointyStatusPill(
                      label: candidate.isSold
                          ? l10n.collapseUnitSold
                          : l10n.collapseUnitInStock,
                      color: candidate.isSold
                          ? colors.mutedInk
                          : colors.success,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _OptionChip(
                      label: candidate.identifier,
                      icon: Icons.qr_code_2_outlined,
                    ),
                    if (candidate.optionsLabel.isNotEmpty)
                      _OptionChip(label: candidate.optionsLabel),
                    for (final entry in candidate.attributes.entries)
                      _OptionChip(label: '${entry.value}'),
                  ],
                ),
              ],
              if (candidate.reasons.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    for (final reason in candidate.reasons)
                      collapseReasonLabel(l10n, reason),
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: uncertain ? colors.warning : colors.mutedInk,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colors.mutedInk),
            const SizedBox(width: 4),
          ],
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
