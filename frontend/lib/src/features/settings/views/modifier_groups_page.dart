import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/modifier_group.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/modifier_groups_view_model.dart';

class ModifierGroupsPage extends StatefulWidget {
  const ModifierGroupsPage({super.key, required this.viewModel});

  final ModifierGroupsViewModel viewModel;

  @override
  State<ModifierGroupsPage> createState() => _ModifierGroupsPageState();
}

class _ModifierGroupsPageState extends State<ModifierGroupsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
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
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.modifierGroupsSectionTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.modifierGroupAddButton,
                onPressed: viewModel.isMutating
                    ? null
                    : () => _openEditor(context),
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.groups.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.groups.isEmpty) {
      return PointyErrorState(
        title: l10n.modifierGroupsLoadError,
        icon: Icons.tune_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (viewModel.groups.isEmpty) {
      return PointyEmptyState(
        icon: Icons.tune_outlined,
        title: l10n.modifierGroupsEmptyMessage,
        action: FilledButton.icon(
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: Text(l10n.modifierGroupAddButton),
        ),
      );
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointySettingsSection(
            children: [
              for (final group in viewModel.groups)
                ListTile(
                  leading: const Icon(Icons.tune_outlined),
                  title: Text(group.name),
                  subtitle: Text(
                    l10n.modifierGroupSummary(
                      group.isSingleSelect
                          ? l10n.modifierGroupSingleSelectLabel
                          : l10n.modifierGroupOptionsLabel,
                      group.options.length,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.editButton,
                        onPressed: viewModel.isMutating
                            ? null
                            : () => _openEditor(context, group: group),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: l10n.deleteButton,
                        onPressed: viewModel.isMutating
                            ? null
                            : () => _confirmDelete(context, group),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  onTap: viewModel.isMutating
                      ? null
                      : () => _openEditor(context, group: group),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(
    BuildContext context, {
    ModifierGroup? group,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<ModifierGroupDraft>(
      context: context,
      builder: (_) => _ModifierGroupEditorDialog(group: group),
    );
    if (draft == null) {
      return;
    }
    final saved = group == null
        ? await widget.viewModel.createGroup(draft)
        : await widget.viewModel.updateGroup(group.id, draft);
    if (!saved) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.modifierGroupSaveError)),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, ModifierGroup group) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.modifierGroupDeleteTitle),
        content: Text(l10n.modifierGroupDeleteMessage),
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
    if (confirmed != true) {
      return;
    }
    final deleted = await widget.viewModel.deleteGroup(group);
    if (!deleted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.modifierGroupDeleteError)),
      );
    }
  }
}

class _EditableOption {
  _EditableOption({
    this.id,
    String name = '',
    double priceDelta = 0,
    this.maxQuantity = 1,
    this.isDefault = false,
  }) : nameController = TextEditingController(text: name),
       priceController = TextEditingController(
         text: priceDelta == 0 ? '' : priceDelta.toStringAsFixed(2),
       );

  final int? id;
  final TextEditingController nameController;
  final TextEditingController priceController;
  int maxQuantity;
  bool isDefault;

  void dispose() {
    nameController.dispose();
    priceController.dispose();
  }

  ModifierOptionDraft toDraft(int index) {
    return ModifierOptionDraft(
      id: id,
      name: nameController.text.trim(),
      priceDelta: double.tryParse(priceController.text.trim()) ?? 0,
      maxQuantity: maxQuantity,
      isDefault: isDefault,
      displayOrder: index,
    );
  }
}

class _ModifierGroupEditorDialog extends StatefulWidget {
  const _ModifierGroupEditorDialog({required this.group});

  final ModifierGroup? group;

  @override
  State<_ModifierGroupEditorDialog> createState() =>
      _ModifierGroupEditorDialogState();
}

class _ModifierGroupEditorDialogState
    extends State<_ModifierGroupEditorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.group?.name ?? '',
  );
  late bool _singleSelect = widget.group?.isSingleSelect ?? true;
  late bool _required = widget.group?.isRequired ?? false;
  late final List<_EditableOption> _options = _initialOptions();

  List<_EditableOption> _initialOptions() {
    final group = widget.group;
    if (group == null || group.options.isEmpty) {
      return [_EditableOption()];
    }
    return [
      for (final option in group.options)
        _EditableOption(
          id: option.id,
          name: option.name,
          priceDelta: option.priceDelta,
          maxQuantity: option.maxQuantity,
          isDefault: option.isDefault,
        ),
    ];
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  bool get _isValid =>
      _nameController.text.trim().isNotEmpty &&
      _options.any((option) => option.nameController.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.tune_outlined),
      title: Text(
        widget.group == null ? l10n.modifierGroupAddButton : widget.group!.name,
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.modifierGroupNameLabel,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.modifierGroupSingleSelectLabel),
                value: _singleSelect,
                onChanged: (value) => setState(() => _singleSelect = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.modifierGroupRequiredToggleLabel),
                value: _required,
                onChanged: (value) => setState(() => _required = value),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  l10n.modifierGroupOptionsLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              for (var index = 0; index < _options.length; index += 1)
                _OptionEditorRow(
                  key: ValueKey(_options[index]),
                  option: _options[index],
                  canDelete: _options.length > 1,
                  onChanged: () => setState(() {}),
                  onDelete: () => setState(() {
                    _options.removeAt(index).dispose();
                  }),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _options.add(_EditableOption())),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.modifierOptionAddButton),
                ),
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

  void _submit() {
    final options = <ModifierOptionDraft>[];
    var index = 0;
    for (final option in _options) {
      if (option.nameController.text.trim().isEmpty) {
        continue;
      }
      options.add(option.toDraft(index));
      index += 1;
    }
    Navigator.of(context).pop(
      ModifierGroupDraft(
        name: _nameController.text.trim(),
        minSelect: _required ? 1 : 0,
        maxSelect: _singleSelect ? 1 : null,
        options: options,
      ),
    );
  }
}

class _OptionEditorRow extends StatelessWidget {
  const _OptionEditorRow({
    super.key,
    required this.option,
    required this.canDelete,
    required this.onChanged,
    required this.onDelete,
  });

  final _EditableOption option;
  final bool canDelete;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: option.nameController,
                  decoration: InputDecoration(
                    labelText: l10n.modifierOptionNameLabel,
                    isDense: true,
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: option.priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.modifierOptionPriceLabel,
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.deleteButton,
                onPressed: canDelete ? onDelete : null,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(l10n.modifierOptionDefaultLabel),
                  value: option.isDefault,
                  onChanged: (value) {
                    option.isDefault = value ?? false;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(l10n.modifierOptionMaxQtyLabel),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: l10n.modifierOptionMaxQtyDecreaseTooltip,
                onPressed: option.maxQuantity > 1
                    ? () {
                        option.maxQuantity -= 1;
                        onChanged();
                      }
                    : null,
                icon: const Icon(Icons.remove, size: 18),
              ),
              Text('${option.maxQuantity}'),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: l10n.modifierOptionMaxQtyIncreaseTooltip,
                onPressed: () {
                  option.maxQuantity += 1;
                  onChanged();
                },
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
