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
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/jobs_board_view_model.dart';
import '../view_models/recipes_view_model.dart';
import 'job_intake_wizard.dart';
import 'operations_ui.dart';
import 'recipes_page.dart';

export '../../../shared/units.dart' show formatQuantity, unitLabel;
export 'operations_ui.dart'
    show jobPriorityLabel, jobStatusLabel, jobTypeIcon, jobTypeLabel;

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
          floatingActionButton:
              widget.capabilities.canCreateJobs &&
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

    if (viewModel.isLoading &&
        viewModel.jobs.isEmpty &&
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
          padding: EdgeInsets.fromLTRB(
            spacing.pageHorizontal,
            spacing.sm,
            spacing.pageHorizontal,
            0,
          ),
          child: AdaptiveMaxWidth(
            width: AppContentWidth.list,
            child: _FilterBar(
              searchController: _searchController,
              onSearchChanged: _onSearchChanged,
              viewModel: viewModel,
            ),
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
        action:
            widget.capabilities.canCreateJobs &&
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
      final jobs = viewModel.jobs;
      // Lazily build the filtered job list so a long backlog doesn't construct
      // every card up front.
      return ListView.builder(
        padding: spacing.pagePadding,
        itemCount: jobs.length,
        itemBuilder: (context, index) {
          final job = jobs[index];
          return AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Padding(
              padding: EdgeInsetsDirectional.only(bottom: spacing.sm),
              child: _JobCard(
                job: job,
                stagePosition: jobStagePosition(job, viewModel.templates),
                isBusy: _advancingJobIds.contains(job.id),
                onTap: () => widget.onOpenJob(job),
                onAdvance: null,
              ),
            ),
          );
        },
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
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final template in templates) ...[
                if (templates.length > 1)
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      top: spacing.sm,
                      bottom: spacing.xs,
                    ),
                    child: Row(
                      children: [
                        OperationsIconBadge(
                          icon: jobTypeIcon(template.jobType),
                          size: 32,
                        ),
                        SizedBox(width: spacing.sm),
                        Text(
                          template.name,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                ..._stageGroups(context, template),
                SizedBox(height: spacing.md),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _stageGroups(BuildContext context, WorkflowTemplate template) {
    final spacing = AdaptiveSpacing.of(context);
    final byStage = widget.viewModel.jobsByStage(template);
    final widgets = <Widget>[];
    for (final stage in template.stages) {
      final jobs = byStage[stage.id] ?? const [];
      // Hide empty stages: an active board should show work, not a wall of
      // zero-count headers.
      if (jobs.isEmpty) {
        continue;
      }
      widgets.add(_StageHeader(name: stage.name, count: jobs.length));
      widgets.add(SizedBox(height: spacing.sm));
      for (final job in jobs) {
        widgets.add(
          _JobCard(
            job: job,
            stagePosition: jobStagePosition(job, widget.viewModel.templates),
            isBusy: _advancingJobIds.contains(job.id),
            onTap: () => widget.onOpenJob(job),
            onAdvance: job.nextStage == null ? null : () => _advanceJob(job),
          ),
        );
        widgets.add(SizedBox(height: spacing.sm));
      }
      widgets.add(SizedBox(height: spacing.sm));
    }
    return widgets;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 4),
              child: Text(
                l10n.newJobButton,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            for (final template in templates)
              ListTile(
                leading: OperationsIconBadge(
                  icon: jobTypeIcon(template.jobType),
                  size: 40,
                ),
                title: Text(template.name),
                subtitle: Text(jobTypeLabel(l10n, template.jobType)),
                trailing: const PointyDisclosureChevron(),
                onTap: () => Navigator.of(sheetContext).pop(template),
              ),
            const SizedBox(height: 8),
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
      builder: (dialogContext) =>
          _ProductionBatchDialog(template: template, boms: boms),
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
        SegmentedButton<OperationsJobStatus?>(
          showSelectedIcon: false,
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
        SizedBox(height: spacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              FilterChip(
                avatar: const Icon(Icons.person_outline, size: 18),
                label: Text(l10n.jobFilterMine),
                selected: viewModel.assignedToMe,
                onSelected: (selected) {
                  viewModel.assignedToMe = selected;
                },
              ),
              if (types.length > 1)
                for (final type in types)
                  Padding(
                    padding: EdgeInsetsDirectional.only(start: spacing.xs),
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

class _StageHeader extends StatelessWidget {
  const _StageHeader({required this.name, required this.count});

  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surfaceSunken,
            borderRadius: BorderRadius.circular(PointyRadii.pill),
          ),
          child: Text(
            '$count',
            style: PointyTypography.numeric(
              textTheme.labelMedium ?? const TextStyle(),
            ).copyWith(color: colors.mutedInk, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.stagePosition,
    required this.isBusy,
    required this.onTap,
    required this.onAdvance,
  });

  final OperationsJob job;
  final ({int index, int total})? stagePosition;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback? onAdvance;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final position = stagePosition;
    final overdue =
        job.isOpen && job.dueAt != null && job.dueAt!.isBefore(DateTime.now());
    final subtitle = <String>[
      if (job.customerName.trim().isNotEmpty) job.customerName,
      if (job.outputVariantName.trim().isNotEmpty)
        '${job.outputQuantity ?? ''} × ${job.outputVariantName}'.trim()
      else if (job.symptoms.trim().isNotEmpty)
        job.symptoms,
      if (job.assignedEmployeeName.trim().isNotEmpty)
        '${l10n.jobAssignmentSection}: ${job.assignedEmployeeName}',
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OperationsIconBadge(icon: jobTypeIcon(job.jobType)),
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
                              if (job.priority != OperationsJobPriority.normal)
                                Padding(
                                  padding: EdgeInsetsDirectional.only(
                                    start: spacing.xs,
                                  ),
                                  child: JobPriorityBadge(
                                    priority: job.priority,
                                  ),
                                ),
                              if (!job.isOpen)
                                Padding(
                                  padding: EdgeInsetsDirectional.only(
                                    start: spacing.xs,
                                  ),
                                  child: _StatusPill(status: job.status),
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
                        ],
                      ),
                    ),
                    SizedBox(width: spacing.xs),
                    PointyDisclosureChevron(color: colors.mutedInk),
                  ],
                ),
                if (position != null && job.isOpen) ...[
                  SizedBox(height: spacing.md),
                  JobStageProgressBar(
                    currentIndex: position.index,
                    total: position.total,
                  ),
                ],
                if (overdue) ...[
                  SizedBox(height: spacing.sm),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: PointyStatusPill(
                      label: l10n.jobOverdueBadge,
                      icon: Icons.schedule_outlined,
                      color: colors.danger,
                    ),
                  ),
                ],
                if (onAdvance != null && job.nextStage != null) ...[
                  SizedBox(height: spacing.sm),
                  _AdvanceButton(
                    label: job.nextStage!.name,
                    isBusy: isBusy,
                    onPressed: onAdvance,
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final OperationsJobStatus status;

  @override
  Widget build(BuildContext context) {
    final visual = JobStatusVisual.of(context, status);
    return PointyStatusPill(
      label: visual.label,
      icon: visual.icon,
      color: visual.color,
    );
  }
}

class _AdvanceButton extends StatelessWidget {
  const _AdvanceButton({
    required this.label,
    required this.isBusy,
    required this.onPressed,
  });

  final String label;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return OutlinedButton(
      onPressed: isBusy ? null : onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isBusy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.arrow_forward, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.jobNextActionButton(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

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
              padding: EdgeInsets.all(spacing.sm),
              decoration: BoxDecoration(
                color: colors.surfaceSunken,
                borderRadius: BorderRadius.circular(PointyRadii.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.all(spacing.xs),
                    child: _StageHeader(
                      name: stage.name,
                      count: (jobsByStage[stage.id] ?? const []).length,
                    ),
                  ),
                  SizedBox(height: spacing.xs),
                  for (final job in jobsByStage[stage.id] ?? const []) ...[
                    _JobCard(
                      job: job,
                      stagePosition: jobStagePosition(job, [template]),
                      isBusy: advancingJobIds.contains(job.id),
                      onTap: () => onOpenJob(job),
                      onAdvance: job.nextStage == null
                          ? null
                          : () => onAdvance(job),
                    ),
                    SizedBox(height: spacing.sm),
                  ],
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
    final outputName = _bom.variantName.isEmpty
        ? _bom.productName
        : _bom.variantName;

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
