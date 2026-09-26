import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/models/workflow.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import 'asset_types_section.dart';
import '../../operations/view_models/asset_types_view_model.dart';
import '../../operations/view_models/workflows_view_model.dart';
import '../view_models/modifier_groups_view_model.dart';
import '../view_models/prep_stations_view_model.dart';
import '../view_models/shop_settings_view_model.dart';
import 'modifier_groups_page.dart';
import 'prep_stations_page.dart';
import 'repair_ticket_settings_section.dart';

/// The settings payload this page sends when one of its switches moves.
///
/// Built from the stored [settings] rather than from the switches, because a
/// draft is sent as the whole payload: every field this page does not show —
/// credit limits, the valuation method, the camera settings — would otherwise
/// go out as its default and be silently reset by a shop turning kitchen mode
/// on. Public so that property is a test, not a convention.
ShopSettingsDraft operationsSettingsDraft(
  ShopSettings settings, {
  bool? enableRepairOperations,
  bool? enableProductionOperations,
  bool? enableKitchenOperations,
  bool? enableJobTracking,
  bool? autoPrintKitchenTickets,
}) {
  return ShopSettingsDraft.fromSettings(settings).copyWith(
    enableRepairOperations: enableRepairOperations,
    enableProductionOperations: enableProductionOperations,
    enableKitchenOperations: enableKitchenOperations,
    enableJobTracking: enableJobTracking,
    autoPrintKitchenTickets: autoPrintKitchenTickets,
  );
}

class OperationsSettingsPage extends StatefulWidget {
  const OperationsSettingsPage({
    super.key,
    required this.shopSettingsViewModel,
    required this.workflowsViewModel,
    required this.assetTypesViewModel,
    required this.prepStationsViewModel,
    required this.modifierGroupsViewModel,
  });

  final ShopSettingsViewModel shopSettingsViewModel;
  final WorkflowsViewModel workflowsViewModel;
  final AssetTypesViewModel assetTypesViewModel;
  final PrepStationsViewModel prepStationsViewModel;
  final ModifierGroupsViewModel modifierGroupsViewModel;

  @override
  State<OperationsSettingsPage> createState() => _OperationsSettingsPageState();
}

class _OperationsSettingsPageState extends State<OperationsSettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.workflowsViewModel.loadTemplates());
      unawaited(widget.assetTypesViewModel.load());
      // Only to know whether the shop has menu options at all: the kitchen
      // block below is hidden from a shop that neither cooks nor uses them.
      unawaited(widget.modifierGroupsViewModel.load());
      if (widget.shopSettingsViewModel.settings == null) {
        unawaited(widget.shopSettingsViewModel.loadSettings());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.shopSettingsViewModel,
        widget.workflowsViewModel,
        widget.assetTypesViewModel,
        widget.modifierGroupsViewModel,
      ]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final settings = widget.shopSettingsViewModel.settings;
        final isBusy =
            widget.shopSettingsViewModel.isSaving ||
            widget.workflowsViewModel.isMutating ||
            widget.assetTypesViewModel.isMutating;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.operationsSettingsSectionTitle),
            isLoading:
                widget.shopSettingsViewModel.isLoading ||
                widget.workflowsViewModel.isLoading ||
                widget.assetTypesViewModel.isLoading ||
                isBusy,
          ),
          body: settings == null
              ? const PointyLoadingArea()
              : ListView(
                  padding: spacing.pagePadding,
                  children: [
                    AdaptiveMaxWidth(
                      width: AppContentWidth.form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PointySectionHeader(
                            title: l10n.operationsModesTitle,
                            subtitle: l10n.operationsModesHint,
                            leading: const Icon(Icons.handyman_outlined),
                          ),
                          SizedBox(height: spacing.sm),
                          PointySettingsSection(
                            children: [
                              _modeSwitch(
                                context,
                                title: l10n.enableRepairOperationsTitle,
                                description:
                                    l10n.enableRepairOperationsDescription,
                                icon: Icons.build_outlined,
                                value: settings.enableRepairOperations,
                                jobType: OperationsJobType.repair,
                                enabled: !isBusy,
                              ),
                              _modeSwitch(
                                context,
                                title: l10n.enableProductionOperationsTitle,
                                description:
                                    l10n.enableProductionOperationsDescription,
                                icon: Icons.precision_manufacturing_outlined,
                                value: settings.enableProductionOperations,
                                jobType: OperationsJobType.production,
                                enabled: !isBusy,
                              ),
                              _modeSwitch(
                                context,
                                title: l10n.enableKitchenOperationsTitle,
                                description:
                                    l10n.enableKitchenOperationsDescription,
                                icon: Icons.restaurant_outlined,
                                value: settings.enableKitchenOperations,
                                jobType: OperationsJobType.kitchen,
                                enabled: !isBusy,
                              ),
                              SwitchListTile(
                                secondary: const Icon(Icons.qr_code_2_outlined),
                                title: Text(l10n.enableJobTrackingTitle),
                                subtitle: Text(
                                  l10n.enableJobTrackingDescription,
                                ),
                                value: settings.enableJobTracking,
                                onChanged: isBusy
                                    ? null
                                    : (value) => _saveSettings(
                                        settings,
                                        enableJobTracking: value,
                                      ),
                              ),
                            ],
                          ),
                          // Shown only to a shop that repairs things: the fee
                          // and the conditions mean nothing to a kitchen.
                          if (settings.enableRepairOperations) ...[
                            SizedBox(height: spacing.lg),
                            RepairTicketSettingsSection(
                              settings: settings,
                              enabled: !isBusy,
                              onSave: _saveDraft,
                            ),
                          ],
                          // Kitchen chits, prep stations and menu options are a
                          // kitchen's; a phone shop never sees them. A shop that
                          // already prints chits, or already sells with menu
                          // options, keeps the way to change them.
                          if (settings.enableKitchenOperations ||
                              settings.autoPrintKitchenTickets ||
                              widget
                                  .modifierGroupsViewModel
                                  .groups
                                  .isNotEmpty) ...[
                            SizedBox(height: spacing.lg),
                            PointySectionHeader(
                              title: l10n.kitchenPrintingSectionTitle,
                              subtitle: l10n.kitchenPrintingSectionHint,
                              leading: const Icon(Icons.print_outlined),
                            ),
                            SizedBox(height: spacing.sm),
                            PointySettingsSection(
                              children: [
                                SwitchListTile(
                                  secondary: const Icon(
                                    Icons.receipt_long_outlined,
                                  ),
                                  title: Text(
                                    l10n.autoPrintKitchenTicketsTitle,
                                  ),
                                  subtitle: Text(
                                    l10n.autoPrintKitchenTicketsDescription,
                                  ),
                                  value: settings.autoPrintKitchenTickets,
                                  onChanged: isBusy
                                      ? null
                                      : (value) => _saveSettings(
                                          settings,
                                          autoPrintKitchenTickets: value,
                                        ),
                                ),
                                PointySettingsTile(
                                  icon: Icons.dinner_dining_outlined,
                                  title: l10n.prepStationsSectionTitle,
                                  subtitle: l10n.prepStationsSectionSubtitle,
                                  onTap: isBusy ? null : _openPrepStations,
                                ),
                                PointySettingsTile(
                                  icon: Icons.tune_outlined,
                                  title: l10n.modifierGroupsSectionTitle,
                                  subtitle: l10n.modifierGroupsSectionSubtitle,
                                  onTap: isBusy ? null : _openModifierGroups,
                                ),
                              ],
                            ),
                          ],
                          SizedBox(height: spacing.lg),
                          PointySectionHeader(
                            title: l10n.workflowsTitle,
                            subtitle: l10n.workflowStagesHint,
                            leading: const Icon(Icons.timeline_outlined),
                          ),
                          SizedBox(height: spacing.sm),
                          if (widget.workflowsViewModel.hasLoadError)
                            PointyInlineMessage.error(
                              message: l10n.workflowsLoadError,
                              icon: Icons.warning_amber_outlined,
                            )
                          else
                            PointySettingsSection(
                              children: [
                                for (final template
                                    in widget.workflowsViewModel.templates
                                        .where((template) => template.isActive))
                                  PointySettingsTile(
                                    icon: _jobTypeIcon(template.jobType),
                                    title: template.name,
                                    subtitle:
                                        '${_jobTypeLabel(l10n, template.jobType)}'
                                        ' · ${l10n.jobCountLabel(template.stages.length)}',
                                    onTap: isBusy
                                        ? null
                                        : () => _openStageEditor(template),
                                  ),
                              ],
                            ),
                          // What the shop works ON, beside how work moves. A
                          // television repairer and a car workshop run the same
                          // workflow engine and differ only here.
                          SizedBox(height: spacing.lg),
                          AssetTypesSection(
                            viewModel: widget.assetTypesViewModel,
                            canEdit: !isBusy,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _modeSwitch(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required bool value,
    required OperationsJobType jobType,
    required bool enabled,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(description),
      value: value,
      onChanged: enabled ? (next) => _toggleMode(jobType, next) : null,
    );
  }

  Future<void> _toggleMode(OperationsJobType jobType, bool enabled) async {
    final settings = widget.shopSettingsViewModel.settings;
    if (settings == null) {
      return;
    }
    final saved = await _saveSettings(
      settings,
      enableRepairOperations: jobType == OperationsJobType.repair
          ? enabled
          : null,
      enableProductionOperations: jobType == OperationsJobType.production
          ? enabled
          : null,
      enableKitchenOperations: jobType == OperationsJobType.kitchen
          ? enabled
          : null,
    );
    if (!saved || !mounted) {
      return;
    }
    // The server turns the matching built-in workflow on or off with the
    // switch — the setup wizard's preset goes through the same place — so the
    // jobs board offers exactly the kinds of work switched on here. Reload to
    // show what it did.
    await widget.workflowsViewModel.loadTemplates();
  }

  Future<bool> _saveSettings(
    ShopSettings settings, {
    bool? enableRepairOperations,
    bool? enableProductionOperations,
    bool? enableKitchenOperations,
    bool? enableJobTracking,
    bool? autoPrintKitchenTickets,
  }) async {
    final saved = await widget.shopSettingsViewModel.updateSettings(
      operationsSettingsDraft(
        settings,
        enableRepairOperations: enableRepairOperations,
        enableProductionOperations: enableProductionOperations,
        enableKitchenOperations: enableKitchenOperations,
        enableJobTracking: enableJobTracking,
        autoPrintKitchenTickets: autoPrintKitchenTickets,
      ),
    );
    if (!saved && mounted) {
      _showError();
    }
    return saved;
  }

  Future<bool> _saveDraft(ShopSettingsDraft draft) async {
    final saved = await widget.shopSettingsViewModel.updateSettings(draft);
    if (!saved && mounted) {
      _showError();
    }
    return saved;
  }

  void _openPrepStations() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PrepStationsPage(viewModel: widget.prepStationsViewModel),
      ),
    );
  }

  void _openModifierGroups() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ModifierGroupsPage(viewModel: widget.modifierGroupsViewModel),
      ),
    );
  }

  Future<void> _openStageEditor(WorkflowTemplate template) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WorkflowStageEditorPage(
          template: template,
          viewModel: widget.workflowsViewModel,
        ),
      ),
    );
  }

  void _showError() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.operationsActionError)));
  }
}

IconData _jobTypeIcon(OperationsJobType type) {
  return switch (type) {
    OperationsJobType.repair => Icons.build_outlined,
    OperationsJobType.production => Icons.precision_manufacturing_outlined,
    OperationsJobType.kitchen => Icons.restaurant_outlined,
    OperationsJobType.workOrder => Icons.assignment_outlined,
  };
}

String _jobTypeLabel(AppLocalizations l10n, OperationsJobType type) {
  return switch (type) {
    OperationsJobType.repair => l10n.jobTypeRepair,
    OperationsJobType.production => l10n.jobTypeProduction,
    OperationsJobType.kitchen => l10n.jobTypeKitchen,
    OperationsJobType.workOrder => l10n.jobTypeWorkOrder,
  };
}

class _EditableStage {
  _EditableStage({
    this.id,
    required this.code,
    required this.name,
    this.isInitial = false,
    this.isTerminal = false,
    this.requiresCustomerApproval = false,
    this.requiresSettlement = false,
    this.releasesCustody = false,
    this.consumesMaterials = false,
    this.producesOutput = false,
  });

  final int? id;
  final String code;
  String name;
  bool isInitial;
  bool isTerminal;
  bool requiresCustomerApproval;
  bool requiresSettlement;
  bool releasesCustody;
  bool consumesMaterials;
  bool producesOutput;
}

class _WorkflowStageEditorPage extends StatefulWidget {
  const _WorkflowStageEditorPage({
    required this.template,
    required this.viewModel,
  });

  final WorkflowTemplate template;
  final WorkflowsViewModel viewModel;

  @override
  State<_WorkflowStageEditorPage> createState() =>
      _WorkflowStageEditorPageState();
}

class _WorkflowStageEditorPageState extends State<_WorkflowStageEditorPage> {
  late List<_EditableStage> _stages;
  var _newStageCounter = 0;

  @override
  void initState() {
    super.initState();
    _stages = [
      for (final stage in widget.template.stages)
        _EditableStage(
          id: stage.id,
          code: stage.code,
          name: stage.name,
          isInitial: stage.isInitial,
          isTerminal: stage.isTerminal,
          requiresCustomerApproval: stage.requiresCustomerApproval,
          requiresSettlement: stage.requiresSettlement,
          releasesCustody: stage.releasesCustody,
          consumesMaterials: stage.consumesMaterials,
          producesOutput: stage.producesOutput,
        ),
    ];
  }

  bool get _isValid {
    final initialCount = _stages.where((stage) => stage.isInitial).length;
    final hasTerminal = _stages.any((stage) => stage.isTerminal);
    return _stages.isNotEmpty &&
        initialCount == 1 &&
        hasTerminal &&
        _stages.every((stage) => stage.name.trim().isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final isSaving = widget.viewModel.isMutating;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(widget.template.name),
            isLoading: isSaving,
          ),
          body: ListView(
            padding: spacing.pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.workflowStagesHint,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    SizedBox(height: spacing.md),
                    for (var index = 0; index < _stages.length; index++)
                      _StageEditorCard(
                        key: ValueKey(_stages[index].code),
                        stage: _stages[index],
                        position: index + 1,
                        enabled: !isSaving,
                        canMoveUp: index > 0,
                        canMoveDown: index < _stages.length - 1,
                        canDelete: _stages.length > 1,
                        onMoveUp: () => _move(index, index - 1),
                        onMoveDown: () => _move(index, index + 1),
                        onDelete: () => _delete(index),
                        onChanged: () => setState(() {}),
                      ),
                    SizedBox(height: spacing.sm),
                    OutlinedButton.icon(
                      onPressed: isSaving ? null : _addStage,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.workflowAddStageButton),
                    ),
                    SizedBox(height: spacing.lg),
                    FilledButton.icon(
                      onPressed: isSaving || !_isValid ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(l10n.workflowSaveButton),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _move(int from, int to) {
    setState(() {
      final stage = _stages.removeAt(from);
      _stages.insert(to, stage);
    });
  }

  void _delete(int index) {
    setState(() => _stages.removeAt(index));
  }

  void _addStage() {
    _newStageCounter += 1;
    setState(() {
      _stages.add(
        _EditableStage(
          code:
              'stage-${DateTime.now().millisecondsSinceEpoch}-$_newStageCounter',
          name: '',
        ),
      );
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.viewModel.save(
      WorkflowTemplateDraft(
        id: widget.template.id,
        name: widget.template.name,
        jobType: widget.template.jobType,
        isActive: widget.template.isActive,
        stages: [
          for (var index = 0; index < _stages.length; index++)
            WorkflowStageDraft(
              id: _stages[index].id,
              code: _stages[index].code,
              name: _stages[index].name.trim(),
              displayOrder: index,
              isInitial: _stages[index].isInitial,
              isTerminal: _stages[index].isTerminal,
              requiresCustomerApproval: _stages[index].requiresCustomerApproval,
              requiresSettlement: _stages[index].requiresSettlement,
              releasesCustody: _stages[index].releasesCustody,
              consumesMaterials: _stages[index].consumesMaterials,
              producesOutput: _stages[index].producesOutput,
            ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.workflowSavedMessage : l10n.operationsActionError,
        ),
      ),
    );
    if (saved) {
      Navigator.of(context).pop();
    }
  }
}

class _StageEditorCard extends StatefulWidget {
  const _StageEditorCard({
    super.key,
    required this.stage,
    required this.position,
    required this.enabled,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.canDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onChanged,
  });

  final _EditableStage stage;
  final int position;
  final bool enabled;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool canDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDelete;
  final VoidCallback onChanged;

  @override
  State<_StageEditorCard> createState() => _StageEditorCardState();
}

class _StageEditorCardState extends State<_StageEditorCard> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.stage.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Card(
      margin: EdgeInsets.only(bottom: spacing.sm),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.md,
          vertical: spacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 14, child: Text('${widget.position}')),
                SizedBox(width: spacing.sm),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    enabled: widget.enabled,
                    decoration: InputDecoration(
                      labelText: l10n.workflowStageNameLabel,
                    ),
                    onChanged: (value) {
                      widget.stage.name = value;
                      widget.onChanged();
                    },
                  ),
                ),
                IconButton(
                  tooltip: l10n.workflowStageMoveUpTooltip,
                  onPressed: widget.enabled && widget.canMoveUp
                      ? widget.onMoveUp
                      : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: l10n.workflowStageMoveDownTooltip,
                  onPressed: widget.enabled && widget.canMoveDown
                      ? widget.onMoveDown
                      : null,
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: l10n.workflowStageDeleteTooltip,
                  onPressed: widget.enabled && widget.canDelete
                      ? widget.onDelete
                      : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                l10n.jobCurrentStageLabel,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              children: [
                _flagSwitch(
                  l10n.workflowStageInitialLabel,
                  widget.stage.isInitial,
                  (value) => widget.stage.isInitial = value,
                ),
                _flagSwitch(
                  l10n.workflowStageTerminalLabel,
                  widget.stage.isTerminal,
                  (value) => widget.stage.isTerminal = value,
                ),
                _flagSwitch(
                  l10n.workflowStageApprovalLabel,
                  widget.stage.requiresCustomerApproval,
                  (value) => widget.stage.requiresCustomerApproval = value,
                ),
                // The two gates that decide whether a customer's property
                // can leave. Without them here, editing a workflow would
                // silently clear whatever the seeded template had set.
                _flagSwitch(
                  l10n.workflowStageSettlementLabel,
                  widget.stage.requiresSettlement,
                  (value) => widget.stage.requiresSettlement = value,
                  helpText: l10n.workflowStageSettlementHelp,
                ),
                _flagSwitch(
                  l10n.workflowStageCustodyLabel,
                  widget.stage.releasesCustody,
                  (value) => widget.stage.releasesCustody = value,
                  helpText: l10n.workflowStageCustodyHelp,
                ),
                _flagSwitch(
                  l10n.workflowStageConsumesLabel,
                  widget.stage.consumesMaterials,
                  (value) => widget.stage.consumesMaterials = value,
                ),
                _flagSwitch(
                  l10n.workflowStageProducesLabel,
                  widget.stage.producesOutput,
                  (value) => widget.stage.producesOutput = value,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _flagSwitch(
    String label,
    bool value,
    ValueChanged<bool> apply, {
    String? helpText,
  }) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: helpText == null ? null : Text(helpText),
      value: value,
      onChanged: widget.enabled
          ? (next) {
              setState(() => apply(next));
              widget.onChanged();
            }
          : null,
    );
  }
}
