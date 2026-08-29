import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/customer_asset.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../assets/views/assets_ui.dart';
import '../../operations/view_models/asset_types_view_model.dart';

/// What this shop takes in, and which numbers each kind is known by.
///
/// Lives beside the workflow editor because it answers the same question from
/// the other side: the workflow says how work moves, this says what the work is
/// done *on*. A television repairer and a car workshop run the same engine and
/// differ only here.
class AssetTypesSection extends StatelessWidget {
  const AssetTypesSection({
    super.key,
    required this.viewModel,
    this.canEdit = true,
  });

  final AssetTypesViewModel viewModel;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return PointyDetailSection(
      title: l10n.assetTypesSectionTitle,
      icon: Icons.devices_other_outlined,
      trailing: canEdit
          ? TextButton.icon(
              onPressed: viewModel.isMutating
                  ? null
                  : () => _openEditor(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.assetTypeAddButton),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.assetTypesSectionHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.sm),
          if (viewModel.isLoading && viewModel.types.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: PointySpinner()),
            )
          else
            for (final type in viewModel.types)
              _AssetTypeRow(
                type: type,
                canEdit: canEdit,
                onEdit: () => _openEditor(context, type),
                onDelete: () => _confirmDelete(context, type),
              ),
        ],
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    CustomerAssetType? type,
  ) async {
    final saved = await showDialog<CustomerAssetType>(
      context: context,
      builder: (_) => _AssetTypeEditorDialog(type: type),
    );
    if (saved == null || !context.mounted) {
      return;
    }
    final ok = await viewModel.save(saved);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(viewModel.mutationError)));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    CustomerAssetType type,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PointyDestructiveConfirmationDialog(
        title: l10n.assetTypeDeleteConfirmTitle,
        message: l10n.assetTypeDeleteConfirmBody,
        confirmLabel: l10n.deleteButton,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final ok = await viewModel.remove(type.id);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(viewModel.mutationError)));
    }
  }
}

class _AssetTypeRow extends StatelessWidget {
  const _AssetTypeRow({
    required this.type,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final CustomerAssetType type;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    final identifiers = <String>[
      if (type.tracksSerialNumber) l10n.assetTypeTracksSerial,
      if (type.tracksImei) l10n.assetTypeTracksImei,
      if (type.tracksVin) l10n.assetTypeTracksVin,
      if (type.tracksPlateNumber) l10n.assetTypeTracksPlate,
      if (type.tracksEngineNumber) l10n.assetTypeTracksEngine,
      if (type.tracksCustomIdentifier) type.customIdentifierLabel,
    ];

    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.xs),
      child: Row(
        children: [
          AssetIconBadge(
            iconKey: type.iconKey,
            size: 34,
            color: type.isActive ? colors.primaryStrong : colors.mutedInk,
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        type.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!type.isActive) ...[
                      SizedBox(width: spacing.xs),
                      PointyStatusPill(
                        label: l10n.assetTypeInactiveBadge,
                        icon: Icons.visibility_off_outlined,
                        color: colors.mutedInk,
                      ),
                    ],
                  ],
                ),
                Text(
                  [
                    if (identifiers.isNotEmpty) identifiers.join(' · '),
                    l10n.assetTypeItemCount(type.assetCount),
                  ].join(' — '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
          if (canEdit) ...[
            IconButton(
              tooltip: l10n.editButton,
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            // A built-in type has no delete: it can be switched off, which is
            // the same outcome without stranding the items already on it.
            if (!type.isSystem)
              IconButton(
                tooltip: l10n.deleteButton,
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
          ],
        ],
      ),
    );
  }
}

class _AssetTypeEditorDialog extends StatefulWidget {
  const _AssetTypeEditorDialog({this.type});

  final CustomerAssetType? type;

  @override
  State<_AssetTypeEditorDialog> createState() => _AssetTypeEditorDialogState();
}

class _AssetTypeEditorDialogState extends State<_AssetTypeEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _slug;
  late final TextEditingController _customLabel;
  late String _iconKey;
  late bool _isActive;
  late bool _serial;
  late bool _imei;
  late bool _vin;
  late bool _plate;
  late bool _engine;
  late bool _year;
  late bool _odometer;
  var _showValidation = false;

  @override
  void initState() {
    super.initState();
    final type = widget.type;
    _name = TextEditingController(text: type?.name ?? '');
    _slug = TextEditingController(text: type?.slug ?? '');
    _customLabel = TextEditingController(
      text: type?.customIdentifierLabel ?? '',
    );
    _iconKey = type?.iconKey ?? 'device';
    _isActive = type?.isActive ?? true;
    _serial = type?.tracksSerialNumber ?? true;
    _imei = type?.tracksImei ?? false;
    _vin = type?.tracksVin ?? false;
    _plate = type?.tracksPlateNumber ?? false;
    _engine = type?.tracksEngineNumber ?? false;
    _year = type?.tracksModelYear ?? false;
    _odometer = type?.tracksOdometer ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _customLabel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final slugInvalid =
        _showValidation &&
        !RegExp(r'^[a-z0-9_-]+$').hasMatch(_slug.text.trim());

    return AlertDialog(
      title: Text(
        widget.type == null
            ? l10n.assetTypeCreateTitle
            : l10n.assetTypeEditTitle,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: l10n.assetTypeNameLabel),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _slug,
                // The slug is the stable key behind the label; a shop may rename
                // "تلفاز" freely without anything that referenced it breaking.
                enabled: widget.type == null,
                decoration: InputDecoration(
                  labelText: l10n.assetTypeSlugLabel,
                  errorText: slugInvalid ? l10n.assetTypeSlugRequired : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _iconKey,
                decoration: InputDecoration(labelText: l10n.assetTypeIconLabel),
                items: [
                  for (final entry in assetTypeIcons.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Icon(entry.value, size: 20),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _iconKey = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  l10n.assetTypeIdentifiersLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              _flag(l10n.assetTypeTracksSerial, _serial, (v) => _serial = v),
              _flag(l10n.assetTypeTracksImei, _imei, (v) => _imei = v),
              _flag(l10n.assetTypeTracksVin, _vin, (v) => _vin = v),
              _flag(l10n.assetTypeTracksPlate, _plate, (v) => _plate = v),
              _flag(l10n.assetTypeTracksEngine, _engine, (v) => _engine = v),
              _flag(l10n.assetTypeTracksYear, _year, (v) => _year = v),
              _flag(
                l10n.assetTypeTracksOdometer,
                _odometer,
                (v) => _odometer = v,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _customLabel,
                decoration: InputDecoration(
                  labelText: l10n.assetTypeCustomLabelLabel,
                  hintText: l10n.assetTypeCustomLabelHint,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(l10n.assetTypeActiveLabel),
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
        FilledButton(onPressed: _submit, child: Text(l10n.saveButton)),
      ],
    );
  }

  Widget _flag(String label, bool value, ValueChanged<bool> apply) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      value: value,
      onChanged: (next) => setState(() => apply(next)),
    );
  }

  void _submit() {
    final name = _name.text.trim();
    final slug = _slug.text.trim();
    if (name.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(slug)) {
      setState(() => _showValidation = true);
      return;
    }
    Navigator.of(context).pop(
      CustomerAssetType(
        id: widget.type?.id ?? 0,
        name: name,
        slug: slug,
        iconKey: _iconKey,
        displayOrder: widget.type?.displayOrder ?? 0,
        isActive: _isActive,
        isSystem: widget.type?.isSystem ?? false,
        tracksSerialNumber: _serial,
        tracksImei: _imei,
        tracksVin: _vin,
        tracksPlateNumber: _plate,
        tracksEngineNumber: _engine,
        tracksModelYear: _year,
        tracksOdometer: _odometer,
        customIdentifierLabel: _customLabel.text.trim(),
      ),
    );
  }
}
