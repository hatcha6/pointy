import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_of_measure.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import '../view_models/units_management_view_model.dart';

/// Full CRUD over the global unit-of-measure registry, grouped by dimension.
/// Built-in units can be relabelled or deactivated but never deleted, and their
/// code/dimension are locked; custom units are fully editable.
class UnitsManagementScreen extends StatefulWidget {
  const UnitsManagementScreen({super.key, required this.viewModel});

  final UnitsManagementViewModel viewModel;

  @override
  State<UnitsManagementScreen> createState() => _UnitsManagementScreenState();
}

class _UnitsManagementScreenState extends State<UnitsManagementScreen> {
  UnitsManagementViewModel get viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => viewModel.load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          appBar: PointyAppBar(
            leading: const BackButton(),
            title: Text(l10n.unitsManagementTitle),
            isLoading: viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.isMutating ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: viewModel.isMutating ? null : () => _openEditor(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addUnitButton),
          ),
          body: SafeArea(
            child: _UnitsBody(
              viewModel: viewModel,
              onCreate: () => _openEditor(context),
              onEdit: (unit) => _openEditor(context, unit: unit),
              onToggleActive: (unit) => _toggleActive(context, unit),
              onDelete: (unit) => _deleteUnit(context, unit),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEditor(BuildContext context, {UnitOfMeasure? unit}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showUnitEditorDialog(context, unit: unit);
    if (draft == null || !context.mounted) {
      return;
    }
    final saved = unit == null
        ? await viewModel.createUnit(draft)
        : await viewModel.updateUnit(unit.id, draft);
    if (!saved) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.unitSaveError)));
    }
  }

  Future<void> _toggleActive(BuildContext context, UnitOfMeasure unit) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await viewModel.updateUnit(
      unit.id,
      _draftFromUnit(unit, isActive: !unit.isActive),
    );
    if (!ok) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.unitSaveError)));
    }
  }

  Future<void> _deleteUnit(BuildContext context, UnitOfMeasure unit) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    // Built-in and in-use units are protected; explain why rather than failing.
    if (unit.isSystem) {
      await _showInfoDialog(
        context,
        icon: Icons.lock_outline,
        title: l10n.unitCannotDeleteSystemTitle,
        message: l10n.unitCannotDeleteSystemMessage,
      );
      return;
    }
    if (unit.isInUse) {
      await _showInfoDialog(
        context,
        icon: Icons.inventory_2_outlined,
        title: l10n.unitCannotDeleteInUseTitle,
        message: l10n.unitCannotDeleteInUseMessage(unit.productCount),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        icon: Icons.delete_outline,
        title: l10n.unitDeleteTitle,
        message: l10n.unitDeleteConfirm(unit.name),
        confirmLabel: l10n.deleteButton,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final ok = await viewModel.deleteUnit(unit);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(ok ? l10n.unitDeletedMessage : l10n.unitDeleteError),
        ),
      );
  }

  Future<void> _showInfoDialog(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(icon),
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
  }
}

UnitOfMeasureDraft _draftFromUnit(UnitOfMeasure unit, {bool? isActive}) {
  return UnitOfMeasureDraft(
    code: unit.code,
    name: unit.name,
    abbreviation: unit.abbreviation,
    dimension: unit.dimension,
    referenceFactor: unit.referenceFactor,
    allowsFractional: unit.allowsFractional,
    isActive: isActive ?? unit.isActive,
    displayOrder: unit.displayOrder,
    includeCode: !unit.isSystem,
  );
}

class _UnitsBody extends StatelessWidget {
  const _UnitsBody({
    required this.viewModel,
    required this.onCreate,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  final UnitsManagementViewModel viewModel;
  final VoidCallback onCreate;
  final ValueChanged<UnitOfMeasure> onEdit;
  final ValueChanged<UnitOfMeasure> onToggleActive;
  final ValueChanged<UnitOfMeasure> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.units.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.units.isEmpty) {
      return PointyErrorState(
        icon: Icons.error_outline,
        title: l10n.unitsLoadError,
        action: OutlinedButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (viewModel.units.isEmpty) {
      return PointyEmptyState(
        icon: Icons.straighten_outlined,
        title: l10n.unitsEmptyTitle,
        message: l10n.unitsEmptyMessage,
        action: FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: Text(l10n.addUnitButton),
        ),
      );
    }

    final grouped = viewModel.unitsByDimension;
    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointyDetailCallout(
                icon: Icons.straighten_outlined,
                title: l10n.unitsManagementIntroTitle,
                message: l10n.unitsManagementIntroMessage,
              ),
              SizedBox(height: spacing.lg),
              for (final entry in grouped.entries) ...[
                _UnitSection(
                  dimension: entry.key,
                  units: entry.value,
                  onEdit: onEdit,
                  onToggleActive: onToggleActive,
                  onDelete: onDelete,
                ),
                SizedBox(height: spacing.lg),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UnitSection extends StatelessWidget {
  const _UnitSection({
    required this.dimension,
    required this.units,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  final String dimension;
  final List<UnitOfMeasure> units;
  final ValueChanged<UnitOfMeasure> onEdit;
  final ValueChanged<UnitOfMeasure> onToggleActive;
  final ValueChanged<UnitOfMeasure> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: unitDimensionLabel(l10n, dimension),
          subtitle: l10n.unitsCountLabel(units.length),
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),
        PointySettingsSection(
          children: [
            for (final unit in units)
              _UnitRow(
                unit: unit,
                onEdit: () => onEdit(unit),
                onToggleActive: () => onToggleActive(unit),
                onDelete: () => onDelete(unit),
              ),
          ],
        ),
      ],
    );
  }
}

enum _UnitAction { edit, toggleActive, delete }

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.unit,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  final UnitOfMeasure unit;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return PointyDataRow(
      onTap: onEdit,
      leading: _UnitGlyph(active: unit.isActive),
      title: unit.name,
      subtitle: _subtitle(l10n),
      badges: [
        if (unit.isSystem)
          PointyStatusPill(
            label: l10n.unitSystemBadge,
            icon: Icons.lock_outline,
            color: colors.mutedInk,
          ),
        if (!unit.isActive)
          PointyStatusPill(
            label: l10n.unitInactiveBadge,
            color: colors.warning,
          ),
        if (unit.isInUse)
          PointyStatusPill(
            label: l10n.unitInUseBadge(unit.productCount),
            icon: Icons.inventory_2_outlined,
            color: colors.primaryStrong,
          ),
      ],
      trailing: PopupMenuButton<_UnitAction>(
        tooltip: l10n.moreActionsTooltip,
        icon: const Icon(Icons.more_vert),
        onSelected: (action) => switch (action) {
          _UnitAction.edit => onEdit(),
          _UnitAction.toggleActive => onToggleActive(),
          _UnitAction.delete => onDelete(),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _UnitAction.edit,
            child: _MenuRow(icon: Icons.edit_outlined, label: l10n.editButton),
          ),
          PopupMenuItem(
            value: _UnitAction.toggleActive,
            child: _MenuRow(
              icon: unit.isActive
                  ? Icons.toggle_off_outlined
                  : Icons.toggle_on_outlined,
              label: unit.isActive
                  ? l10n.unitDeactivateAction
                  : l10n.unitActivateAction,
            ),
          ),
          PopupMenuItem(
            value: _UnitAction.delete,
            child: _MenuRow(
              icon: Icons.delete_outline,
              label: l10n.deleteButton,
              color: colors.danger,
            ),
          ),
        ],
      ),
    );
  }

  String _subtitle(AppLocalizations l10n) {
    final parts = <String>[
      if (unit.abbreviation.isNotEmpty) unit.abbreviation,
      unit.code,
    ];
    final factor = unit.referenceFactor;
    if (factor != null) {
      parts.add(
        l10n.unitReferenceSummary(
          formatQuantity(factor),
          unitDimensionReferenceLabel(l10n, unit.dimension),
        ),
      );
    }
    return parts.join('  ·  ');
  }
}

class _UnitGlyph extends StatelessWidget {
  const _UnitGlyph({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: active ? colors.primaryContainer : colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Icon(
        Icons.straighten_outlined,
        size: 20,
        color: active ? colors.primaryStrong : colors.mutedInk,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? context.pointyColors.ink;
    return Row(
      children: [
        Icon(icon, size: 18, color: resolved),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: resolved)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Editor dialog
// ---------------------------------------------------------------------------

/// Opens the create/edit dialog for a unit, returning the entered draft (or null
/// if cancelled). [unit] non-null edits that unit; null creates a new one.
Future<UnitOfMeasureDraft?> showUnitEditorDialog(
  BuildContext context, {
  UnitOfMeasure? unit,
}) {
  return showDialog<UnitOfMeasureDraft>(
    context: context,
    builder: (_) => _UnitEditorDialog(unit: unit),
  );
}

class _UnitEditorDialog extends StatefulWidget {
  const _UnitEditorDialog({this.unit});

  final UnitOfMeasure? unit;

  @override
  State<_UnitEditorDialog> createState() => _UnitEditorDialogState();
}

class _UnitEditorDialogState extends State<_UnitEditorDialog> {
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _abbreviationController;
  late final TextEditingController _referenceController;
  late String _dimension;
  late bool _allowsFractional;
  late bool _isActive;

  bool get _isEditing => widget.unit != null;
  bool get _isSystem => widget.unit?.isSystem ?? false;
  bool get _isPhysical => _dimension != 'count';

  @override
  void initState() {
    super.initState();
    final unit = widget.unit;
    _codeController = TextEditingController(text: unit?.code ?? '');
    _nameController = TextEditingController(text: unit?.name ?? '');
    _abbreviationController = TextEditingController(
      text: unit?.abbreviation ?? '',
    );
    _referenceController = TextEditingController(
      text: unit?.referenceFactor == null
          ? ''
          : formatQuantity(unit!.referenceFactor!),
    );
    _dimension = unit?.dimension ?? 'count';
    _allowsFractional = unit?.allowsFractional ?? false;
    _isActive = unit?.isActive ?? true;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _abbreviationController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  bool get _isValid {
    final hasName = _nameController.text.trim().isNotEmpty;
    final hasCode = _isSystem || _codeController.text.trim().isNotEmpty;
    return hasName && hasCode;
  }

  void _submit() {
    if (!_isValid) {
      return;
    }
    final reference = double.tryParse(
      _referenceController.text.trim().replaceAll(',', '.'),
    );
    Navigator.of(context).pop(
      UnitOfMeasureDraft(
        code: _codeController.text.trim().toLowerCase(),
        name: _nameController.text.trim(),
        abbreviation: _abbreviationController.text.trim(),
        dimension: _dimension,
        referenceFactor: _isPhysical ? reference : null,
        allowsFractional: _allowsFractional,
        isActive: _isActive,
        displayOrder: widget.unit?.displayOrder ?? 0,
        // The server locks a built-in unit's code, so omit it when editing one.
        includeCode: !_isSystem,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AlertDialog(
      icon: const Icon(Icons.straighten_outlined),
      title: Text(_isEditing ? l10n.unitEditTitle : l10n.unitCreateTitle),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isSystem)
                Padding(
                  padding: EdgeInsets.only(bottom: spacing.md),
                  child: PointyInlineMessage(
                    message: l10n.unitSystemLockedHint,
                    icon: Icons.lock_outline,
                    compact: true,
                  ),
                ),
              TextField(
                controller: _nameController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l10n.unitNameLabel),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: spacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeController,
                      enabled: !_isSystem,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-z0-9_-]'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.unitCodeLabel,
                        helperText: l10n.unitCodeHelper,
                        helperMaxLines: 2,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  Expanded(
                    child: TextField(
                      controller: _abbreviationController,
                      decoration: InputDecoration(
                        labelText: l10n.unitAbbreviationLabel,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing.md),
              DropdownButtonFormField<String>(
                initialValue: _dimension,
                decoration: InputDecoration(labelText: l10n.unitDimensionLabel),
                items: [
                  for (final dimension in kUnitDimensions)
                    DropdownMenuItem(
                      value: dimension,
                      child: Text(unitDimensionLabel(l10n, dimension)),
                    ),
                ],
                onChanged: _isSystem
                    ? null
                    : (value) => setState(() => _dimension = value ?? 'count'),
              ),
              if (_isPhysical) ...[
                SizedBox(height: spacing.md),
                TextField(
                  controller: _referenceController,
                  enabled: !_isSystem,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.unitReferenceFactorLabel,
                    helperText: l10n.unitReferenceFactorHelper,
                    helperMaxLines: 2,
                  ),
                ),
              ],
              SizedBox(height: spacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.unitAllowsFractionalLabel),
                value: _allowsFractional,
                onChanged: (value) => setState(() => _allowsFractional = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.unitActiveLabel),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
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
        FilledButton(
          onPressed: _isValid ? _submit : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
