import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/warehouse.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/warehouses_view_model.dart';

/// Where the shop keeps its stock.
///
/// Written for the shop that has one place, because that is nearly all of them:
/// the page opens saying so plainly rather than presenting an empty-looking
/// list, and adding a second room is an offer, never a prompt.
class WarehousesPage extends StatefulWidget {
  const WarehousesPage({super.key, required this.viewModel});

  final WarehousesViewModel viewModel;

  @override
  State<WarehousesPage> createState() => _WarehousesPageState();
}

class _WarehousesPageState extends State<WarehousesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
            title: Text(l10n.warehousesTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.warehousesAddAction,
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

    if (viewModel.isLoading && viewModel.warehouses.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.warehouses.isEmpty) {
      return PointyErrorState(
        title: l10n.warehousesTitle,
        icon: Icons.warehouse_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
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
              if (viewModel.hasOnlyOnePlace) ...[
                _OnePlaceCallout(
                  name: viewModel.defaultWarehouse?.name ?? '',
                  onAdd: viewModel.isMutating
                      ? null
                      : () => _openEditor(context),
                ),
                SizedBox(height: spacing.lg),
              ],
              PointySettingsSection(
                children: [
                  for (final warehouse in viewModel.warehouses)
                    _WarehouseTile(
                      warehouse: warehouse,
                      isBusy: viewModel.isMutating,
                      isThisTill:
                          viewModel.registerProfile?.warehouseId == warehouse.id,
                      onEdit: () =>
                          _openEditor(context, warehouse: warehouse),
                      onDelete: warehouse.canDelete
                          ? () => _confirmDelete(context, warehouse)
                          : () => _explainBlockers(context, warehouse),
                    ),
                ],
              ),
              SizedBox(height: spacing.lg),
              _ThisTillCard(
                viewModel: viewModel,
                onChange: () => _pickTillWarehouse(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, {Warehouse? warehouse}) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final draft = await showDialog<Warehouse>(
      context: context,
      builder: (_) => _WarehouseEditorDialog(warehouse: warehouse),
    );
    if (draft == null) return;
    final error = await widget.viewModel.save(draft);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? l10n.warehouseSaved)),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Warehouse warehouse) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l10n.warehouseDeleteConfirmTitle(warehouse.name)),
        content: Text(l10n.warehouseDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await widget.viewModel.delete(warehouse);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? l10n.warehouseDeleted)),
    );
  }

  /// Rather than a delete button that fails, the reasons are shown up front —
  /// they come from the server, which is the thing that actually knows.
  Future<void> _explainBlockers(
    BuildContext context,
    Warehouse warehouse,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text(l10n.warehouseDeleteBlockedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final blocker in warehouse.blockers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $blocker'),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.closeButton),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTillWarehouse(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final viewModel = widget.viewModel;
    final chosen = await showDialog<Warehouse>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.registerWarehouseTitle),
        children: [
          for (final warehouse in viewModel.warehouses)
            if (warehouse.isActive)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(warehouse),
                child: ListTile(
                  leading: Icon(_iconFor(warehouse.kind)),
                  title: Text(warehouse.name),
                  subtitle: Text(warehouse.kind.label(l10n)),
                  trailing:
                      viewModel.registerProfile?.warehouseId == warehouse.id
                      ? const Icon(Icons.check)
                      : null,
                ),
              ),
        ],
      ),
    );
    if (chosen == null) return;
    final error = await viewModel.assignThisTill(chosen.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? l10n.registerWarehouseSaved(chosen.name)),
      ),
    );
  }
}

IconData _iconFor(WarehouseKind kind) {
  switch (kind) {
    case WarehouseKind.shopFloor:
      return Icons.storefront_outlined;
    case WarehouseKind.storeRoom:
      return Icons.warehouse_outlined;
    case WarehouseKind.van:
      return Icons.local_shipping_outlined;
    case WarehouseKind.transit:
      return Icons.route_outlined;
  }
}

/// The state nearly every shop is in. Says so in a sentence rather than
/// presenting a one-row list that looks like something is missing.
class _OnePlaceCallout extends StatelessWidget {
  const _OnePlaceCallout({required this.name, required this.onAdd});

  final String name;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailCallout(
      icon: Icons.storefront_outlined,
      title: l10n.warehousesEmptyTitle,
      message: l10n.warehousesEmptyBody(name),
      trailing: TextButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: Text(l10n.warehousesAddAction),
      ),
    );
  }
}

class _WarehouseTile extends StatelessWidget {
  const _WarehouseTile({
    required this.warehouse,
    required this.isBusy,
    required this.isThisTill,
    required this.onEdit,
    required this.onDelete,
  });

  final Warehouse warehouse;
  final bool isBusy;
  final bool isThisTill;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = <String>[
      warehouse.kind.label(l10n),
      l10n.warehouseProductsHeld('${warehouse.stockItemCount}'),
      if (warehouse.oversellPolicy != WarehouseOversellPolicy.shopDefault)
        _oversellLabel(l10n, warehouse.oversellPolicy),
    ];

    return ListTile(
      leading: Icon(_iconFor(warehouse.kind)),
      title: Row(
        children: [
          Flexible(child: Text(warehouse.name)),
          if (warehouse.isDefault) ...[
            const SizedBox(width: 8),
            _Chip(label: l10n.warehouseDefaultBadge),
          ],
          if (isThisTill) ...[
            const SizedBox(width: 8),
            _Chip(label: l10n.registerWarehouseTitle, subtle: true),
          ],
          if (!warehouse.isActive) ...[
            const SizedBox(width: 8),
            _Chip(label: l10n.warehouseInactiveBadge),
          ],
        ],
      ),
      subtitle: Text(subtitle.join(' · ')),
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
            // Never disabled: a locked place explains itself when tapped,
            // which is more use than a greyed-out button that says nothing.
            onPressed: isBusy ? null : onDelete,
            icon: Icon(
              warehouse.canDelete ? Icons.delete_outline : Icons.lock_outline,
            ),
          ),
        ],
      ),
      onTap: isBusy ? null : onEdit,
    );
  }

  String _oversellLabel(AppLocalizations l10n, WarehouseOversellPolicy policy) {
    switch (policy) {
      case WarehouseOversellPolicy.allow:
        return l10n.warehouseOversellAllow;
      case WarehouseOversellPolicy.refuse:
        return l10n.warehouseOversellRefuse;
      case WarehouseOversellPolicy.shopDefault:
        return l10n.warehouseOversellShopDefault;
    }
  }
}

class _ThisTillCard extends StatelessWidget {
  const _ThisTillCard({required this.viewModel, required this.onChange});

  final WarehousesViewModel viewModel;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final profile = viewModel.registerProfile;
    // Nothing to choose between while the shop has one place, and a control
    // whose only option is the one already selected is noise.
    if (profile == null || viewModel.hasOnlyOnePlace) {
      return const SizedBox.shrink();
    }
    return PointySettingsSection(
      children: [
        ListTile(
          leading: Icon(_iconFor(profile.kind)),
          title: Text(
            profile.assigned
                ? profile.warehouseName
                : l10n.registerWarehouseUnassigned,
          ),
          subtitle: Text(l10n.registerWarehouseBody),
          trailing: TextButton(
            onPressed: viewModel.isMutating ? null : onChange,
            child: Text(l10n.registerWarehouseChangeAction),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.subtle = false});

  final String label;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: subtle ? colors.subtleFill : colors.amberContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: colors.ink),
      ),
    );
  }
}

class _WarehouseEditorDialog extends StatefulWidget {
  const _WarehouseEditorDialog({required this.warehouse});

  final Warehouse? warehouse;

  @override
  State<_WarehouseEditorDialog> createState() => _WarehouseEditorDialogState();
}

class _WarehouseEditorDialogState extends State<_WarehouseEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.warehouse?.name ?? '',
  );
  late final TextEditingController _code = TextEditingController(
    text: widget.warehouse?.code ?? '',
  );
  late WarehouseKind _kind = widget.warehouse?.kind ?? WarehouseKind.storeRoom;
  late WarehouseOversellPolicy _policy =
      widget.warehouse?.oversellPolicy ?? WarehouseOversellPolicy.shopDefault;
  late bool _isActive = widget.warehouse?.isActive ?? true;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _name.text.trim().isNotEmpty && _code.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isNew = widget.warehouse == null;
    return AlertDialog(
      title: Text(isNew ? l10n.warehouseCreateTitle : l10n.warehouseEditTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.warehouseNameLabel),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              // The code is what reports and stock rows reference; changing it
              // later would rename a thing other records already point at.
              enabled: isNew,
              decoration: InputDecoration(
                labelText: l10n.warehouseCodeLabel,
                helperText: l10n.warehouseCodeHelp,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WarehouseKind>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.warehouseKindLabel),
              items: [
                // Transit is not offered: it is a state stock passes through,
                // created by the transfer itself, and the server refuses it.
                for (final kind in WarehouseKind.values)
                  if (kind != WarehouseKind.transit)
                    DropdownMenuItem(
                      value: kind,
                      child: Text(kind.label(l10n)),
                    ),
              ],
              onChanged: (value) =>
                  setState(() => _kind = value ?? _kind),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<WarehouseOversellPolicy>(
              initialValue: _policy,
              decoration: InputDecoration(
                labelText: l10n.warehouseOversellLabel,
              ),
              items: [
                DropdownMenuItem(
                  value: WarehouseOversellPolicy.shopDefault,
                  child: Text(l10n.warehouseOversellShopDefault),
                ),
                DropdownMenuItem(
                  value: WarehouseOversellPolicy.allow,
                  child: Text(l10n.warehouseOversellAllow),
                ),
                DropdownMenuItem(
                  value: WarehouseOversellPolicy.refuse,
                  child: Text(l10n.warehouseOversellRefuse),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _policy = value ?? _policy),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isActive,
              title: Text(l10n.warehouseActiveLabel),
              onChanged: (value) => setState(() => _isActive = value),
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
          onPressed: _isValid ? _submit : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(
      Warehouse(
        id: widget.warehouse?.id ?? 0,
        name: _name.text.trim(),
        code: _code.text.trim(),
        kind: _kind,
        oversellPolicy: _policy,
        isDefault: widget.warehouse?.isDefault ?? false,
        isActive: _isActive,
      ),
    );
  }
}
