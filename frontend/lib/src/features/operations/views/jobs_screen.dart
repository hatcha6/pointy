import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/bill_of_materials.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/operations_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/units.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/job_print_actions.dart';
import '../view_models/jobs_board_view_model.dart';
import '../view_models/recipes_view_model.dart';
import 'job_awaiting_hand_back_strip.dart';
import 'job_intake_wizard.dart';
import 'job_stage_move.dart';
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
    required this.onOpenHistory,
    this.shopSettingsRepository,
    this.printActions,
  });

  final JobsBoardViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final PosUser currentUser;
  final ContactRepository contactRepository;
  final OperationsRepository operationsRepository;
  final CatalogRepository catalogRepository;
  final RecipesViewModel recipesViewModel;

  /// Handed to the intake wizard so it can open on the kind of item this shop
  /// works on. Optional: the preview harness and tests do without it.
  final ShopSettingsRepository? shopSettingsRepository;
  final ValueChanged<OperationsJob> onOpenJob;

  /// Opens the finished-work list. The board deliberately cannot show it: what
  /// is done is history, and history is a different screen.
  final VoidCallback onOpenHistory;

  /// Handed to the intake wizard, which prints the customer's receipt and the
  /// device sticker for a new repair. Optional, like the settings repository.
  final JobPrintActions? printActions;

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
              IconButton(
                tooltip: l10n.jobsHistoryTooltip,
                onPressed: widget.onOpenHistory,
                icon: const Icon(Icons.history),
              ),
              // Recipes are how a kitchen or a production line knows what
              // goes into what; a repair shop has neither.
              if (widget.capabilities.canManageRecipes && viewModel.usesRecipes)
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FilterBar(
                  searchController: _searchController,
                  onSearchChanged: _onSearchChanged,
                  viewModel: viewModel,
                ),
                if (viewModel.awaitingHandBack.isNotEmpty) ...[
                  SizedBox(height: spacing.sm),
                  JobAwaitingHandBackStrip(
                    jobs: viewModel.awaitingHandBack,
                    onOpenJob: widget.onOpenJob,
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(child: _buildJobsArea(context, l10n)),
      ],
    );
  }

  Widget _buildJobsArea(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final lanes = viewModel.enabledTemplates;

    // The shop runs no kind of work at all — its type has none, or every
    // switch is off. Say where they are switched on, rather than showing an
    // empty board with no way to start a job.
    if (lanes.isEmpty && !viewModel.isLoading) {
      return PointyEmptyState(
        icon: Icons.handyman_outlined,
        title: l10n.jobsNoWorkTypesTitle,
        message: l10n.jobsNoWorkTypesMessage,
      );
    }

    if (viewModel.jobs.isEmpty && !viewModel.isLoading) {
      // The board is filtered several ways, so a blank result is far more often
      // the technician's own search or filter than a shop with no work at all.
      // `QueryEmptyState` names whichever is hiding the job and offers the one
      // tap that brings it back; the "new job" invitation is reserved for the
      // genuinely-empty board, where creating one is the only way forward.
      return QueryEmptyState(
        icon: Icons.handyman_outlined,
        search: viewModel.searchQuery,
        hasFilters: viewModel.hasActiveFilters,
        emptyTitle: l10n.jobsEmptyTitle,
        emptyMessage: l10n.jobsEmptyMessage,
        onClear: _clearFilters,
        emptyAction: widget.capabilities.canCreateJobs && lanes.isNotEmpty
            ? FilledButton.icon(
                onPressed: _openNewJobMenu,
                icon: const Icon(Icons.add),
                label: Text(l10n.newJobButton),
              )
            : null,
      );
    }
    if (lanes.isEmpty) {
      return const SizedBox.shrink();
    }

    // One board, at every width. A kanban read across a workshop wall and a
    // kanban scrolled sideways on a phone are the same mental model — columns
    // are the work, and moving right is progress — so the layout does not
    // change shape underneath someone who learned it on the other device.
    if (lanes.length == 1) {
      return _KanbanBoard(
        template: lanes.single,
        jobsByStage: viewModel.jobsByStage(lanes.single),
        advancingJobIds: _advancingJobIds,
        onOpenJob: widget.onOpenJob,
        onMove: widget.capabilities.canChangeJobs ? _moveJob : null,
      );
    }
    // A shop that runs more than one kind of work sees every lane, stacked,
    // each a full board of its own — nothing hidden behind a switcher.
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = AdaptiveSpacing.of(context);
        final laneHeight = (constraints.maxHeight * 0.8).clamp(360.0, 720.0);
        return ListView(
          padding: EdgeInsets.symmetric(vertical: spacing.sm),
          children: [
            for (final lane in lanes) ...[
              _LaneHeader(template: lane, count: _jobCountIn(lane)),
              // A lane with nothing in it is one line, not a board's worth of
              // empty columns pushing the busy lane off the screen.
              if (_jobCountIn(lane) == 0)
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    spacing.pageHorizontal,
                    spacing.xs,
                    spacing.pageHorizontal,
                    spacing.sm,
                  ),
                  child: Text(
                    l10n.jobsLaneEmptyMessage,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.pointyColors.mutedInk,
                    ),
                  ),
                )
              else
                SizedBox(
                  height: laneHeight,
                  child: _KanbanBoard(
                    template: lane,
                    jobsByStage: viewModel.jobsByStage(lane),
                    advancingJobIds: _advancingJobIds,
                    onOpenJob: widget.onOpenJob,
                    onMove: widget.capabilities.canChangeJobs ? _moveJob : null,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  int _jobCountIn(WorkflowTemplate lane) => widget.viewModel.jobs
      .where((job) => job.workflowTemplate == lane.id)
      .length;

  Future<void> _openRecipes() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipesPage(
          capabilities: widget.capabilities,
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

  void _clearFilters() {
    // The search box holds its own controller rather than reading back from the
    // view model, so clearing the query there would leave the cleared term
    // still visible — and the pending debounce would then re-apply it.
    _searchDebounce?.cancel();
    _searchController.clear();
    widget.viewModel.clearFilters();
  }

  /// Moves [job] to [target] — the next stage from the card's button, or any
  /// stage from its "move to" sheet.
  Future<void> _moveJob(
    OperationsJob job,
    WorkflowTemplate template,
    WorkflowStage target,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await runJobStageMove(
      context,
      job: job,
      stages: template.stages,
      target: target,
      recordApprovedPrice: (price) =>
          widget.viewModel.recordApprovedPrice(job, price),
      // The card spins only while the server is being asked — not while the
      // counter is still answering a question about it.
      moveTo: (stage, collector) async {
        setState(() => _advancingJobIds.add(job.id));
        try {
          return await widget.viewModel.moveJob(
            job,
            stage,
            handedOverTo: collector,
          );
        } finally {
          if (mounted) {
            setState(() => _advancingJobIds.remove(job.id));
          }
        }
      },
    );
    if (!mounted) {
      return;
    }
    switch (outcome.result) {
      case JobMoveResult.moved:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.jobStageChangedMessage(target.name))),
        );
      case JobMoveResult.unsettled:
        await _explainUnsettledHandover(job);
      case JobMoveResult.failed:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.operationsActionError)),
        );
      case JobMoveResult.cancelled:
        break;
    }
  }

  /// The board cannot take the money; the job screen can. So a handover the
  /// server refused for want of payment is explained here, with the way on.
  Future<void> _explainUnsettledHandover(OperationsJob job) async {
    final l10n = AppLocalizations.of(context)!;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text(l10n.jobHandoverBlockedTitle),
        content: Text(l10n.jobHandoverBlockedMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.jobOpenAction),
          ),
        ],
      ),
    );
    if (open == true && mounted) {
      widget.onOpenJob(job);
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
              canCreateCustomers: widget.capabilities.canCreateCustomers,
              boardViewModel: widget.viewModel,
              contactRepository: widget.contactRepository,
              operationsRepository: widget.operationsRepository,
              shopSettingsRepository: widget.shopSettingsRepository,
              printActions: widget.printActions,
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
    final recipes = await widget.viewModel.loadActiveRecipes();
    if (!mounted) {
      return;
    }
    if (recipes == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.productionRecipesLoadError)),
      );
      return;
    }
    final boms = recipes.where((bom) => bom.isActive).toList(growable: false);
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

    // No lane or job-type chips: the board shows the kinds of work the shop
    // runs, all of them, and a phone shop runs one.
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
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilterChip(
            avatar: const Icon(Icons.person_outline, size: 18),
            label: Text(l10n.jobFilterMine),
            selected: viewModel.assignedToMe,
            onSelected: (selected) {
              viewModel.assignedToMe = selected;
            },
          ),
        ),
      ],
    );
  }
}

/// The title of one lane when a shop runs more than one kind of work.
class _LaneHeader extends StatelessWidget {
  const _LaneHeader({required this.template, required this.count});

  final WorkflowTemplate template;
  final int count;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.pageHorizontal,
        spacing.md,
        spacing.pageHorizontal,
        0,
      ),
      child: Row(
        children: [
          OperationsIconBadge(icon: jobTypeIcon(template.jobType), size: 32),
          SizedBox(width: spacing.sm),
          Expanded(
            child: _StageHeader(name: template.name, count: count),
          ),
        ],
      ),
    );
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
    required this.onChooseStage,
  });

  final OperationsJob job;
  final ({int index, int total})? stagePosition;
  final bool isBusy;
  final VoidCallback onTap;

  /// The everyday move: on to the next stage. Null for someone who can only
  /// look at the board.
  final VoidCallback? onAdvance;

  /// Any other stage — ahead past work already done, or back to the bench.
  final VoidCallback? onChooseStage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final position = stagePosition;
    final overdue =
        job.isOpen && job.dueAt != null && job.dueAt!.isBefore(DateTime.now());
    final awaitingCollection =
        job.isOpen &&
        job.settlementState.isSettled &&
        job.custodyState == JobCustodyState.withShop;
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
                // The three things worth reading across a workshop from the
                // other side of the room: it is late, it is stuck waiting on a
                // part, or it is paid and just sitting here waiting to be
                // collected.
                if (overdue || job.isOnHold || awaitingCollection) ...[
                  SizedBox(height: spacing.sm),
                  Wrap(
                    spacing: spacing.xs,
                    runSpacing: spacing.xs / 2,
                    children: [
                      if (overdue)
                        PointyStatusPill(
                          label: l10n.jobOverdueBadge,
                          icon: Icons.schedule_outlined,
                          color: colors.danger,
                        ),
                      if (job.isOnHold)
                        PointyStatusPill(
                          label: job.holdReason.trim().isEmpty
                              ? l10n.jobOnHoldBadge
                              : '${l10n.jobOnHoldBadge} · ${job.holdReason}',
                          icon: Icons.pause_circle_outline,
                          color: colors.warning,
                        ),
                      if (awaitingCollection)
                        PointyStatusPill(
                          label: l10n.jobSettlementSettled,
                          icon: Icons.inventory_2_outlined,
                          color: colors.success,
                        ),
                    ],
                  ),
                ],
                if (onAdvance != null || onChooseStage != null) ...[
                  SizedBox(height: spacing.sm),
                  Row(
                    children: [
                      if (onAdvance != null && job.nextStage != null)
                        Expanded(
                          child: _AdvanceButton(
                            label: job.nextStageReleasesCustody
                                ? l10n.jobHandoverButton
                                : job.nextStage!.name,
                            isBusy: isBusy,
                            onPressed: onAdvance,
                          ),
                        )
                      else
                        const Spacer(),
                      if (onChooseStage != null) ...[
                        SizedBox(width: spacing.xs),
                        IconButton.outlined(
                          tooltip: l10n.jobMoveToStageAction,
                          onPressed: isBusy ? null : onChooseStage,
                          icon: const Icon(Icons.swap_horiz),
                        ),
                      ],
                    ],
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
              child: PointySpinner(strokeWidth: 2),
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
    required this.onMove,
  });

  final WorkflowTemplate template;
  final Map<int, List<OperationsJob>> jobsByStage;
  final Set<int> advancingJobIds;
  final ValueChanged<OperationsJob> onOpenJob;

  /// Moves a job to a stage; null when this person cannot move jobs.
  final Future<void> Function(
    OperationsJob job,
    WorkflowTemplate template,
    WorkflowStage target,
  )?
  onMove;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final move = onMove;
    // On a workshop screen the columns sit side by side; on a phone one column
    // owns most of the width with a deliberate sliver of the next showing, so
    // it reads as a board that scrolls rather than a list that ends. A fixed
    // 320 on a 375pt phone leaves a stub too narrow to recognise as a column.
    final available = MediaQuery.sizeOf(context).width;
    final columnWidth = available < 480
        ? (available - spacing.pageHorizontal * 2) * 0.86
        : 320.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: spacing.pagePadding,
      // Every column is as tall as the board and scrolls on its own, so the
      // tenth phone waiting in "received" is a scroll away rather than drawn
      // off the bottom of the screen — and the board's sideways scrollbar
      // stays where the eye expects it.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final stage in template.stages)
            Container(
              width: columnWidth,
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
                  Expanded(
                    child: ListView(
                      children: [
                        for (final job
                            in jobsByStage[stage.id] ?? const <OperationsJob>[])
                          Padding(
                            padding: EdgeInsets.only(bottom: spacing.sm),
                            child: _JobCard(
                              job: job,
                              stagePosition: jobStagePosition(job, [template]),
                              isBusy: advancingJobIds.contains(job.id),
                              onTap: () => onOpenJob(job),
                              onAdvance: move == null || job.nextStage == null
                                  ? null
                                  : () => move(job, template, job.nextStage!),
                              onChooseStage: move == null
                                  ? null
                                  : () => _chooseStage(context, job, move),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _chooseStage(
    BuildContext context,
    OperationsJob job,
    Future<void> Function(
      OperationsJob job,
      WorkflowTemplate template,
      WorkflowStage target,
    )
    move,
  ) async {
    final target = await showJobStagePicker(
      context,
      stages: template.stages,
      currentStageId: job.currentStage,
    );
    if (target != null && context.mounted) {
      await move(job, template, target);
    }
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
                  tooltip: l10n.productionBatchesDecreaseTooltip,
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
                  tooltip: l10n.productionBatchesIncreaseTooltip,
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
