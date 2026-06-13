import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/prep_station.dart';
import '../../../data/models/product_category.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/prep_stations_view_model.dart';

class PrepStationsPage extends StatefulWidget {
  const PrepStationsPage({super.key, required this.viewModel});

  final PrepStationsViewModel viewModel;

  @override
  State<PrepStationsPage> createState() => _PrepStationsPageState();
}

class _PrepStationsPageState extends State<PrepStationsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.load());
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
            title: Text(l10n.prepStationsSectionTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.prepStationAddButton,
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

    if (viewModel.isLoading && viewModel.stations.isEmpty) {
      return const PointyLoadingArea();
    }

    if (viewModel.hasLoadError && viewModel.stations.isEmpty) {
      return PointyErrorState(
        title: l10n.prepStationsLoadError,
        icon: Icons.dinner_dining_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    if (viewModel.stations.isEmpty) {
      return PointyEmptyState(
        icon: Icons.dinner_dining_outlined,
        title: l10n.prepStationsEmptyMessage,
        action: FilledButton.icon(
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: Text(l10n.prepStationAddButton),
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
              for (final station in viewModel.stations)
                _PrepStationTile(
                  station: station,
                  isBusy: viewModel.isMutating,
                  onEdit: () => _openEditor(context, station: station),
                  onDelete: () => _confirmDelete(context, station),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, {PrepStation? station}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<PrepStationDraft>(
      context: context,
      builder: (_) => _PrepStationEditorDialog(
        station: station,
        categories: widget.viewModel.categories,
      ),
    );
    if (draft == null) {
      return;
    }
    final saved = station == null
        ? await widget.viewModel.createStation(draft)
        : await widget.viewModel.updateStation(station.id, draft.toJson());
    if (!saved) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.prepStationSaveError)));
    }
  }

  Future<void> _confirmDelete(BuildContext context, PrepStation station) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.prepStationDeleteTitle),
        content: Text(l10n.prepStationDeleteMessage),
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
    final deleted = await widget.viewModel.deleteStation(station);
    if (!deleted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.prepStationDeleteError)),
      );
    }
  }
}

class _PrepStationTile extends StatelessWidget {
  const _PrepStationTile({
    required this.station,
    required this.isBusy,
    required this.onEdit,
    required this.onDelete,
  });

  final PrepStation station;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final subtitleParts = <String>[
      if (station.categoryNames.isEmpty)
        l10n.prepStationCategoriesEmpty
      else
        station.categoryNames.join('، '),
      if (station.printerProfileName.isNotEmpty) station.printerProfileName,
    ];

    return ListTile(
      leading: const Icon(Icons.dinner_dining_outlined),
      title: Row(
        children: [
          Flexible(child: Text(station.name)),
          if (station.isDefault) ...[
            const SizedBox(width: 8),
            _Badge(label: l10n.prepStationDefaultBadge),
          ],
          if (!station.isActive) ...[
            const SizedBox(width: 8),
            _Badge(label: l10n.prepStationInactiveBadge),
          ],
        ],
      ),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.editButton,
            onPressed: isBusy ? null : onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: l10n.deleteButton,
            onPressed: isBusy ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      onTap: isBusy ? null : onEdit,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _PrepStationEditorDialog extends StatefulWidget {
  const _PrepStationEditorDialog({
    required this.station,
    required this.categories,
  });

  final PrepStation? station;
  final List<ProductCategory> categories;

  @override
  State<_PrepStationEditorDialog> createState() =>
      _PrepStationEditorDialogState();
}

class _PrepStationEditorDialogState extends State<_PrepStationEditorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.station?.name ?? '',
  );
  late final Set<int> _selectedCategoryIds = {
    ...?widget.station?.categoryIds,
  };
  late bool _isDefault = widget.station?.isDefault ?? false;
  late bool _isActive = widget.station?.isActive ?? true;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _isValid => _nameController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.dinner_dining_outlined),
      title: Text(
        widget.station == null
            ? l10n.prepStationAddButton
            : widget.station!.name,
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.prepStationNameLabel,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.prepStationDefaultLabel),
                value: _isDefault,
                onChanged: (value) => setState(() => _isDefault = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.prepStationActiveLabel),
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  l10n.prepStationCategoriesLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: widget.categories.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(l10n.prepStationCategoriesEmpty),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final category in widget.categories)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(category.displayPath),
                              value: _selectedCategoryIds.contains(category.id),
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _selectedCategoryIds.add(category.id);
                                } else {
                                  _selectedCategoryIds.remove(category.id);
                                }
                              }),
                            ),
                        ],
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
    Navigator.of(context).pop(
      PrepStationDraft(
        name: _nameController.text.trim(),
        printerProfileId: widget.station?.printerProfileId,
        categoryIds: _selectedCategoryIds.toList(growable: false),
        isDefault: _isDefault,
        isActive: _isActive,
        priority: widget.station?.priority ?? 0,
      ),
    );
  }
}
