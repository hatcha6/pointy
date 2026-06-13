import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/bill_of_materials.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/operations_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/units.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/jobs_board_view_model.dart';
import '../view_models/recipes_view_model.dart';
import 'job_intake_wizard.dart';
import 'recipes_page.dart';

export '../../../shared/units.dart' show formatQuantity, unitLabel;

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

class JobsScreen extends StatefulWidget {
  const JobsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.navigation,
    required this.currentUser,
    required this.contactRepository,
    required this.operationsRepository,
    required this.catalogRepository,
    required this.recipesViewModel,
    required this.onOpenJob,
  });

  final JobsBoardViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final PosUser currentUser;
  final ContactRepository contactRepository;
  final OperationsRepository operationsRepository;
  final CatalogRepository catalogRepository;
  final RecipesViewModel recipesViewModel;
  final ValueChanged<OperationsJob> onOpenJob;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  final _advancingJobIds = <int>{};

  @override
  void initState() {
    super.initState();
    widget.viewModel.currentUserId = widget.currentUser.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.loadAll());
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.operations,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.jobsBoardTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            reserveLoadingSlot: false,
            actions: [
              if (widget.capabilities.canManageRecipes)
                IconButton(
                  tooltip: l10n.recipesTitle,
                  onPressed: _openRecipes,
                  icon: const Icon(Icons.menu_book_outlined),
                ),
              IconButton(
                tooltip: l10n.refreshJobsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.loadAll,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: widget.capabilities.canCreateJobs &&
                  viewModel.enabledTemplates.isNotEmpty
              ? FloatingActionButton.extended(
                  onPressed: viewModel.isMutating ? null : _openNewJobMenu,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.newJobButton),
                )
              : null,
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.jobs.isEmpty &&
        viewModel.templates.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.jobs.isEmpty) {
      return PointyErrorState(
        title: l10n.jobsLoadError,
        icon: Icons.handyman_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.loadAll,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(spacing.md, spacing.sm, spacing.md, 0),
          child: _FilterBar(
            searchController: _searchController,
            onSearchChanged: _onSearchChanged,
            viewModel: viewModel,
          ),
        ),
        Expanded(child: _buildJobsArea(context, l10n)),
      ],
    );
  }

  Widget _buildJobsArea(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final showBoard = viewModel.statusFilter == OperationsJobStatus.open;

    if (viewModel.jobs.isEmpty && !viewModel.isLoading) {
      return PointyEmptyState(
        icon: Icons.handyman_outlined,
        title: l10n.jobsEmptyTitle,
        message: l10n.jobsEmptyMessage,
        action: widget.capabilities.canCreateJobs &&
                viewModel.enabledTemplates.isNotEmpty
            ? FilledButton.icon(
                onPressed: _openNewJobMenu,
                icon: const Icon(Icons.add),
                label: Text(l10n.newJobButton),
              )
            : null,
      );
    }

    if (!showBoard) {
      return ListView(
        padding: spacing.pagePadding,
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final job in viewModel.jobs)
                  _JobCard(
                    job: job,
                    isBusy: _advancingJobIds.contains(job.id),
                    onTap: () => widget.onOpenJob(job),
                    onAdvance: null,
                  ),
              ],
            ),
          ),
        ],
      );
    }

    final templates = viewModel.enabledTemplates
        .where(
          (template) =>
              viewModel.jobTypeFilter == null ||
              template.jobType == viewModel.jobTypeFilter,
        )
        .toList(growable: false);
    final isWide =
        AppBreakpoints.of(context).index >= AppBreakpoint.desktop.index;

    if (isWide && templates.length == 1) {
      return _KanbanBoard(
        template: templates.first,
        jobsByStage: viewModel.jobsByStage(templates.first),
        advancingJobIds: _advancingJobIds,
        onOpenJob: widget.onOpenJob,
        onAdvance: _advanceJob,
      );
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final template in templates) ...[
                if (templates.length > 1)
                  PointySectionHeader(
                    title: template.name,
                    leading: Icon(jobTypeIcon(template.jobType)),
                  ),
                for (final stage in template.stages)
                  ..._stageGroup(
                    context,
                    stage,
                    widget.viewModel.jobsByStage(template)[stage.id] ??
                        const [],
                  ),
                SizedBox(height: spacing.md),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _stageGroup(
    BuildContext context,
    WorkflowStage stage,
    List<OperationsJob> jobs,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return [
      Padding(
        padding: EdgeInsets.symmetric(vertical: spacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                stage.name,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            PointyStatusPill(
              label: l10n.jobCountLabel(jobs.length),
              color: jobs.isEmpty
                  ? context.pointyColors.mutedInk
                  : context.pointyColors.primaryStrong,
            ),
          ],
        ),
      ),
      for (final job in jobs)
        _JobCard(
          job: job,
          isBusy: _advancingJobIds.contains(job.id),
          onTap: () => widget.onOpenJob(job),
          onAdvance: job.nextStage == null ? null : () => _advanceJob(job),
        ),
    ];
  }

  Future<void> _openRecipes() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipesPage(
          viewModel: widget.recipesViewModel,
          catalogRepository: widget.catalogRepository,
        ),
      ),
    );
    // Recipes drive the production menu — pick up edits immediately.
    if (mounted) {
      unawaited(widget.viewModel.loadAll());
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      widget.viewModel.searchQuery = value;
    });
  }

  Future<void> _advanceJob(OperationsJob job) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final nextStage = job.nextStage;
    if (nextStage == null) {
      return;
    }
    setState(() => _advancingJobIds.add(job.id));
    final result = await widget.operationsRepository.transitionJob(
      job.id,
      toStage: nextStage.id,
      idempotencyKey:
          'job-advance-${job.id}-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (!mounted) {
      return;
    }
    setState(() => _advancingJobIds.remove(job.id));
    switch (result) {
      case Ok<OperationsJob>():
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.jobStageChangedMessage(nextStage.name))),
        );
        await widget.viewModel.loadJobs();
      case Error<OperationsJob>():
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.operationsActionError)),
        );
    }
  }

  Future<void> _openNewJobMenu() async {
    final l10n = AppLocalizations.of(context)!;
    final templates = widget.viewModel.enabledTemplates;
    if (templates.isEmpty) {
      return;
    }
    if (templates.length == 1) {
      await _startJobForTemplate(templates.first);
      return;
    }
    final template = await showAdaptiveModalBottomSheet<WorkflowTemplate>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.newJobButton,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final template in templates)
              ListTile(
                leading: Icon(jobTypeIcon(template.jobType)),
                title: Text(template.name),
                subtitle: Text(jobTypeLabel(l10n, template.jobType)),
                onTap: () => Navigator.of(sheetContext).pop(template),
              ),
          ],
        ),
      ),
    );
    if (template != null && mounted) {
      await _startJobForTemplate(template);
    }
  }

  Future<void> _startJobForTemplate(WorkflowTemplate template) async {
    switch (template.jobType) {
      case OperationsJobType.production:
        await _openProductionDialog(template);
      case OperationsJobType.repair:
      case OperationsJobType.kitchen:
      case OperationsJobType.workOrder:
        final job = await Navigator.of(context).push<OperationsJob>(
          MaterialPageRoute(
            builder: (_) => JobIntakeWizard(
              template: template,
              boardViewModel: widget.viewModel,
              contactRepository: widget.contactRepository,
              operationsRepository: widget.operationsRepository,
            ),
          ),
        );
        if (job != null && mounted) {
          widget.onOpenJob(job);
        }
    }
  }

  Future<void> _openProductionDialog(WorkflowTemplate template) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final boms = widget.viewModel.boms
        .where((bom) => bom.isActive)
        .toList(growable: false);
    if (boms.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.productionNoRecipesMessage)),
      );
      return;
    }

    final draft = await showDialog<OperationsJobDraft>(
      context: context,
      builder: (dialogContext) => _ProductionBatchDialog(
        template: template,
        boms: boms,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final job = await widget.viewModel.createJob(draft);
    if (!mounted) {
      return;
    }
    if (job == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.intakeJobCreated(job.jobNumber))),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.onSearchChanged,
    required this.viewModel,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final JobsBoardViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final types = {
      for (final template in viewModel.enabledTemplates) template.jobType,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: searchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.jobSearchHint,
            isDense: true,
          ),
          onChanged: onSearchChanged,
        ),
        SizedBox(height: spacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              SegmentedButton<OperationsJobStatus?>(
                segments: [
                  ButtonSegment(
                    value: OperationsJobStatus.open,
                    label: Text(l10n.jobFilterOpenOnly),
                  ),
                  ButtonSegment(
                    value: OperationsJobStatus.completed,
                    label: Text(l10n.jobFilterDone),
                  ),
                  const ButtonSegment(value: null, label: _AllLabel()),
                ],
                selected: {viewModel.statusFilter},
                onSelectionChanged: (selection) {
                  viewModel.statusFilter = selection.first;
                },
              ),
              SizedBox(width: spacing.sm),
              FilterChip(
                label: Text(l10n.jobFilterMine),
                selected: viewModel.assignedToMe,
                onSelected: (selected) {
                  viewModel.assignedToMe = selected;
                },
              ),
              if (types.length > 1) ...[
                SizedBox(width: spacing.sm),
                for (final type in types)
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: spacing.xs),
                    child: FilterChip(
                      avatar: Icon(jobTypeIcon(type), size: 18),
                      label: Text(jobTypeLabel(l10n, type)),
                      selected: viewModel.jobTypeFilter == type,
                      onSelected: (selected) {
                        viewModel.jobTypeFilter = selected ? type : null;
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AllLabel extends StatelessWidget {
  const _AllLabel();

  @override
  Widget build(BuildContext context) {
    return Text(AppLocalizations.of(context)!.jobFilterAll);
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.isBusy,
    required this.onTap,
    required this.onAdvance,
  });

  final OperationsJob job;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback? onAdvance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final subtitleParts = <String>[
      if (job.customerName.trim().isNotEmpty) job.customerName,
      if (job.outputVariantName.trim().isNotEmpty)
        '${job.outputQuantity ?? ''} × ${job.outputVariantName}'.trim(),
      if (job.dueAt != null)
        '${l10n.jobDueAtLabel}: ${formatDateTime(job.dueAt!)}',
    ];

    return Card(
      margin: EdgeInsets.only(bottom: spacing.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(spacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      job.jobNumber,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (job.priority != OperationsJobPriority.normal)
                    PointyStatusPill(
                      label: jobPriorityLabel(l10n, job.priority),
                      icon: Icons.flag_outlined,
                      color: switch (job.priority) {
                        OperationsJobPriority.urgent => colors.danger,
                        OperationsJobPriority.high => colors.warning,
                        _ => colors.mutedInk,
                      },
                    ),
                  if (job.status != OperationsJobStatus.open) ...[
                    SizedBox(width: spacing.xs),
                    PointyStatusPill(
                      label: jobStatusLabel(l10n, job.status),
                      color: job.status == OperationsJobStatus.completed
                          ? colors.success
                          : colors.danger,
                    ),
                  ],
                  if (job.orderReceiptNumber.trim().isNotEmpty) ...[
                    SizedBox(width: spacing.xs),
                    PointyStatusPill(
                      label: l10n.jobInvoicedBadge(job.orderReceiptNumber),
                      icon: Icons.receipt_long_outlined,
                      color: colors.success,
                    ),
                  ],
                ],
              ),
              if (subtitleParts.isNotEmpty) ...[
                SizedBox(height: spacing.xs),
                Text(
                  subtitleParts.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (onAdvance != null && job.nextStage != null) ...[
                SizedBox(height: spacing.sm),
                FilledButton.tonalIcon(
                  onPressed: isBusy ? null : onAdvance,
                  icon: isBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward, size: 18),
                  label: Text(l10n.jobNextActionButton(job.nextStage!.name)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _KanbanBoard extends StatelessWidget {
  const _KanbanBoard({
    required this.template,
    required this.jobsByStage,
    required this.advancingJobIds,
    required this.onOpenJob,
    required this.onAdvance,
  });

  final WorkflowTemplate template;
  final Map<int, List<OperationsJob>> jobsByStage;
  final Set<int> advancingJobIds;
  final ValueChanged<OperationsJob> onOpenJob;
  final Future<void> Function(OperationsJob job) onAdvance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: spacing.pagePadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final stage in template.stages)
            Container(
              width: 320,
              margin: EdgeInsetsDirectional.only(end: spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          stage.name,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      PointyStatusPill(
                        label: l10n.jobCountLabel(
                          (jobsByStage[stage.id] ?? const []).length,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: spacing.sm),
                  for (final job in jobsByStage[stage.id] ?? const [])
                    _JobCard(
                      job: job,
                      isBusy: advancingJobIds.contains(job.id),
                      onTap: () => onOpenJob(job),
                      onAdvance: job.nextStage == null
                          ? null
                          : () => onAdvance(job),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProductionBatchDialog extends StatefulWidget {
  const _ProductionBatchDialog({required this.template, required this.boms});

  final WorkflowTemplate template;
  final List<BillOfMaterials> boms;

  @override
  State<_ProductionBatchDialog> createState() => _ProductionBatchDialogState();
}

class _ProductionBatchDialogState extends State<_ProductionBatchDialog> {
  late BillOfMaterials _bom;
  var _batches = 1;

  @override
  void initState() {
    super.initState();
    _bom = widget.boms.first;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final outputName =
        _bom.variantName.isEmpty ? _bom.productName : _bom.variantName;

    return AlertDialog(
      icon: const Icon(Icons.precision_manufacturing_outlined),
      title: Text(l10n.productionNewBatchButton),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<BillOfMaterials>(
              initialValue: _bom,
              decoration: InputDecoration(
                labelText: l10n.productionRecipeLabel,
              ),
              items: [
                for (final bom in widget.boms)
                  DropdownMenuItem(value: bom, child: Text(bom.name)),
              ],
              onChanged: (bom) {
                if (bom != null) {
                  setState(() => _bom = bom);
                }
              },
            ),
            SizedBox(height: spacing.md),
            Row(
              children: [
                Expanded(child: Text(l10n.productionBatchesLabel)),
                IconButton(
                  onPressed: _batches > 1
                      ? () => setState(() => _batches -= 1)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text(
                  '$_batches',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  onPressed: () => setState(() => _batches += 1),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.productionOutputPreview(
                '${_bom.outputQuantity * _batches}',
                outputName,
              ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.productionMaterialsPreviewTitle,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            for (final line in _bom.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        line.componentName.isEmpty
                            ? line.componentProductName
                            : line.componentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '× ${formatQuantity(line.quantity * _batches)} '
                      '${unitLabel(l10n, line.componentUnit)}',
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            OperationsJobDraft(
              workflowTemplate: widget.template.id,
              bom: _bom.id,
              batches: _batches,
            ),
          ),
          child: Text(l10n.intakeCreateButton),
        ),
      ],
    );
  }
}
