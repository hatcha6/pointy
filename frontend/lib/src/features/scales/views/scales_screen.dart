import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/scale.dart';
import '../../../data/services/analytics_export_downloader.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/scales_view_model.dart';

/// The shop's weighing scales, and the button that makes them agree with the
/// catalog.
///
/// The screen is built around one distinction it refuses to blur: a file that
/// has been produced is not a scale that has been updated. Most scales in this
/// market are loaded from a file, and saying "done" when the prices are still
/// sitting in a download would be the same lie as retyping them and not
/// checking.
class ScalesScreen extends StatefulWidget {
  const ScalesScreen({super.key, required this.viewModel});

  final ScalesViewModel viewModel;

  @override
  State<ScalesScreen> createState() => _ScalesScreenState();
}

class _ScalesScreenState extends State<ScalesScreen> {
  ScalesViewModel get viewModel => widget.viewModel;

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
            title: Text(l10n.scalesTitle),
            isLoading: viewModel.busyScaleId != null,
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openEditor(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addScaleButton),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                PointyDetailCallout(
                  icon: Icons.monitor_weight_outlined,
                  title: l10n.scalesIntroTitle,
                  message: l10n.scalesIntroMessage,
                ),
                const SizedBox(height: 16),
                if (viewModel.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: PointySpinner()),
                  )
                else ...[
                  if (viewModel.scales.isEmpty)
                    PointyEmptyState(
                      icon: Icons.monitor_weight_outlined,
                      title: l10n.scalesEmpty,
                      message: l10n.scalesIntroMessage,
                    )
                  else
                    for (final scale in viewModel.scales)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ScaleCard(
                          scale: scale,
                          viewModel: viewModel,
                          onEdit: () => _openEditor(context, scale: scale),
                          onDelete: () => _delete(context, scale),
                          onCheck: () => viewModel.check(scale.id),
                          onPush: () => _push(context, scale),
                          onExport: () => _export(context, scale),
                        ),
                      ),
                  const SizedBox(height: 16),
                  _PluSection(viewModel: viewModel),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEditor(BuildContext context, {Scale? scale}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) =>
          _ScaleEditorDialog(scale: scale, drivers: viewModel.drivers),
    );
    if (draft == null) {
      return;
    }
    final ok = await viewModel.save(id: scale?.id, draft: draft);
    if (!ok) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              viewModel.errorMessage.isEmpty
                  ? l10n.scaleSaveError
                  : viewModel.errorMessage,
            ),
          ),
        );
    }
  }

  Future<void> _delete(BuildContext context, Scale scale) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.scaleDeleteTitle,
        message: l10n.scaleDeleteMessage,
        confirmLabel: l10n.deleteButton,
      ),
    );
    if (confirmed == true) {
      await viewModel.remove(scale.id);
    }
  }

  Future<void> _push(BuildContext context, Scale scale) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final job = await viewModel.push(scale.id);
    if (job == null) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(_pushMessage(l10n, job))));
  }

  /// Download the PLU file — and, for a scale that has no other way of being
  /// fed, record the push at the same time. The shop pressed one button; the
  /// history should not pretend nothing happened.
  Future<void> _export(BuildContext context, Scale scale) async {
    final messenger = ScaffoldMessenger.of(context);
    final needsAddress =
        viewModel.driverFor(scale.driver)?.needsAddress ?? scale.needsAddress;
    if (!needsAddress) {
      await viewModel.push(scale.id);
    }
    final file = await viewModel.exportFile(scale.id);
    if (file == null) {
      if (viewModel.errorMessage.isNotEmpty) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(viewModel.errorMessage)));
      }
      return;
    }
    await downloadAnalyticsExportFile(file);
  }
}

String _pushMessage(AppLocalizations l10n, ScalePushJob job) {
  return switch (job.status) {
    'exported' => l10n.scalePushExportedMessage,
    'succeeded' => l10n.scalePushSucceededMessage(job.sentCount),
    'partial' => l10n.scalePushPartialMessage(job.sentCount, job.failedCount),
    _ => job.message.isNotEmpty ? job.message : l10n.scalePushFailedMessage,
  };
}

/// One scale, as a card of the same family as every other device card in the
/// app: a titled section with a state pill, its details as muted icon lines,
/// and its actions inside the card rather than floating under it.
class _ScaleCard extends StatelessWidget {
  const _ScaleCard({
    required this.scale,
    required this.viewModel,
    required this.onEdit,
    required this.onDelete,
    required this.onCheck,
    required this.onPush,
    required this.onExport,
  });

  final Scale scale;
  final ScalesViewModel viewModel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCheck;
  final VoidCallback onPush;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.busyScaleId == scale.id;
    final lastPush = viewModel.lastPushFor(scale.id);
    final reach = viewModel.reachabilityFor(scale.id);
    final driver = viewModel.driverFor(scale.driver);
    final needsAddress = driver?.needsAddress ?? scale.needsAddress;
    final status = _statusFor(l10n, colors, lastPush);

    return PointyDetailSection(
      icon: Icons.monitor_weight_outlined,
      title: scale.name,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PointyStatusPill(
            label: status.label,
            icon: status.icon,
            color: status.color,
          ),
          // Everything that is not the one thing this card is for. Renaming a
          // scale, reaching for the file when the wire is the problem, and
          // deleting it are all rare next to "get today's prices onto it", and
          // giving each of them a row of its own is what made the card read
          // like a toolbar with a scale attached.
          PopupMenuButton<_ScaleAction>(
            enabled: !busy,
            onSelected: (action) => switch (action) {
              _ScaleAction.edit => onEdit(),
              _ScaleAction.exportFile => onExport(),
              _ScaleAction.delete => onDelete(),
            },
            itemBuilder: (menuContext) => [
              PopupMenuItem(
                value: _ScaleAction.edit,
                child: Text(l10n.editButton),
              ),
              if (needsAddress)
                PopupMenuItem(
                  value: _ScaleAction.exportFile,
                  child: Text(l10n.scaleExportFallbackAction),
                ),
              PopupMenuItem(
                value: _ScaleAction.delete,
                child: Text(l10n.deleteButton),
              ),
            ],
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScaleLine(
            icon: needsAddress
                ? Icons.cable_outlined
                : Icons.description_outlined,
            child: Text(
              scale.driverLabel.isEmpty ? scale.driver : scale.driverLabel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ),
          if (needsAddress && scale.host.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: spacing.xs),
              child: _ScaleLine(
                icon: Icons.lan_outlined,
                child: Text(
                  ltrIsolated(
                    scale.port > 0 ? '${scale.host}:${scale.port}' : scale.host,
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: spacing.xs),
            child: _ScaleLine(
              icon: Icons.schedule_outlined,
              child: Text(
                lastPush == null
                    ? l10n.scaleLastPushNever
                    : _pushMessage(l10n, lastPush),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: status.color),
              ),
            ),
          ),
          if (reach != null)
            Padding(
              padding: EdgeInsets.only(top: spacing.xs),
              child: _ScaleLine(
                icon: reach.reachable
                    ? Icons.wifi_tethering
                    : Icons.wifi_tethering_off_outlined,
                child: Text(
                  reach.reachable
                      ? l10n.scaleReachableMessage
                      : '${l10n.scaleUnreachableMessage} ${reach.detail}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: reach.reachable ? colors.success : colors.danger,
                  ),
                ),
              ),
            ),
          SizedBox(height: spacing.md),
          // One primary action per scale, named after what it actually does. A
          // file scale has no wire to push down — "send" there would produce a
          // download and change nothing on the scale, so the button says
          // download and there is only one of it. A wire scale keeps the file
          // as a named fallback for the day the network is the problem.
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : (needsAddress ? onPush : onExport),
                  icon: Icon(
                    needsAddress
                        ? Icons.upload_outlined
                        : Icons.download_outlined,
                    size: 18,
                  ),
                  label: Text(
                    needsAddress
                        ? l10n.scalePushAction
                        : l10n.scaleExportAction,
                  ),
                ),
              ),
              if (needsAddress) ...[
                SizedBox(width: spacing.sm),
                OutlinedButton.icon(
                  onPressed: busy ? null : onCheck,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(l10n.scaleCheckAction),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

enum _ScaleAction { edit, exportFile, delete }

/// A muted icon + content row — the secondary lines on a device card, matching
/// the price-checker cards.
class _ScaleLine extends StatelessWidget {
  const _ScaleLine({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: colors.mutedInk),
        const SizedBox(width: 6),
        Expanded(child: child),
      ],
    );
  }
}

/// What the card's pill says about where this scale's prices stand.
///
/// The distinction the pill exists to carry: a produced file is *waiting*, not
/// done. Only a push that reached the scale is "up to date".
({String label, IconData icon, Color color}) _statusFor(
  AppLocalizations l10n,
  PointySemanticColors colors,
  ScalePushJob? job,
) {
  if (job == null) {
    return (
      label: l10n.scaleStatusNeverPushed,
      icon: Icons.remove_circle_outline,
      color: colors.mutedInk,
    );
  }
  return switch (job.status) {
    'succeeded' => (
      label: l10n.scaleStatusUpToDate,
      icon: Icons.check_circle_outline,
      color: colors.success,
    ),
    'exported' => (
      label: l10n.scaleStatusWaitingToLoad,
      icon: Icons.hourglass_bottom_outlined,
      color: colors.warning,
    ),
    'partial' => (
      label: l10n.scaleStatusPartial,
      icon: Icons.error_outline,
      color: colors.warning,
    ),
    _ => (
      label: l10n.scaleStatusFailed,
      icon: Icons.cancel_outlined,
      color: colors.danger,
    ),
  };
}

class _PluSection extends StatelessWidget {
  const _PluSection({required this.viewModel});

  final ScalesViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return PointyDetailSection(
      icon: Icons.sell_outlined,
      title: l10n.scalePlusSectionTitle,
      trailing: TextButton.icon(
        onPressed: () => _assign(context),
        icon: const Icon(Icons.add, size: 18),
        label: Text(l10n.scaleAssignPluButton),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            viewModel.plus.isEmpty
                ? l10n.scalePlusEmpty
                : l10n.scaleAssignedCount(viewModel.assignedCount),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          for (final plu in viewModel.plus)
            Padding(
              padding: EdgeInsets.only(top: spacing.sm),
              child: _PluRow(
                plu: plu,
                onToggle: () =>
                    viewModel.retirePlu(plu.id, isActive: !plu.isActive),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _assign(BuildContext context) async {
    final variant = await showDialog<ProductVariant>(
      context: context,
      builder: (_) => _AssignPluDialog(viewModel: viewModel),
    );
    if (variant != null) {
      await viewModel.assignPlu(variant.id);
    }
  }
}

/// One product's number on the scales. The number is the row's identity, so it
/// leads; a retired row keeps it, greyed, because its stickers may still be in
/// the shop.
class _PluRow extends StatelessWidget {
  const _PluRow({required this.plu, required this.onToggle});

  final ScalePlu plu;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final tone = plu.isActive ? colors.ink : colors.mutedInk;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 34,
          child: Text(
            '${plu.pluNumber}',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: plu.isActive ? colors.primaryStrong : colors.mutedInk,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                plu.printedName,
                style: theme.textTheme.bodyMedium?.copyWith(color: tone),
              ),
              if (!plu.isActive)
                Text(
                  l10n.scalePluRetiredNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                )
              else if (plu.productName.isNotEmpty &&
                  plu.productName != plu.printedName)
                Text(
                  plu.productName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
            ],
          ),
        ),
        TextButton(
          onPressed: onToggle,
          child: Text(
            plu.isActive
                ? l10n.scalePluRetireAction
                : l10n.scalePluRestoreAction,
          ),
        ),
      ],
    );
  }
}

class _AssignPluDialog extends StatefulWidget {
  const _AssignPluDialog({required this.viewModel});

  final ScalesViewModel viewModel;

  @override
  State<_AssignPluDialog> createState() => _AssignPluDialogState();
}

class _AssignPluDialogState extends State<_AssignPluDialog> {
  final TextEditingController _search = TextEditingController();
  List<ProductVariant> _results = const [];
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run(String term) async {
    setState(() => _searching = true);
    final results = await widget.viewModel.searchVariants(term);
    if (mounted) {
      setState(() {
        _results = results;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.scaleAssignPluTitle),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(hintText: l10n.scaleAssignPluHint),
              onSubmitted: _run,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _searching
                  ? const Center(child: PointySpinner())
                  : ListView(
                      children: [
                        for (final variant in _results)
                          ListTile(
                            dense: true,
                            title: Text(variant.displayLabel),
                            subtitle: Text(variant.sku),
                            onTap: () => Navigator.of(context).pop(variant),
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
      ],
    );
  }
}

class _ScaleEditorDialog extends StatefulWidget {
  const _ScaleEditorDialog({this.scale, required this.drivers});

  final Scale? scale;
  final List<ScaleDriverInfo> drivers;

  @override
  State<_ScaleEditorDialog> createState() => _ScaleEditorDialogState();
}

class _ScaleEditorDialogState extends State<_ScaleEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _department;
  late String _driver;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final scale = widget.scale;
    _name = TextEditingController(text: scale?.name ?? '');
    _host = TextEditingController(text: scale?.host ?? '');
    _port = TextEditingController(text: '${scale?.port ?? 0}');
    _department = TextEditingController(text: '${scale?.department ?? 1}');
    _driver =
        scale?.driver ??
        (widget.drivers.isNotEmpty ? widget.drivers.first.key : 'file_export');
    _isActive = scale?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _department.dispose();
    super.dispose();
  }

  ScaleDriverInfo? get _selectedDriver {
    for (final driver in widget.drivers) {
      if (driver.key == _driver) {
        return driver;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final needsAddress = _selectedDriver?.needsAddress ?? true;
    final canSave =
        _name.text.trim().isNotEmpty &&
        (!needsAddress || _host.text.trim().isNotEmpty);

    return AlertDialog(
      title: Text(l10n.scaleEditTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: l10n.scaleNameLabel),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _driver,
                decoration: InputDecoration(labelText: l10n.scaleTypeLabel),
                items: [
                  for (final driver in widget.drivers)
                    DropdownMenuItem(
                      value: driver.key,
                      child: Text(driver.label),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _driver = value ?? _driver;
                  final port = _selectedDriver?.defaultPort ?? 0;
                  if (port > 0 && (int.tryParse(_port.text) ?? 0) == 0) {
                    _port.text = '$port';
                  }
                }),
              ),
              if (needsAddress) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _host,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: l10n.scaleHostLabel,
                          hintText: '192.168.1.50',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: l10n.scalePortLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _department,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.scaleDepartmentLabel,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isActive,
                title: Text(l10n.scaleActiveLabel),
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
          onPressed: canSave
              ? () => Navigator.of(context).pop(<String, Object?>{
                  'name': _name.text.trim(),
                  'driver': _driver,
                  'host': _host.text.trim(),
                  'port': int.tryParse(_port.text) ?? 0,
                  'department': int.tryParse(_department.text) ?? 1,
                  'is_active': _isActive,
                })
              : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
