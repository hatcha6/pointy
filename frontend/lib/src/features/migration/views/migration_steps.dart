import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/migration.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/migration_view_model.dart';
import 'migration_formatting.dart';

/// Renders whichever step of the migration the work is actually at.
class MigrationStepView extends StatelessWidget {
  const MigrationStepView({super.key, required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return switch (viewModel.step) {
      MigrationStep.choose => _ChooseFileStep(viewModel: viewModel),
      MigrationStep.uploading => _UploadStep(viewModel: viewModel),
      MigrationStep.preparing => _PrepareStep(viewModel: viewModel),
      MigrationStep.failed => _FailedStep(viewModel: viewModel),
      MigrationStep.review => _ReviewStep(viewModel: viewModel),
      MigrationStep.running => _RunningStep(viewModel: viewModel),
      MigrationStep.done => _DoneStep(viewModel: viewModel),
    };
  }
}

// --- 1. choose --------------------------------------------------------------
class _ChooseFileStep extends StatelessWidget {
  const _ChooseFileStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final file = viewModel.pickedFile;
    final config = viewModel.uploadConfig;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.drive_folder_upload_outlined,
          title: l10n.migrationChooseTitle,
          description: l10n.migrationChooseSubtitle,
        ),
        SizedBox(height: spacing.md),
        _DropZone(
          file: file,
          formats: config.acceptedExtensions.join('  ·  '),
          maxSizeLabel: formatBytes(config.maxBytes),
          onPick: () => unawaited(viewModel.pickFile()),
        ),
        if (file != null) ...[
          SizedBox(height: spacing.md),
          FilledButton.icon(
            onPressed: () => unawaited(viewModel.startUpload()),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(l10n.migrationStartUploadButton),
          ),
          SizedBox(height: spacing.xs),
          TextButton(
            onPressed: () => unawaited(viewModel.pickFile()),
            child: Text(l10n.migrationChooseAnotherFile),
          ),
        ],
        SizedBox(height: spacing.lg),
        _HelpSection(viewModel: viewModel),
      ],
    );
  }
}

/// The one thing this screen asks for.
///
/// Deliberately large and deliberately alone: it is the whole of step one, and a
/// person who has been told "bring your old data" should not have to hunt for
/// where to put it.
class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.file,
    required this.formats,
    required this.maxSizeLabel,
    required this.onPick,
  });

  final PickedFileInfo? file;
  final String formats;
  final String maxSizeLabel;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final chosen = file != null;

    return Material(
      color: chosen ? colors.primaryContainer : colors.subtleFill,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.symmetric(
            vertical: spacing.lg,
            horizontal: spacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: chosen ? colors.primaryStrong : colors.line,
              width: chosen ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                chosen ? Icons.description_outlined : Icons.upload_file_outlined,
                size: 44,
                color: chosen ? colors.primaryStrong : colors.mutedInk,
              ),
              SizedBox(height: spacing.sm),
              if (chosen) ...[
                Text(
                  file!.name,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatBytes(file!.size),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ] else ...[
                FilledButton.tonalIcon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: Text(l10n.migrationPickFileButton),
                ),
                SizedBox(height: spacing.sm),
                Text(
                  l10n.migrationAcceptedFormats(formats),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.migrationMaxFileSize(maxSizeLabel),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
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

class _HelpSection extends StatelessWidget {
  const _HelpSection({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final systems = viewModel.systems.where((s) => s.implemented).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.migrationWhereIsMyFileTitle,
                style: theme.textTheme.titleSmall,
              ),
              SizedBox(height: spacing.xs),
              Text(
                l10n.migrationWhereIsMyFileBody,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.mutedInk,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        if (systems.isNotEmpty) ...[
          SizedBox(height: spacing.md),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.migrationSupportedSystemsTitle,
                  style: theme.textTheme.titleSmall,
                ),
                SizedBox(height: spacing.xs),
                Text(
                  l10n.migrationSystemDetectedAutomatically,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
                SizedBox(height: spacing.sm),
                Wrap(
                  spacing: spacing.xs,
                  runSpacing: spacing.xs,
                  children: [
                    for (final system in systems)
                      PointyStatusPill(
                        label: system.displayName,
                        icon: Icons.check,
                        color: colors.success,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// --- 2. upload --------------------------------------------------------------
class _UploadStep extends StatelessWidget {
  const _UploadStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final progress = viewModel.uploadProgress;
    final uploading = viewModel.isUploading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: uploading
              ? Icons.cloud_upload_outlined
              : Icons.cloud_off_outlined,
          title: uploading
              ? l10n.migrationUploadingTitle
              : l10n.migrationUploadFailedTitle,
          description: viewModel.source?.originalFilename ?? '',
        ),
        SizedBox(height: spacing.md),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyProgressBar(
                value: progress?.fraction,
                minHeight: 10,
                borderRadius: BorderRadius.circular(5),
              ),
              SizedBox(height: spacing.sm),
              if (progress != null)
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: colors.mutedInk,
                  ),
                  child: Row(
                    children: [
                      Text(
                        l10n.migrationUploadedOf(
                          formatBytes(progress.sentBytes),
                          formatBytes(progress.totalBytes),
                        ),
                      ),
                      const Spacer(),
                      // Rate and ETA appear only once they mean something: a
                      // made-up "2 seconds left" on a gigabyte is worse than
                      // saying nothing.
                      if (progress.bytesPerSecond > 0)
                        Text(
                          l10n.migrationUploadRate(
                            formatBytes(progress.bytesPerSecond.round()),
                          ),
                        ),
                      if (progress.remaining != null) ...[
                        const SizedBox(width: 12),
                        Text(
                          l10n.migrationUploadRemaining(
                            formatDuration(progress.remaining!),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              SizedBox(height: spacing.md),
              PointyDetailCallout(
                icon: Icons.restart_alt,
                title: l10n.migrationUploadResumeNote,
                tone: PointyCalloutTone.neutral,
              ),
            ],
          ),
        ),
        SizedBox(height: spacing.md),
        if (uploading)
          OutlinedButton.icon(
            onPressed: viewModel.cancelUpload,
            icon: const Icon(Icons.close),
            label: Text(l10n.migrationCancelUploadButton),
          )
        else
          FilledButton.icon(
            onPressed: () => unawaited(viewModel.startUpload()),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.migrationResumeUploadButton),
          ),
      ],
    );
  }
}

// --- 3. prepare -------------------------------------------------------------
class _PrepareStep extends StatelessWidget {
  const _PrepareStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final source = viewModel.source;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.auto_awesome_outlined,
          title: l10n.migrationPreparingTitle,
          description: l10n.migrationPreparingSubtitle,
        ),
        SizedBox(height: spacing.md),
        _StageCard(stages: viewModel.stages),
        if (source != null && source.stagedSizeBytes > 0) ...[
          SizedBox(height: spacing.md),
          PointySummaryList(
            rows: [
              PointySummaryRow(
                label: source.originalFilename,
                value: formatBytes(source.stagedSizeBytes),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// --- preparation failed -----------------------------------------------------
class _FailedStep extends StatelessWidget {
  const _FailedStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final source = viewModel.source;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.report_problem_outlined,
          title: l10n.migrationPreparationFailedTitle,
          // The server phrases this for a person and names what it did see —
          // "this is a ZIP", not "unsupported file".
          description: source?.errorMessage ?? '',
        ),
        SizedBox(height: spacing.md),
        _StageCard(stages: viewModel.stages),
        SizedBox(height: spacing.md),
        FilledButton.icon(
          onPressed: () => unawaited(viewModel.startOver()),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.migrationTryAnotherFileButton),
        ),
      ],
    );
  }
}

// --- 4. review --------------------------------------------------------------
class _ReviewStep extends StatelessWidget {
  const _ReviewStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final source = viewModel.source;
    final analysis = viewModel.analysis;
    final lastRun = viewModel.lastRun;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.inventory_2_outlined,
          title: l10n.migrationFoundTitle,
          description: source?.detection.displayName ?? '',
          pills: [
            if ((source?.detectedVersion ?? '').isNotEmpty)
              PointyHeroPill(
                label: source!.detectedVersion,
                icon: Icons.verified_outlined,
              ),
            if (analysis.hasHistory)
              PointyHeroPill(
                label: l10n.migrationHistoryRange(
                  analysis.historyFrom,
                  analysis.historyTo,
                ),
                icon: Icons.event_outlined,
              ),
          ],
        ),
        SizedBox(height: spacing.md),
        if (analysis.isEmpty)
          PointyInlineMessage.warning(message: l10n.migrationNothingToImport)
        else
          _ContentsGrid(viewModel: viewModel),
        SizedBox(height: spacing.md),
        _EntitySelection(viewModel: viewModel),
        SizedBox(height: spacing.md),
        _StockSourceSelection(viewModel: viewModel),
        if (lastRun != null && lastRun.isDryRun) ...[
          SizedBox(height: spacing.md),
          _DryRunVerdict(viewModel: viewModel),
        ],
        SizedBox(height: spacing.lg),
        _ReviewActions(viewModel: viewModel),
      ],
    );
  }
}

/// The payoff: real numbers, before anything is agreed to.
class _ContentsGrid extends StatelessWidget {
  const _ContentsGrid({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final entities = viewModel.analysis.entities;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 560 ? 3 : 2;
        return Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            for (final entity in entities)
              SizedBox(
                width:
                    (constraints.maxWidth - spacing.sm * (columns - 1)) /
                    columns,
                child: _CountTile(
                  label: viewModel.entityLabel(entity.entityType),
                  count: entity.count,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatCount(count),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.primaryStrong,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

class _EntitySelection extends StatelessWidget {
  const _EntitySelection({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final entities = viewModel.supportedEntities;
    if (entities.isEmpty) return const SizedBox.shrink();

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.migrationWhatToTransferTitle,
            style: theme.textTheme.titleSmall,
          ),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: [
              for (final entity in entities)
                FilterChip(
                  label: Text(viewModel.entityLabel(entity)),
                  selected: viewModel.selectedEntities.contains(entity),
                  onSelected: (selected) =>
                      viewModel.toggleEntity(entity, selected),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StockSourceSelection extends StatelessWidget {
  const _StockSourceSelection({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.migrationStockSourceSectionTitle,
            style: theme.textTheme.titleSmall,
          ),
          SizedBox(height: spacing.xs),
          for (final option in MigrationStockSource.values)
            _StockSourceTile(
              label: _label(l10n, option),
              subtitle: _subtitle(l10n, option),
              selected: viewModel.stockSource == option,
              onTap: () => viewModel.setStockSource(option),
            ),
        ],
      ),
    );
  }

  String _label(AppLocalizations l10n, MigrationStockSource option) =>
      switch (option) {
        MigrationStockSource.snapshot => l10n.migrationStockSourceSnapshotLabel,
        MigrationStockSource.reconstruct =>
          l10n.migrationStockSourceReconstructLabel,
        MigrationStockSource.none => l10n.migrationStockSourceNoneLabel,
      };

  String _subtitle(AppLocalizations l10n, MigrationStockSource option) =>
      switch (option) {
        MigrationStockSource.snapshot =>
          l10n.migrationStockSourceSnapshotSubtitle,
        MigrationStockSource.reconstruct =>
          l10n.migrationStockSourceReconstructSubtitle,
        MigrationStockSource.none => l10n.migrationStockSourceNoneSubtitle,
      };
}

/// One stock-source choice, as a tappable card.
///
/// The app uses selectable surfaces rather than radio buttons throughout, and
/// each of these options needs a sentence of explanation next to it — the
/// difference between copying the old system's quantities and recomputing them
/// from invoices is not something a bare label conveys.
class _StockSourceTile extends StatelessWidget {
  const _StockSourceTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? colors.primaryStrong : colors.line,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: selected ? colors.primaryStrong : colors.mutedInk,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                          height: 1.5,
                        ),
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

class _DryRunVerdict extends StatelessWidget {
  const _DryRunVerdict({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final run = viewModel.lastRun!;
    final clean = run.totalFailed == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: clean ? Icons.verified : Icons.warning_amber_rounded,
          title: clean
              ? l10n.migrationDryRunCleanTitle
              : l10n.migrationDryRunIssuesTitle,
          message: clean
              ? l10n.migrationDryRunCleanMessage
              : '${formatCount(run.totalFailed)} ${l10n.migrationSummaryFailed}',
          tone: clean ? PointyCalloutTone.success : PointyCalloutTone.warning,
        ),
        SizedBox(height: spacing.sm),
        _RunSummary(viewModel: viewModel, run: run),
        if (!clean) ...[
          SizedBox(height: spacing.sm),
          _IssueList(viewModel: viewModel),
        ],
      ],
    );
  }
}

class _ReviewActions extends StatelessWidget {
  const _ReviewActions({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.isStartingRun;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.canImport)
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => unawaited(viewModel.startRun(dryRun: false)),
            icon: const Icon(Icons.download_done),
            label: Text(l10n.migrationImportButton),
          )
        else ...[
          FilledButton.icon(
            onPressed: busy || viewModel.selectedEntities.isEmpty
                ? null
                : () => unawaited(viewModel.startRun(dryRun: true)),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(l10n.migrationPreviewButton),
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.migrationImportGatedHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ],
        SizedBox(height: spacing.sm),
        TextButton.icon(
          onPressed: viewModel.isDiscarding
              ? null
              : () => unawaited(_confirmDiscard(context)),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text(l10n.migrationDiscardFileButton),
        ),
      ],
    );
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.migrationDiscardFileButton),
        content: Text(l10n.migrationDiscardFileConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await viewModel.startOver();
  }
}

// --- 5. running -------------------------------------------------------------
class _RunningStep extends StatelessWidget {
  const _RunningStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final run = viewModel.activeRun;
    final isDryRun = run?.isDryRun ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: isDryRun ? Icons.fact_check_outlined : Icons.sync,
          title: isDryRun
              ? l10n.migrationDryRunningTitle
              : l10n.migrationImportingTitle,
          description: run?.progressMessage ?? l10n.migrationRunningLabel,
        ),
        SizedBox(height: spacing.md),
        _StageCard(stages: viewModel.stages),
      ],
    );
  }
}

// --- 6. done ----------------------------------------------------------------
class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final run = viewModel.lastRun;
    final source = viewModel.source;
    final purged = source?.isPurged ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailHero(
          icon: Icons.check_circle_outline,
          title: l10n.migrationDoneTitle,
          description: run?.progressMessage ?? '',
          pills: [
            if (run != null)
              PointyHeroPill(
                label: l10n.migrationRecordsImported(
                  formatCount(run.totalCreated + run.totalUpdated),
                ),
                icon: Icons.inventory_2_outlined,
              ),
          ],
        ),
        SizedBox(height: spacing.md),
        // Closing the loop the first screen opened: the file is gone.
        PointyDetailCallout(
          icon: purged ? Icons.delete_sweep_outlined : Icons.schedule,
          title: purged
              ? l10n.migrationFileDeletedNotice
              : l10n.migrationFileKeptNotice,
          tone: purged ? PointyCalloutTone.success : PointyCalloutTone.warning,
        ),
        if (run != null) ...[
          SizedBox(height: spacing.md),
          _RunSummary(viewModel: viewModel, run: run),
        ],
        SizedBox(height: spacing.lg),
        OutlinedButton.icon(
          onPressed: () => unawaited(viewModel.startOver()),
          icon: const Icon(Icons.add),
          label: Text(l10n.migrationStartAnotherButton),
        ),
      ],
    );
  }
}

// --- shared pieces ----------------------------------------------------------
class _StageCard extends StatelessWidget {
  const _StageCard({required this.stages});

  final List<MigrationStage> stages;

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) {
      return const _Card(child: Center(child: PointySpinner()));
    }
    return _Card(
      child: PointyStageTimeline(
        stages: [
          for (final stage in stages)
            PointyStageEntry(
              label: stage.label,
              status: _status(stage.status),
              detail: stage.detail,
              percent: stage.percent,
            ),
        ],
      ),
    );
  }

  PointyStageStatus _status(String raw) => switch (raw) {
    'running' => PointyStageStatus.running,
    'done' => PointyStageStatus.done,
    'failed' => PointyStageStatus.failed,
    'skipped' => PointyStageStatus.skipped,
    _ => PointyStageStatus.pending,
  };
}

class _RunSummary extends StatelessWidget {
  const _RunSummary({required this.viewModel, required this.run});

  final MigrationViewModel viewModel;
  final MigrationRun run;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summaries = run.entitySummaries.where((s) => s.total > 0).toList();
    if (summaries.isEmpty) return const SizedBox.shrink();
    return PointySummaryList(
      rows: [
        for (final summary in summaries)
          PointySummaryRow(
            label: viewModel.entityLabel(summary.entityType),
            value: [
              if (summary.created > 0)
                '${formatCount(summary.created)} ${l10n.migrationSummaryCreated}',
              if (summary.updated > 0)
                '${formatCount(summary.updated)} ${l10n.migrationSummaryUpdated}',
              if (summary.failed > 0)
                '${formatCount(summary.failed)} ${l10n.migrationSummaryFailed}',
            ].join(' · '),
          ),
      ],
    );
  }
}

class _IssueList extends StatelessWidget {
  const _IssueList({required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final issues = viewModel.issues;
    if (issues.isEmpty) {
      return OutlinedButton.icon(
        onPressed: viewModel.isLoadingIssues
            ? null
            : () => unawaited(viewModel.loadIssues()),
        icon: const Icon(Icons.list_alt),
        label: Text(l10n.migrationViewIssuesButton),
      );
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final issue in issues.take(30))
            PointyDataRow(
              leading: Icon(
                issue.severity == 'error'
                    ? Icons.error_outline
                    : Icons.warning_amber_rounded,
                size: 18,
                color: issue.severity == 'error'
                    ? context.pointyColors.danger
                    : context.pointyColors.warning,
              ),
              title: viewModel.entityLabel(issue.entityType),
              subtitle: issue.message,
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Container(
      padding: EdgeInsets.all(spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.line),
      ),
      child: child,
    );
  }
}
