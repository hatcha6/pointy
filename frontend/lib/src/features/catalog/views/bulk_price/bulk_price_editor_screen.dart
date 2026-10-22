import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../core/result.dart';
import '../../../../data/models/bulk_price_preview.dart';
import '../../../../data/models/bulk_price_rule.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/repositories/contact_repository.dart';
import '../../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/contact_picker_sheet.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/product_category_picker.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../view_models/bulk_price_editor_view_model.dart';
import 'bulk_price_condition_editor.dart';
import 'bulk_price_history_sheet.dart';
import 'bulk_price_labels.dart';
import 'bulk_price_preview_panel.dart';
import 'bulk_price_step_card.dart';

/// Opens the rule-driven bulk price editor. [selectedProducts] (from the
/// products list's multi-select) narrows it to those products to start with.
/// [onPricesChanged] runs after every apply or undo, so the list behind it
/// shows the new prices when the editor closes.
Future<void> openBulkPriceEditor(
  BuildContext context, {
  required CatalogRepository catalogRepository,
  ContactRepository? contactRepository,
  List<BulkPriceRef> selectedProducts = const [],
  VoidCallback? onPricesChanged,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => BulkPriceEditorScreen(
        catalogRepository: catalogRepository,
        contactRepository: contactRepository,
        selectedProducts: selectedProducts,
        onPricesChanged: onPricesChanged,
      ),
    ),
  );
}

class BulkPriceEditorScreen extends StatefulWidget {
  const BulkPriceEditorScreen({
    super.key,
    required this.catalogRepository,
    this.contactRepository,
    this.selectedProducts = const [],
    this.onPricesChanged,
    this.viewModel,
  });

  final CatalogRepository catalogRepository;
  final ContactRepository? contactRepository;
  final List<BulkPriceRef> selectedProducts;
  final VoidCallback? onPricesChanged;

  /// For previews and tests; otherwise the screen makes its own.
  final BulkPriceEditorViewModel? viewModel;

  @override
  State<BulkPriceEditorScreen> createState() => _BulkPriceEditorScreenState();
}

class _BulkPriceEditorScreenState extends State<BulkPriceEditorScreen> {
  late final BulkPriceEditorViewModel _viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    _viewModel =
        widget.viewModel ??
        BulkPriceEditorViewModel(
          catalogRepository: widget.catalogRepository,
          selectedProducts: widget.selectedProducts,
        );
    if (_ownsViewModel) _viewModel.load();
  }

  @override
  void dispose() {
    if (_ownsViewModel) _viewModel.dispose();
    super.dispose();
  }

  List<BulkPriceField> get _conditionFields => [
    for (final field in BulkPriceField.values)
      if (field.isPickable &&
          (!field.needsCost || _viewModel.costVisible) &&
          (field != BulkPriceField.supplier ||
              widget.contactRepository != null))
        field,
  ];

  Future<List<BulkPriceRef>?> _pickRefs(
    BuildContext context,
    BulkPriceField field,
    List<BulkPriceRef> current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    if (field == BulkPriceField.category) {
      final picked = await showAsyncMultiSelectPicker<int>(
        context: context,
        strings: productCategoryPickerStrings(l10n),
        selected: [
          for (final ref in current)
            AsyncSelectionOption(id: ref.id, label: ref.label, subtitle: ''),
        ],
        loadPage: (search, page) => loadProductCategorySelectionPage(
          catalogRepository: widget.catalogRepository,
          search: search,
          page: page,
        ),
      );
      if (picked == null) return null;
      return [
        for (final option in picked)
          BulkPriceRef(id: option.id, label: option.label),
      ];
    }
    final repository = widget.contactRepository;
    if (field == BulkPriceField.supplier && repository != null) {
      final supplier = await showSupplierPickerSheet(
        context: context,
        repository: repository,
      );
      if (supplier == null) return null;
      return [
        ...current.where((ref) => ref.id != supplier.id),
        BulkPriceRef(id: supplier.id, label: supplier.name),
      ];
    }
    return null;
  }

  Future<void> _apply() async {
    final l10n = AppLocalizations.of(context)!;
    final preview = _viewModel.preview;
    if (!_viewModel.canApply || preview == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ApplyConfirmDialog(summary: preview.summary),
    );
    if (confirmed != true || !mounted) return;
    final result = await _viewModel.apply();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case Ok(value: final record):
        widget.onPricesChanged?.call();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(l10n.bulkPriceAppliedMessage(record.changed)),
            action: SnackBarAction(
              label: l10n.bulkPriceUndoAction,
              onPressed: () => _undo(record.id),
            ),
          ),
        );
      case Error(exception: final error):
        final failure = error is BulkPriceException
            ? error.failure
            : BulkPriceFailure.other;
        messenger.showSnackBar(
          SnackBar(
            content: Text(switch (failure) {
              BulkPriceFailure.stale => l10n.bulkPriceStaleMessage,
              BulkPriceFailure.nothingToApply =>
                l10n.bulkPriceNothingToApplyMessage,
              _ => l10n.bulkPriceApplyFailed,
            }),
          ),
        );
    }
  }

  Future<void> _undo(int changeId) async {
    final done = await confirmAndRevertBulkPriceChange(
      context,
      catalogRepository: widget.catalogRepository,
      changeId: changeId,
    );
    if (done) {
      widget.onPricesChanged?.call();
      await _viewModel.refreshPreview();
    }
  }

  Future<void> _openHistory() async {
    final reverted = await showBulkPriceHistorySheet(
      context,
      catalogRepository: widget.catalogRepository,
    );
    if (reverted) {
      widget.onPricesChanged?.call();
      await _viewModel.refreshPreview();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyUnsavedChangesGuard(
      isDirty: () => _viewModel.isDirty,
      child: ListenableBuilder(
        listenable: _viewModel,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= AppBreakpoints.desktopMin;
              final rules = _RulesPane(
                viewModel: _viewModel,
                pickRefs: _pickRefs,
                conditionFields: _conditionFields,
              );
              final previewPane = Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: BulkPricePreviewPanel(viewModel: _viewModel),
              );
              final footer = _ApplyFooter(
                viewModel: _viewModel,
                onApply: _apply,
              );
              final historyAction = IconButton(
                key: const ValueKey('bulk_price_history_button'),
                tooltip: l10n.bulkPriceHistoryAction,
                icon: const Icon(Icons.history),
                onPressed: _openHistory,
              );

              if (wide) {
                return Scaffold(
                  appBar: AppBar(
                    title: Text(l10n.bulkPriceEditorTitle),
                    actions: [historyAction, const SizedBox(width: 8)],
                  ),
                  body: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 11, child: rules),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 9,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: previewPane),
                            footer,
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              final changed = _viewModel.isPreviewFresh
                  ? _viewModel.preview?.summary.changed
                  : null;
              return DefaultTabController(
                length: 2,
                child: Scaffold(
                  appBar: AppBar(
                    title: Text(l10n.bulkPriceEditorTitle),
                    actions: [historyAction],
                    bottom: TabBar(
                      tabs: [
                        Tab(text: l10n.bulkPriceRulesTab),
                        Tab(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(l10n.bulkPricePreviewTab),
                              if (changed != null) ...[
                                const SizedBox(width: 6),
                                Badge(label: Text('$changed')),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  body: TabBarView(children: [rules, previewPane]),
                  bottomNavigationBar: footer,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _RulesPane extends StatelessWidget {
  const _RulesPane({
    required this.viewModel,
    required this.pickRefs,
    required this.conditionFields,
  });

  final BulkPriceEditorViewModel viewModel;
  final BulkPriceRefPicker pickRefs;
  final List<BulkPriceField> conditionFields;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final spec = viewModel.spec;
    final summary = viewModel.isPreviewFresh
        ? viewModel.preview?.summary
        : null;
    final hint = theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        PointyDetailSection(
          title: l10n.bulkPriceScopeTitle,
          icon: Icons.filter_alt_outlined,
          trailing: summary == null
              ? null
              : PointyStatusPill(
                  label: l10n.bulkPriceMatchedCount(summary.matched),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SegmentedButton<bool>(
                  key: const ValueKey('bulk_price_scope'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.select_all),
                      label: Text(l10n.bulkPriceScopeAll),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.filter_list),
                      label: Text(l10n.bulkPriceScopeFiltered),
                    ),
                  ],
                  selected: {viewModel.scopeAll},
                  onSelectionChanged: (selection) =>
                      viewModel.setScopeAll(selection.first),
                ),
              ),
              const SizedBox(height: 10),
              if (viewModel.scopeAll)
                Text(l10n.bulkPriceScopeAllHint, style: hint)
              else
                BulkPriceGroupEditor(
                  group: spec.filter,
                  viewModel: viewModel,
                  pickRefs: pickRefs,
                  availableFields: conditionFields,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PointyDetailSection(
          title: l10n.bulkPriceStepsTitle,
          icon: Icons.linear_scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.bulkPriceStepsHint, style: hint),
              const SizedBox(height: 10),
              for (var index = 0; index < spec.steps.length; index++) ...[
                if (index > 0) const BulkPriceStepConnector(),
                BulkPriceStepCard(
                  key: ValueKey(spec.steps[index].key),
                  step: spec.steps[index],
                  index: index,
                  count: spec.steps.length,
                  viewModel: viewModel,
                  pickRefs: pickRefs,
                  conditionFields: conditionFields,
                ),
              ],
              const SizedBox(height: 10),
              _AddStepBar(viewModel: viewModel),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PointyDetailSection(
          title: l10n.bulkPriceSafeguardsTitle,
          icon: Icons.shield_outlined,
          child: Column(
            children: [
              if (viewModel.costVisible)
                SwitchListTile(
                  key: const ValueKey('bulk_price_never_below_cost'),
                  contentPadding: EdgeInsets.zero,
                  value: spec.neverBelowCost,
                  onChanged: viewModel.setNeverBelowCost,
                  title: Text(l10n.bulkPriceNeverBelowCost),
                  subtitle: Text(l10n.bulkPriceNeverBelowCostHint),
                ),
              SwitchListTile(
                key: const ValueKey('bulk_price_scale_packs'),
                contentPadding: EdgeInsets.zero,
                value: spec.packMode == BulkPricePackMode.scale,
                onChanged: (value) => viewModel.setPackMode(
                  value ? BulkPricePackMode.scale : BulkPricePackMode.keep,
                ),
                title: Text(l10n.bulkPriceScalePacks),
                subtitle: Text(l10n.bulkPriceScalePacksHint),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Add step" with every action grouped, plus one-tap presets for the
/// changes shops make most.
class _AddStepBar extends StatelessWidget {
  const _AddStepBar({required this.viewModel});

  final BulkPriceEditorViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = viewModel.canAddStep;
    final presets = <(String, BulkPriceAction, String)>[
      (l10n.bulkPricePresetIncrease10, BulkPriceAction.increasePercent, '10'),
      (l10n.bulkPricePresetDecrease10, BulkPriceAction.decreasePercent, '10'),
      if (viewModel.costVisible)
        (l10n.bulkPricePresetMarkup25, BulkPriceAction.costMarkup, '25'),
      (l10n.bulkPricePresetRound025, BulkPriceAction.round, '0.25'),
      (l10n.bulkPricePresetEnding, BulkPriceAction.ending, '0.99'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        MenuAnchor(
          builder: (context, controller, _) => FilledButton.tonalIcon(
            key: const ValueKey('bulk_price_add_step'),
            onPressed: enabled
                ? () =>
                      controller.isOpen ? controller.close() : controller.open()
                : null,
            icon: const Icon(Icons.add),
            label: Text(l10n.bulkPriceAddStep),
          ),
          menuChildren: [
            for (
              var group = 0;
              group < bulkPriceActionGroups.length;
              group++
            ) ...[
              if (group > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: Text(
                  bulkPriceActionGroupLabel(l10n, group),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.pointyColors.mutedInk,
                  ),
                ),
              ),
              for (final action in bulkPriceActionGroups[group])
                if (!action.needsCost || viewModel.costVisible)
                  MenuItemButton(
                    leadingIcon: Icon(bulkPriceActionIcon(action)),
                    onPressed: () => viewModel.addStep(action),
                    child: Text(l10n.actionLabel(action)),
                  ),
            ],
          ],
        ),
        Text(
          l10n.bulkPricePresetsTitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
        ),
        for (final (label, action, value) in presets)
          ActionChip(
            label: Text(label),
            onPressed: enabled
                ? () => viewModel.addStep(action, value: value)
                : null,
          ),
      ],
    );
  }
}

class _ApplyFooter extends StatelessWidget {
  const _ApplyFooter({required this.viewModel, required this.onApply});

  final BulkPriceEditorViewModel viewModel;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final preview = viewModel.preview;
    final fresh = viewModel.isPreviewFresh;
    final changed = fresh ? preview?.summary.changed ?? 0 : 0;

    final String label;
    if (!viewModel.isComplete) {
      label = l10n.bulkPriceApplyIncomplete;
    } else if (!fresh) {
      label = l10n.bulkPriceApplyWaiting;
    } else if (changed == 0) {
      label = l10n.bulkPriceApplyNothing;
    } else {
      label = l10n.bulkPriceApplyButton(changed);
    }

    return PointyStickyActionFooter(
      primaryAction: FilledButton.icon(
        key: const ValueKey('bulk_price_apply'),
        onPressed: viewModel.canApply ? onApply : null,
        icon: viewModel.isApplying
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.price_check),
        label: Text(label),
      ),
      summary: fresh && preview != null && preview.summary.warnings > 0
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: context.pointyColors.warning,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.bulkPriceConfirmWarnings(preview.summary.warnings),
                  ),
                ),
              ],
            )
          : null,
    );
  }
}

class _ApplyConfirmDialog extends StatelessWidget {
  const _ApplyConfirmDialog({required this.summary});

  final BulkPriceSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: Icon(Icons.price_change_outlined, color: colors.primaryStrong),
        title: Text(l10n.bulkPriceConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.bulkPriceConfirmBody(
                summary.changed,
                summary.increased,
                summary.decreased,
              ),
            ),
            if (summary.packsChanged > 0) ...[
              const SizedBox(height: 6),
              Text(l10n.bulkPriceConfirmPacks(summary.packsChanged)),
            ],
            if (summary.warnings > 0) ...[
              const SizedBox(height: 10),
              PointyInlineMessage.warning(
                message: l10n.bulkPriceConfirmWarnings(summary.warnings),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.bulkPriceConfirmUndo,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('bulk_price_confirm_apply'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.bulkPriceConfirmAction),
          ),
        ],
      ),
    );
  }
}
