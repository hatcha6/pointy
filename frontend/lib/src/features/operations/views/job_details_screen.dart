import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/job_refusal.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/employee_repository.dart';
import '../../../data/repositories/operations_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/job_details_view_model.dart';
import 'jobs_screen.dart' show formatQuantity, unitLabel;
import '../../assets/views/assets_ui.dart';
import 'operations_ui.dart';
import 'variant_picker_sheet.dart';

class JobDetailsScreen extends StatefulWidget {
  const JobDetailsScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.currentUser,
    required this.catalogRepository,
    required this.operationsRepository,
    required this.employeeRepository,
  });

  final JobDetailsViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final PosUser currentUser;
  final CatalogRepository catalogRepository;
  final OperationsRepository operationsRepository;
  final EmployeeRepository employeeRepository;

  @override
  State<JobDetailsScreen> createState() => _JobDetailsScreenState();
}

class _JobDetailsScreenState extends State<JobDetailsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.loadJob());
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
        final job = viewModel.job;
        final menuItems = job == null
            ? const <PopupMenuEntry<String>>[]
            : _menuItems(l10n, job);

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(job?.jobNumber ?? l10n.jobDetailsTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              // Every entry is conditional, so a completed or cancelled job
              // seen by someone without reopen permission leaves the menu
              // empty — and a PopupMenuButton with no items looks enabled but
              // does nothing when tapped. Hide it instead, like the invoice
              // and purchase order row menus do.
              if (job != null && menuItems.isNotEmpty)
                PopupMenuButton<String>(
                  enabled: !viewModel.isMutating,
                  tooltip: l10n.moreActionsTooltip,
                  onSelected: (action) => _onMenuAction(action, job),
                  itemBuilder: (menuContext) => menuItems,
                ),
            ],
          ),
          body: job == null
              ? (viewModel.hasLoadError
                    ? PointyErrorState(
                        title: l10n.jobsLoadError,
                        icon: Icons.handyman_outlined,
                        action: FilledButton.icon(
                          onPressed: viewModel.loadJob,
                          icon: const Icon(Icons.sync),
                          label: Text(l10n.retryButton),
                        ),
                      )
                    : const PointyLoadingArea())
              : _JobDetailsBody(
                  job: job,
                  viewModel: viewModel,
                  capabilities: widget.capabilities,
                  currentUser: widget.currentUser,
                  catalogRepository: widget.catalogRepository,
                  operationsRepository: widget.operationsRepository,
                  employeeRepository: widget.employeeRepository,
                ),
        );
      },
    );
  }

  /// The overflow-menu entries available for [job]. May be empty, in which
  /// case the caller must not render the menu button at all.
  List<PopupMenuEntry<String>> _menuItems(
    AppLocalizations l10n,
    OperationsJob job,
  ) {
    final isOpen = job.status == OperationsJobStatus.open;
    return [
      if (isOpen)
        PopupMenuItem(value: 'move', child: Text(l10n.jobMoveToStageAction)),
      if (isOpen && job.order == null)
        PopupMenuItem(value: 'cancel', child: Text(l10n.jobCancelAction)),
      if (!isOpen && widget.capabilities.canReopenJobs)
        PopupMenuItem(value: 'reopen', child: Text(l10n.jobReopenAction)),
    ];
  }

  Future<void> _onMenuAction(String action, OperationsJob job) async {
    switch (action) {
      case 'move':
        await _openMoveDialog(job);
      case 'cancel':
        await _confirmCancel(job);
      case 'reopen':
        await _reopen();
    }
  }

  Future<void> _openMoveDialog(OperationsJob job) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final templatesResult = await widget.operationsRepository
        .loadAllWorkflowTemplates();
    if (!mounted) {
      return;
    }
    final templates = switch (templatesResult) {
      Ok<List<WorkflowTemplate>>(value: final value) => value,
      Error<List<WorkflowTemplate>>() => const <WorkflowTemplate>[],
    };
    final template = templates
        .where((template) => template.id == job.workflowTemplate)
        .firstOrNull;
    if (template == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
      return;
    }

    final stage = await showAdaptiveModalBottomSheet<WorkflowStage>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    l10n.jobMoveToStageAction,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.jobManagerOnlyMoveHint,
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            for (final stage in template.stages)
              ListTile(
                leading: Icon(
                  stage.id == job.currentStage
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(stage.name),
                enabled: stage.id != job.currentStage,
                onTap: () => Navigator.of(sheetContext).pop(stage),
              ),
          ],
        ),
      ),
    );
    if (stage == null || !mounted) {
      return;
    }
    final moved = await widget.viewModel.transition(stage.id);
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          moved
              ? l10n.jobStageChangedMessage(stage.name)
              : l10n.operationsActionError,
        ),
      ),
    );
  }

  Future<void> _confirmCancel(OperationsJob job) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_outlined,
          color: dialogContext.pointyColors.danger,
        ),
        title: Text(l10n.jobCancelConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.jobCancelConfirmMessage),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              decoration: InputDecoration(labelText: l10n.jobCancelReasonLabel),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.pointyColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.jobCancelAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      reasonController.dispose();
      return;
    }
    final cancelled = await widget.viewModel.cancel(
      reason: reasonController.text.trim(),
    );
    reasonController.dispose();
    if (!cancelled && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _reopen() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final reopened = await widget.viewModel.reopen();
    if (!reopened && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }
}

class _JobDetailsBody extends StatefulWidget {
  const _JobDetailsBody({
    required this.job,
    required this.viewModel,
    required this.capabilities,
    required this.currentUser,
    required this.catalogRepository,
    required this.operationsRepository,
    required this.employeeRepository,
  });

  final OperationsJob job;
  final JobDetailsViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final PosUser currentUser;
  final CatalogRepository catalogRepository;
  final OperationsRepository operationsRepository;
  final EmployeeRepository employeeRepository;

  @override
  State<_JobDetailsBody> createState() => _JobDetailsBodyState();
}

class _JobDetailsBodyState extends State<_JobDetailsBody> {
  late final TextEditingController _symptomsController;
  late final TextEditingController _diagnosisController;
  late final TextEditingController _notesController;
  late final TextEditingController _quotedPriceController;
  late final TextEditingController _approvedPriceController;
  late final TextEditingController _warrantyDaysController;

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    _symptomsController = TextEditingController(text: job.symptoms);
    _diagnosisController = TextEditingController(text: job.diagnosis);
    _notesController = TextEditingController(text: job.technicianNotes);
    _quotedPriceController = TextEditingController(
      text: job.quotedPrice == null ? '' : job.quotedPrice!.toStringAsFixed(2),
    );
    _approvedPriceController = TextEditingController(
      text: job.approvedPrice == null
          ? ''
          : job.approvedPrice!.toStringAsFixed(2),
    );
    _warrantyDaysController = TextEditingController(
      text: '${job.warrantyDays}',
    );
  }

  @override
  void dispose() {
    _symptomsController.dispose();
    _diagnosisController.dispose();
    _notesController.dispose();
    _quotedPriceController.dispose();
    _approvedPriceController.dispose();
    _warrantyDaysController.dispose();
    super.dispose();
  }

  bool get _isEditable =>
      widget.job.status == OperationsJobStatus.open &&
      !widget.viewModel.isMutating;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final job = widget.job;
    final needsApproval =
        (job.currentStageDetails?.requiresCustomerApproval ?? false) &&
        job.approvedPrice == null;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: spacing.pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _headerCard(context),
                    SizedBox(height: spacing.md),
                    if (needsApproval)
                      Padding(
                        padding: EdgeInsets.only(bottom: spacing.md),
                        child: PointyInlineMessage.warning(
                          message: l10n.jobApprovalRequiredHint,
                          icon: Icons.price_check_outlined,
                        ),
                      ),
                    if (job.isOnHold)
                      Padding(
                        padding: EdgeInsets.only(bottom: spacing.md),
                        child: PointyInlineMessage.warning(
                          message: job.holdReason,
                          icon: Icons.pause_circle_outline,
                        ),
                      ),
                    // A repair the shop has been paid for but still holds is
                    // the state a counter most needs called out: the money is
                    // done, the phone is not.
                    if (job.settlementState.isSettled &&
                        job.custodyState == JobCustodyState.withShop &&
                        job.status == OperationsJobStatus.open)
                      Padding(
                        padding: EdgeInsets.only(bottom: spacing.md),
                        child: PointyInlineMessage.success(
                          message: l10n.jobAwaitingCollectionHint,
                          icon: Icons.inventory_2_outlined,
                        ),
                      ),
                    _timelineSection(context),
                    SizedBox(height: spacing.lg),
                    _customerSection(context),
                    SizedBox(height: spacing.lg),
                    _assignmentSection(context),
                    SizedBox(height: spacing.lg),
                    if (job.jobType == OperationsJobType.production) ...[
                      _productionSection(context),
                      SizedBox(height: spacing.lg),
                    ],
                    _materialsSection(context),
                    SizedBox(height: spacing.lg),
                    if (job.jobType != OperationsJobType.production) ...[
                      _servicesSection(context),
                      SizedBox(height: spacing.lg),
                    ],
                    _editSection(context),
                    SizedBox(height: spacing.xl),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (job.status == OperationsJobStatus.open && job.nextStage != null)
          PointyStickyActionFooter(
            primaryAction: FilledButton.icon(
              onPressed: widget.viewModel.isMutating ? null : _advance,
              icon: Icon(
                job.nextStageReleasesCustody
                    ? Icons.how_to_reg_outlined
                    : Icons.arrow_forward,
              ),
              label: Text(
                job.nextStageReleasesCustody
                    ? l10n.jobHandoverButton
                    : l10n.jobNextActionButton(job.nextStage!.name),
              ),
            ),
            secondaryActions: [
              if (_canInvoice(job))
                FilledButton.tonalIcon(
                  onPressed: widget.viewModel.isMutating
                      ? null
                      : () => _openInvoiceDialog(job),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(l10n.jobInvoiceButton),
                ),
              if (job.isOnHold)
                OutlinedButton.icon(
                  onPressed: widget.viewModel.isMutating ? null : _resume,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: Text(l10n.jobResumeButton),
                )
              else
                OutlinedButton.icon(
                  onPressed: widget.viewModel.isMutating
                      ? null
                      : _openHoldDialog,
                  icon: const Icon(Icons.pause_outlined),
                  label: Text(l10n.jobHoldButton),
                ),
            ],
          )
        else if (_canInvoice(job))
          PointyStickyActionFooter(
            primaryAction: FilledButton.icon(
              onPressed: widget.viewModel.isMutating
                  ? null
                  : () => _openInvoiceDialog(job),
              icon: const Icon(Icons.receipt_long_outlined),
              label: Text(l10n.jobInvoiceButton),
            ),
          ),
      ],
    );
  }

  bool _canInvoice(OperationsJob job) {
    return job.order == null &&
        job.status != OperationsJobStatus.cancelled &&
        job.jobType != OperationsJobType.production &&
        widget.capabilities.canCheckoutSale;
  }

  Widget _headerCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final job = widget.job;
    final statusVisual = JobStatusVisual.of(context, job.status);
    final overdue =
        job.isOpen && job.dueAt != null && job.dueAt!.isBefore(DateTime.now());

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OperationsIconBadge(icon: jobTypeIcon(job.jobType), size: 52),
                SizedBox(width: spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.jobNumber,
                        style: PointyTypography.numeric(
                          textTheme.titleLarge ?? const TextStyle(),
                        ).copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        jobTypeLabel(l10n, job.jobType),
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: spacing.sm),
                PointyStatusPill(
                  label: statusVisual.label,
                  icon: statusVisual.icon,
                  color: statusVisual.color,
                ),
              ],
            ),
            if (job.priority != OperationsJobPriority.normal ||
                job.orderReceiptNumber.trim().isNotEmpty) ...[
              SizedBox(height: spacing.md),
              Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  if (job.priority != OperationsJobPriority.normal)
                    JobPriorityBadge(priority: job.priority),
                  if (job.orderReceiptNumber.trim().isNotEmpty)
                    PointyStatusPill(
                      label: l10n.jobInvoicedBadge(job.orderReceiptNumber),
                      icon: Icons.receipt_long_outlined,
                      color: colors.success,
                    ),
                ],
              ),
            ],
            SizedBox(height: spacing.md),
            if (job.createdAt != null)
              _MetaRow(
                icon: Icons.schedule_outlined,
                label: l10n.jobCreatedAtLabel,
                value: formatDateTime(job.createdAt!),
              ),
            if (job.dueAt != null) ...[
              const SizedBox(height: 4),
              _MetaRow(
                icon: Icons.event_outlined,
                label: l10n.jobDueAtLabel,
                value: formatDateTime(job.dueAt!),
                emphasizeColor: overdue ? colors.danger : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timelineSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final job = widget.job;

    return PointyDetailSection(
      title: l10n.jobTimelineTitle,
      icon: Icons.timeline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < job.stageEvents.length; i++)
            _TimelineEntry(
              event: job.stageEvents[i],
              isCurrent: job.stageEvents[i].toStage == job.currentStage,
              isLast: i == job.stageEvents.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _customerSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final job = widget.job;

    return PointyDetailSection(
      title: l10n.jobCustomerSection,
      icon: Icons.person_outline,
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const OperationsIconBadge(
              icon: Icons.person_outline,
              size: 40,
            ),
            title: Text(
              job.customerName.trim().isEmpty
                  ? l10n.jobNoCustomer
                  : job.customerName,
            ),
            subtitle: job.customerPhone.trim().isEmpty
                ? null
                : Text(job.customerPhone),
          ),
          for (final link in job.assets)
            if (link.assetDetails != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: OperationsIconBadge(
                  icon: assetIconForKey(link.assetDetails!.assetTypeIcon),
                  size: 40,
                ),
                title: Text(link.assetDetails!.displayName),
                subtitle: Text(
                  [
                    link.assetDetails!.assetTypeName,
                    if (link.assetDetails!.imei.isNotEmpty)
                      'IMEI ${link.assetDetails!.imei}',
                    if (link.assetDetails!.serialNumber.isNotEmpty)
                      link.assetDetails!.serialNumber,
                  ].join(' · '),
                ),
                trailing: const PointyDisclosureChevron(),
                onTap: () => _openAssetHistory(link.assetDetails!.id),
              ),
        ],
      ),
    );
  }

  Future<void> _openAssetHistory(int assetId) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await widget.operationsRepository.loadJobs(asset: assetId);
    if (!mounted) {
      return;
    }
    final jobs = switch (result) {
      Ok<OperationsJobPage>(value: final page) =>
        page.jobs
            .where((other) => other.id != widget.job.id)
            .toList(growable: false),
      Error<OperationsJobPage>() => const <OperationsJob>[],
    };
    await showAdaptiveModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.assetHistoryTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            if (jobs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.assetHistoryEmpty),
              )
            else
              for (final other in jobs.take(10))
                ListTile(
                  leading: Icon(jobTypeIcon(other.jobType)),
                  title: Text(other.jobNumber),
                  subtitle: Text(
                    [
                      if (other.symptoms.trim().isNotEmpty)
                        other.symptoms.trim(),
                      if (other.createdAt != null)
                        formatDateTime(other.createdAt!),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PointyStatusPill(
                    label: jobStatusLabel(
                      AppLocalizations.of(sheetContext)!,
                      other.status,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _productionSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final job = widget.job;

    return PointyDetailSection(
      title: l10n.productionOutputSection,
      icon: Icons.precision_manufacturing_outlined,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const OperationsIconBadge(
          icon: Icons.inventory_2_outlined,
          size: 40,
        ),
        title: Text(
          l10n.productionOutputPreview(
            '${job.outputQuantity ?? 0}',
            job.outputVariantName,
          ),
        ),
        trailing: job.outputReceivedAt != null
            ? PointyStatusPill(
                label: l10n.productionReceivedBadge,
                icon: Icons.check_circle_outline,
                color: colors.success,
              )
            : null,
      ),
    );
  }

  Widget _materialsSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final job = widget.job;
    final canAddMaterials =
        widget.capabilities.canManageJobMaterials &&
        job.status == OperationsJobStatus.open &&
        job.order == null;

    return PointyDetailSection(
      title: l10n.jobMaterialsSection,
      icon: Icons.widgets_outlined,
      trailing: canAddMaterials
          ? TextButton.icon(
              onPressed: widget.viewModel.isMutating ? null : _addMaterial,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.addMaterialButton),
            )
          : null,
      child: job.materials.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: spacing.sm),
              child: Text(
                l10n.jobMaterialsEmpty,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final material in job.materials)
                  _MaterialRow(
                    material: material,
                    canReverse: canAddMaterials && material.reversedAt == null,
                    isBusy: widget.viewModel.isMutating,
                    onReverse: () => _reverseMaterial(material),
                  ),
                Padding(
                  padding: EdgeInsets.only(top: spacing.sm),
                  child: Divider(height: 1, color: colors.line),
                ),
                SizedBox(height: spacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.jobMaterialsTotalShort,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                    Text(
                      formatMoney(job.materialsTotal),
                      style: PointyTypography.numeric(
                        textTheme.titleMedium ?? const TextStyle(),
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  /// Priced work: the diagnosis fee, the oil change, the screen swap.
  ///
  /// Sits beside materials rather than inside it because the two are different
  /// kinds of thing — a part leaves stock and can be put back, a service is
  /// simply done — and because the technician commission base treats them
  /// differently.
  Widget _servicesSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final job = widget.job;
    final canEdit =
        widget.capabilities.canManageJobMaterials &&
        job.status == OperationsJobStatus.open &&
        job.order == null;

    return PointyDetailSection(
      title: l10n.jobServicesSectionTitle,
      icon: Icons.handyman_outlined,
      trailing: canEdit
          ? TextButton.icon(
              onPressed: widget.viewModel.isMutating ? null : _addService,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.jobAddServiceButton),
            )
          : null,
      child: job.services.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: spacing.sm),
              child: Text(
                l10n.jobNoServicesMessage,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final service in job.services)
                  Padding(
                    padding: EdgeInsetsDirectional.only(bottom: spacing.xs),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                service.variantName.trim().isEmpty
                                    ? service.productName
                                    : '${service.productName} — '
                                          '${service.variantName}',
                                style: textTheme.bodyMedium,
                              ),
                              if (service.note.trim().isNotEmpty)
                                Text(
                                  service.note,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colors.mutedInk,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          formatMoney(service.lineTotal),
                          style: PointyTypography.numeric(
                            textTheme.bodyMedium ?? const TextStyle(),
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (canEdit)
                          IconButton(
                            tooltip: l10n.jobRemoveServiceTooltip,
                            onPressed: widget.viewModel.isMutating
                                ? null
                                : () => _removeService(service),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(top: spacing.xs),
                  child: Divider(height: 1, color: colors.line),
                ),
                SizedBox(height: spacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.jobServicesTotalLabel,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                    Text(
                      formatMoney(job.servicesTotal),
                      style: PointyTypography.numeric(
                        textTheme.titleMedium ?? const TextStyle(),
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _assignmentSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final job = widget.job;
    final assigned = job.assignedEmployeeName.trim();
    final canAssign =
        widget.capabilities.canAssignJobs &&
        job.status != OperationsJobStatus.cancelled;

    return PointyDetailSection(
      title: l10n.jobAssignmentSection,
      icon: Icons.engineering_outlined,
      trailing: canAssign
          ? TextButton.icon(
              onPressed: widget.viewModel.isMutating ? null : _openAssignDialog,
              icon: const Icon(Icons.person_add_alt_outlined, size: 18),
              label: Text(
                assigned.isEmpty
                    ? l10n.jobAssignButton
                    : l10n.jobReassignButton,
              ),
            )
          : null,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: OperationsIconBadge(
          icon: assigned.isEmpty
              ? Icons.person_off_outlined
              : Icons.badge_outlined,
          size: 40,
          color: assigned.isEmpty ? context.pointyColors.mutedInk : null,
        ),
        title: Text(assigned.isEmpty ? l10n.jobUnassigned : assigned),
        subtitle: Text(l10n.jobAssignedEmployeeHint),
      ),
    );
  }

  Future<void> _openAssignDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final employees = await _loadAssignableEmployees();
    if (!mounted) {
      return;
    }
    if (employees == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.jobAssignLoadError)));
      return;
    }
    final selection = await showDialog<_AssignSelection>(
      context: context,
      builder: (_) => _AssignEmployeeDialog(
        employees: employees,
        currentEmployeeId: widget.job.assignedEmployee,
      ),
    );
    if (selection == null || !mounted) {
      return;
    }
    final assigned = await widget.viewModel.assignEmployee(
      selection.employeeId,
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          assigned ? l10n.jobAssignedMessage : l10n.operationsActionError,
        ),
      ),
    );
  }

  Future<List<Employee>?> _loadAssignableEmployees() async {
    final employees = <Employee>[];
    var page = 1;
    var hasMore = true;
    while (hasMore) {
      final result = await widget.employeeRepository.loadEmployees(page: page);
      switch (result) {
        case Ok<EmployeePage>():
          employees.addAll(
            result.value.employees.where(
              (employee) => employee.status == EmployeeStatus.active,
            ),
          );
          hasMore = result.value.hasMore;
          page += 1;
        case Error<EmployeePage>():
          return null;
      }
    }
    return employees;
  }

  // Symptoms/diagnosis/warranty are repair-only; a customer quote/approval
  // applies to repairs and work orders, but not to kitchen or production jobs
  // whose price comes from the sale order. Only show what fits the job type.
  bool get _isRepair => widget.job.jobType == OperationsJobType.repair;
  bool get _hasQuotePricing =>
      _isRepair || widget.job.jobType == OperationsJobType.workOrder;

  Widget _editSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: l10n.jobDetailsTitle,
          leading: const Icon(Icons.edit_note_outlined),
        ),
        SizedBox(height: spacing.sm),
        if (_isRepair) ...[
          TextField(
            controller: _symptomsController,
            enabled: _isEditable,
            maxLines: 2,
            decoration: InputDecoration(labelText: l10n.jobSymptomsLabel),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _diagnosisController,
            enabled: _isEditable,
            maxLines: 2,
            decoration: InputDecoration(labelText: l10n.jobDiagnosisLabel),
          ),
          SizedBox(height: spacing.sm),
        ],
        TextField(
          controller: _notesController,
          enabled: _isEditable,
          maxLines: 2,
          decoration: InputDecoration(labelText: l10n.jobTechnicianNotesLabel),
        ),
        if (_hasQuotePricing) ...[
          SizedBox(height: spacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _quotedPriceController,
                  enabled: _isEditable,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.jobQuotedPriceLabel,
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: TextField(
                  controller: _approvedPriceController,
                  enabled: _isEditable,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.jobApprovedPriceLabel,
                  ),
                ),
              ),
              if (_isRepair) ...[
                SizedBox(width: spacing.sm),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _warrantyDaysController,
                    enabled: _isEditable,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.jobWarrantyDaysLabel,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        SizedBox(height: spacing.md),
        FilledButton.tonalIcon(
          onPressed: _isEditable ? _saveEdits : null,
          icon: const Icon(Icons.save_outlined),
          label: Text(l10n.jobSaveButton),
        ),
      ],
    );
  }

  Future<void> _advance() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final nextStage = widget.job.nextStage;
    if (nextStage == null) {
      return;
    }
    // Handing the customer's property back is its own act, with its own
    // question ("who is collecting it?"), so it gets a confirmation rather
    // than sharing the plain "next stage" button's silence.
    var collector = '';
    if (nextStage.releasesCustody) {
      final answer = await _askWhoIsCollecting();
      if (answer == null || !mounted) {
        return;
      }
      collector = answer;
    }

    final moved = await widget.viewModel.transition(
      nextStage.id,
      handedOverTo: collector,
    );
    if (!mounted) {
      return;
    }
    if (moved) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.jobStageChangedMessage(nextStage.name))),
      );
      return;
    }

    // The one refusal worth explaining rather than reporting: the job is not
    // settled. Offer the two ways out — invoice it now, or (for a manager)
    // release it anyway on the record.
    final refusal = widget.viewModel.lastRefusal;
    if (refusal?.kind == JobRefusalKind.settlementRequired) {
      await _handleUnsettledHandover(nextStage);
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.operationsActionError)));
  }

  Future<String?> _askWhoIsCollecting() async {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => _PromptDialog(
        title: l10n.jobHandoverDialogTitle,
        fieldLabel: l10n.jobHandoverCollectorLabel,
        fieldHint: l10n.jobHandoverCollectorHint,
        confirmLabel: l10n.jobHandoverConfirm,
        cancelLabel: l10n.cancelButton,
      ),
    );
  }

  Future<void> _handleUnsettledHandover(WorkflowStage nextStage) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final canOverride = widget.capabilities.canReleaseUnpaidJobs;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text(l10n.jobHandoverBlockedTitle),
        content: Text(l10n.jobHandoverBlockedMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          // The override is offered only to someone who actually holds the
          // permission: a button that always 400s teaches staff to distrust
          // every other button.
          if (canOverride)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('force'),
              child: Text(l10n.jobForceReleaseButton),
            ),
          if (_canInvoice(widget.job))
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('invoice'),
              child: Text(l10n.jobHandoverBlockedInvoiceAction),
            ),
        ],
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    if (action == 'invoice') {
      await _openInvoiceDialog(widget.job);
      return;
    }

    final note = await _askForceReleaseReason();
    if (note == null || !mounted) {
      return;
    }
    final released = await widget.viewModel.transition(
      nextStage.id,
      note: note,
      forceRelease: true,
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          released
              ? l10n.jobStageChangedMessage(nextStage.name)
              : l10n.operationsActionError,
        ),
      ),
    );
  }

  Future<String?> _askForceReleaseReason() async {
    final l10n = AppLocalizations.of(context)!;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PromptDialog(
        title: l10n.jobForceReleaseDialogTitle,
        explainer: l10n.jobForceReleaseExplainer,
        fieldLabel: l10n.jobForceReleaseNoteLabel,
        fieldHint: l10n.jobForceReleaseNoteHint,
        confirmLabel: l10n.jobForceReleaseButton,
        cancelLabel: l10n.cancelButton,
      ),
    );
    // The backend refuses a blank reason; catching it here keeps the manager
    // from watching a request fail for something the dialog could have said.
    return (reason ?? '').isEmpty ? null : reason;
  }

  Future<void> _saveEdits() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    // Persist only the fields the job type actually shows, so editing a kitchen
    // order never blanks out repair-only fields it doesn't display.
    final changes = <String, Object?>{
      'technician_notes': _notesController.text.trim(),
    };
    if (_isRepair) {
      changes['symptoms'] = _symptomsController.text.trim();
      changes['diagnosis'] = _diagnosisController.text.trim();
      changes['warranty_days'] =
          int.tryParse(_warrantyDaysController.text.trim()) ?? 0;
    }
    if (_hasQuotePricing) {
      final quoted = _quotedPriceController.text.trim();
      final approved = _approvedPriceController.text.trim();
      changes['quoted_price'] = quoted.isEmpty ? null : quoted;
      changes['approved_price'] = approved.isEmpty ? null : approved;
    }
    final saved = await widget.viewModel.saveJob(changes);
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.jobSavedMessage : l10n.operationsActionError,
        ),
      ),
    );
  }

  Future<void> _addMaterial() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: widget.catalogRepository,
      title: l10n.addMaterialButton,
    );
    if (variant == null || !mounted) {
      return;
    }
    final quantityController = TextEditingController(text: '1');
    final quantity = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(variant.displayLabel),
        content: TextField(
          controller: quantityController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l10n.materialQuantityLabel,
            suffixText: unitLabel(l10n, variant.unit),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(double.tryParse(quantityController.text.trim()) ?? 1),
            child: Text(l10n.addMaterialButton),
          ),
        ],
      ),
    );
    quantityController.dispose();
    if (quantity == null || quantity <= 0 || !mounted) {
      return;
    }
    final added = await widget.viewModel.addMaterial(
      variant: variant.id,
      quantity: quantity,
    );
    if (!added && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _reverseMaterial(JobMaterial material) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        title: l10n.reverseMaterialConfirmTitle,
        message: l10n.reverseMaterialConfirmMessage,
        confirmLabel: l10n.reverseMaterialAction,
        icon: Icons.settings_backup_restore,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final reversed = await widget.viewModel.reverseMaterial(material.id);
    if (!reversed && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _addService() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: widget.catalogRepository,
      title: l10n.jobServicePickerTitle,
      // Only service products: adding a screen as "labour" would bill it
      // without moving any stock, and the phone on the bench would still be
      // waiting for a part the system thinks was fitted.
      where: (variant) => variant.isService,
      emptyMessage: l10n.jobNoServiceProductsMessage,
    );
    if (variant == null || !mounted) {
      return;
    }
    final added = await widget.viewModel.addService(
      JobServiceDraft(variant: variant.id),
    );
    if (!added && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _removeService(JobServiceLine service) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final removed = await widget.viewModel.removeService(service.id);
    if (!removed && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _openHoldDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PromptDialog(
        title: l10n.jobHoldDialogTitle,
        explainer: l10n.jobHoldExplainer,
        fieldLabel: l10n.jobHoldReasonLabel,
        fieldHint: l10n.jobHoldReasonHint,
        confirmLabel: l10n.jobHoldButton,
        cancelLabel: l10n.cancelButton,
      ),
    );
    if (reason == null || reason.isEmpty || !mounted) {
      return;
    }
    final held = await widget.viewModel.hold(reason: reason);
    if (!held && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _resume() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final resumed = await widget.viewModel.resume();
    if (!resumed && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
    }
  }

  Future<void> _openInvoiceDialog(OperationsJob job) async {
    final l10n = AppLocalizations.of(context)!;
    // Parts and services are already priced on the job; the labour box is for
    // the one-off amount that has no catalog line behind it.
    final lineTotal = job.billableTotal;
    final laborController = TextEditingController(
      text: job.approvedPrice == null
          ? ''
          : (job.approvedPrice! - lineTotal)
                .clamp(0, double.infinity)
                .toStringAsFixed(2),
    );
    final paidNowController = TextEditingController();
    var method = PaymentMethod.cash;
    var onCredit = false;
    // Seeded once the cashier switches to آجل, so the common "pay it all now
    // anyway" case does not need retyping the total.
    var paidNowTouched = false;

    final draft = await showDialog<JobInvoiceDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final labor = double.tryParse(laborController.text.trim()) ?? 0;
          final total = lineTotal + labor;
          final paidNow = onCredit
              ? (double.tryParse(paidNowController.text.trim()) ?? 0)
              : total;
          final balance = (total - paidNow).clamp(0.0, double.infinity);
          final needsCustomer = onCredit && job.customer == null;
          final overpaid = paidNow > total;

          return AlertDialog(
            icon: const Icon(Icons.receipt_long_outlined),
            title: Text(l10n.jobInvoiceTitle),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.jobInvoiceExplainer,
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.jobMaterialsTotalLabel(
                        formatMoney(job.materialsTotal),
                      ),
                    ),
                    if (job.servicesTotal > 0)
                      Text(
                        '${l10n.jobInvoiceServicesLabel}: '
                        '${formatMoney(job.servicesTotal)}',
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: laborController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [DecimalTextInputFormatter()],
                      decoration: InputDecoration(
                        labelText: l10n.jobLaborTotalLabel,
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<PaymentMethod>(
                      segments: [
                        ButtonSegment(
                          value: PaymentMethod.cash,
                          label: Text(l10n.paymentMethodCash),
                        ),
                        ButtonSegment(
                          value: PaymentMethod.card,
                          label: Text(l10n.paymentMethodCard),
                        ),
                        ButtonSegment(
                          value: PaymentMethod.transfer,
                          label: Text(l10n.paymentMethodTransfer),
                        ),
                      ],
                      selected: {method},
                      onSelectionChanged: (selection) {
                        setDialogState(() => method = selection.first);
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: onCredit,
                      title: Text(l10n.jobInvoiceOnCreditLabel),
                      subtitle: Text(l10n.jobInvoiceOnCreditExplainer),
                      onChanged: (value) => setDialogState(() {
                        onCredit = value;
                        if (value && !paidNowTouched) {
                          paidNowController.text = total.toStringAsFixed(2);
                        }
                      }),
                    ),
                    if (onCredit) ...[
                      TextField(
                        controller: paidNowController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [DecimalTextInputFormatter()],
                        decoration: InputDecoration(
                          labelText: l10n.jobInvoiceAmountNowLabel,
                        ),
                        onChanged: (_) => setDialogState(() {
                          paidNowTouched = true;
                        }),
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.jobBalanceDueLabel(formatMoney(balance))),
                      if (needsCustomer)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: PointyInlineMessage.warning(
                            message: l10n.jobInvoiceNeedsCustomerForCredit,
                            icon: Icons.person_off_outlined,
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      l10n.jobInvoiceTotalLabel(formatMoney(total)),
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.jobInvoiceNeedsRegister,
                      style: Theme.of(dialogContext).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.cancelButton),
              ),
              FilledButton(
                onPressed: total <= 0 || needsCustomer || overpaid
                    ? null
                    : () => Navigator.of(dialogContext).pop(
                        JobInvoiceDraft(
                          laborTotal: labor,
                          onCredit: onCredit,
                          payments: [
                            if (paidNow > 0)
                              JobInvoicePayment(
                                method: method,
                                amount: paidNow,
                              ),
                          ],
                        ),
                      ),
                child: Text(l10n.jobInvoiceButton),
              ),
            ],
          );
        },
      ),
    );
    laborController.dispose();
    paidNowController.dispose();
    if (draft == null || !mounted) {
      return;
    }
    await _submitInvoice(draft);
  }

  Future<void> _submitInvoice(JobInvoiceDraft draft) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final invoiced = await widget.viewModel.invoice(draft);
    if (!mounted) {
      return;
    }
    if (invoiced != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.jobInvoiceSuccess(invoiced.orderReceiptNumber)),
        ),
      );
      return;
    }

    // Billing above what the customer agreed to is a real thing that happens —
    // the part turned out worse than the diagnosis said — so it is a question,
    // not a failure. Asking it here, with both numbers on screen, is the point
    // of the guard: someone has to have said yes.
    final refusal = widget.viewModel.lastRefusal;
    if (refusal?.kind == JobRefusalKind.overApprovedPrice) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.price_change_outlined),
          title: Text(l10n.jobOverQuoteTitle),
          content: Text(
            l10n.jobOverQuoteMessage(
              refusal!.approvedPrice,
              refusal.invoiceTotal,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.jobOverQuoteConfirm),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _submitInvoice(
          JobInvoiceDraft(
            laborTotal: draft.laborTotal,
            payments: draft.payments,
            onCredit: draft.onCredit,
            dueDate: draft.dueDate,
            acknowledgeOverQuote: true,
          ),
        );
      }
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.operationsActionError)));
  }
}

class _AssignSelection {
  const _AssignSelection(this.employeeId);

  final int? employeeId;
}

class _AssignEmployeeDialog extends StatelessWidget {
  const _AssignEmployeeDialog({
    required this.employees,
    required this.currentEmployeeId,
  });

  final List<Employee> employees;
  final int? currentEmployeeId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.engineering_outlined),
      title: Text(l10n.jobAssignSelectTitle),
      content: SizedBox(
        width: 420,
        child: employees.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.jobAssignNoEmployees),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (currentEmployeeId != null)
                      ListTile(
                        leading: const Icon(Icons.person_off_outlined),
                        title: Text(l10n.jobUnassignOption),
                        onTap: () => Navigator.of(
                          context,
                        ).pop(const _AssignSelection(null)),
                      ),
                    for (final employee in employees)
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(employee.fullName),
                        subtitle: employee.jobTitle.trim().isEmpty
                            ? null
                            : Text(employee.jobTitle),
                        selected: employee.id == currentEmployeeId,
                        trailing: employee.id == currentEmployeeId
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.of(
                          context,
                        ).pop(_AssignSelection(employee.id)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
      ],
    );
  }
}

/// A compact icon + label + value line for the header meta block.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasizeColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? emphasizeColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final valueColor = emphasizeColor ?? colors.ink;
    return Row(
      children: [
        Icon(icon, size: 16, color: emphasizeColor ?? colors.mutedInk),
        const SizedBox(width: 8),
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// One entry in the job's stage history, drawn as a vertical timeline node.
class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.event,
    required this.isCurrent,
    required this.isLast,
  });

  final JobStageEvent event;
  final bool isCurrent;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final dotColor = isCurrent ? PointyColors.primary : colors.success;
    final meta = [
      if (event.changedByName.trim().isNotEmpty) event.changedByName,
      if (event.createdAt != null) formatDateTime(event.createdAt!),
    ].join(' · ');

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: isCurrent
                      ? dotColor
                      : dotColor.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                  border: Border.all(color: dotColor, width: 2),
                ),
                child: isCurrent
                    ? null
                    : Icon(Icons.check, size: 10, color: dotColor),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: colors.line,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          event.toStageName,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        Text(
                          '· ${l10n.jobCurrentStageLabel}',
                          style: textTheme.labelSmall?.copyWith(
                            color: PointyColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  if (event.note.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        event.note,
                        style: textTheme.bodySmall?.copyWith(color: colors.ink),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One material line in the materials section: name, status, quantity + total.
class _MaterialRow extends StatelessWidget {
  const _MaterialRow({
    required this.material,
    required this.canReverse,
    required this.isBusy,
    required this.onReverse,
  });

  final JobMaterial material;
  final bool canReverse;
  final bool isBusy;
  final VoidCallback onReverse;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final name = material.variantName.trim().isEmpty
        ? material.productName
        : material.variantName;
    final (statusLabel, statusColor) = material.reversedAt != null
        ? (l10n.materialReversedBadge, colors.mutedInk)
        : material.isConsumed
        ? (l10n.materialConsumedBadge, colors.success)
        : (l10n.materialPendingBadge, colors.warning);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(width: spacing.sm),
                    PointyStatusPill(label: statusLabel, color: statusColor),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '× ${formatQuantity(material.quantity)} '
                  '${unitLabel(l10n, material.unit)} · '
                  '${formatMoney(material.lineTotal)}',
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
          if (canReverse)
            IconButton(
              tooltip: l10n.reverseMaterialAction,
              onPressed: isBusy ? null : onReverse,
              icon: const Icon(Icons.settings_backup_restore),
            ),
        ],
      ),
    );
  }
}

/// A one-field confirmation: a title, an optional explainer, a text box, and
/// two buttons. Pops the trimmed text on confirm, or null on cancel.
///
/// Owns its [TextEditingController] deliberately. Callers that create one and
/// dispose it after `showDialog` completes are disposing it while the route is
/// still animating out, and the next frame rebuilds the field against a dead
/// controller.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.fieldLabel,
    required this.confirmLabel,
    required this.cancelLabel,
    this.explainer,
    this.fieldHint,
  });

  final String title;
  final String? explainer;
  final String fieldLabel;
  final String? fieldHint;
  final String confirmLabel;
  final String cancelLabel;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.explainer != null) ...[
            Text(widget.explainer!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              hintText: widget.fieldHint,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
