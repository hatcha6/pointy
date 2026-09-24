import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/device_printers.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printing_settings_view_model.dart';
import 'printer_editor_sheet.dart';
import 'printer_presentation.dart';

/// The printers on this device and the job each one does.
///
/// Two views of one thing. "What prints where" answers the question a shop
/// actually has — where does a label go? — and changes it in one tap. The
/// printer cards below manage the hardware: which device, is it answering,
/// does it print.
class PrintersPanel extends StatefulWidget {
  const PrintersPanel({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PrintingSettingsViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  State<PrintersPanel> createState() => _PrintersPanelState();
}

class _PrintersPanelState extends State<PrintersPanel> {
  bool _checkedOnOpen = false;

  PrintingSettingsViewModel get _viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel.addListener(_checkOnceLoaded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        _viewModel.loadKitchenStations(
          allowed: widget.capabilities.canViewPrepStations,
        ),
      );
      _checkOnceLoaded();
    });
  }

  @override
  void dispose() {
    _viewModel.removeListener(_checkOnceLoaded);
    super.dispose();
  }

  /// Asks every printer how it is, once, when the screen opens — as soon as
  /// the list is there to ask. The background watch covers only the receipt
  /// printer, and opening this screen is the moment someone wants to know
  /// about the rest.
  void _checkOnceLoaded() {
    if (_checkedOnOpen || !mounted || _viewModel.isLoading) {
      return;
    }
    _checkedOnOpen = true;
    unawaited(_viewModel.checkAllConnections());
  }

  Future<void> _openEditor({DevicePrinter? printer}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showPrinterEditor(
      context,
      settings: _viewModel,
      printer: printer,
    );
    if (outcome == null || !mounted) {
      return;
    }
    final name = printerDisplayName(l10n, outcome.printer);
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (outcome.action) {
          PrinterEditorAction.added => l10n.printerAddedMessage(name),
          PrinterEditorAction.saved => l10n.printerSavedMessage(name),
          PrinterEditorAction.removed => l10n.printerRemovedMessage(name),
        }),
      ),
    );
  }

  Future<void> _remove(DevicePrinter printer) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmPrinterRemoval(context, _viewModel, printer)) {
      return;
    }
    if (await _viewModel.removePrinter(printer.id) && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.printerRemovedMessage(printerDisplayName(l10n, printer)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final printers = _viewModel.printers.printers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.printersSectionHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
            SizedBox(height: spacing.md),
            if (_viewModel.hasLoadError) ...[
              PointyInlineMessage.error(message: l10n.deviceSettingsLoadError),
              SizedBox(height: spacing.md),
            ],
            if (printers.isEmpty)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: context.pointyColors.line),
                  borderRadius: BorderRadius.circular(PointyRadii.card),
                ),
                child: PointyEmptyState(
                  key: const ValueKey('printers_empty_state'),
                  icon: Icons.print_outlined,
                  title: l10n.printersEmptyTitle,
                  message: l10n.printersEmptyMessage,
                  action: FilledButton.icon(
                    key: const ValueKey('printers_empty_add_button'),
                    onPressed: _viewModel.isLoading ? null : _openEditor,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addPrinterButton),
                  ),
                ),
              )
            else ...[
              _PrintJobsCard(viewModel: _viewModel),
              SizedBox(height: spacing.lg),
              PointySectionHeader(
                title: l10n.printersListTitle,
                trailing: FilledButton.tonalIcon(
                  key: const ValueKey('printers_add_button'),
                  onPressed: _openEditor,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addPrinterButton),
                ),
              ),
              for (final printer in printers) ...[
                _PrinterCard(
                  printer: printer,
                  viewModel: _viewModel,
                  onEdit: () => _openEditor(printer: printer),
                  onRemove: () => _remove(printer),
                ),
                SizedBox(height: spacing.sm),
              ],
            ],
            if (_viewModel.hasSaveError) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(message: l10n.deviceSettingsSaveError),
            ],
          ],
        );
      },
    );
  }
}

/// "What prints where": every job, and the printer that does it.
class _PrintJobsCard extends StatelessWidget {
  const _PrintJobsCard({required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final stations = viewModel.kitchenStations;

    return Column(
      key: const ValueKey('print_jobs_card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.printerJobsTitle),
        for (final role in PrinterRole.values) ...[
          _PrintJobRow(
            key: ValueKey('print_job_${printerRoleToJson(role)}'),
            icon: printerRoleIcon(role),
            title: printerRoleTitle(l10n, role),
            description: printerRoleDescription(l10n, role),
            unassignedMessage: printerRoleUnassigned(l10n, role),
            unassignedIsWarning: printerRoleUnassignedIsWarning(role),
            holder: viewModel.holderOf(role),
            printers: viewModel.printers.printers,
            canServe: (printer) => printer.endpoint.canServe(role),
            incompatibleReason: l10n.printerAssignNeedsDocumentPrinter,
            enabled: !viewModel.isSaving,
            onChanged: (printerId) => viewModel.assignRole(role, printerId),
          ),
          SizedBox(height: spacing.sm),
        ],
        for (final station in stations) ...[
          _PrintJobRow(
            key: ValueKey('print_job_kitchen_${station.id}'),
            icon: kitchenStationIcon,
            title: l10n.printerRoleKitchen(station.name),
            description: l10n.printerRoleKitchenDescription,
            unassignedMessage: l10n.printerRoleKitchenUnassigned,
            unassignedIsWarning: false,
            holder: viewModel.kitchenPrinterFor(station.id),
            printers: viewModel.printers.printers,
            canServe: (printer) => printer.endpoint.canServeKitchen,
            incompatibleReason: l10n.printerAssignNeedsThermalPrinter,
            enabled: !viewModel.isSaving,
            onChanged: (printerId) =>
                viewModel.assignKitchenStation(station.id, printerId),
          ),
          SizedBox(height: spacing.sm),
        ],
        if (viewModel.kitchenStationsState == KitchenStationsState.failed)
          PointyInlineMessage.error(
            message: l10n.kitchenPrintersLoadError,
            compact: true,
          ),
      ],
    );
  }
}

/// One job and the printer that does it, changeable in place.
class _PrintJobRow extends StatelessWidget {
  const _PrintJobRow({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.unassignedMessage,
    required this.unassignedIsWarning,
    required this.holder,
    required this.printers,
    required this.canServe,
    required this.incompatibleReason,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String description;
  final String unassignedMessage;
  final bool unassignedIsWarning;
  final DevicePrinter? holder;
  final List<DevicePrinter> printers;
  final bool Function(DevicePrinter printer) canServe;
  final String incompatibleReason;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    final heading = Row(
      children: [
        Icon(icon, size: 20, color: colors.primaryStrong),
        SizedBox(width: spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final picker = DropdownButtonFormField<String?>(
      // Keyed on the holder so a change made elsewhere — the editor, the
      // other rows — shows here instead of the field keeping its first value.
      key: ValueKey('print_job_picker_${holder?.id}_${printers.length}'),
      initialValue: holder?.id,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        // "Nobody" stays first and stays reachable: a till can be told to
        // leave a job alone, and taking it back must be one tap.
        DropdownMenuItem<String?>(
          value: null,
          child: Text(
            l10n.printerAssignNone,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.mutedInk),
          ),
        ),
        for (final printer in printers)
          DropdownMenuItem<String?>(
            value: printer.id,
            enabled: canServe(printer),
            child: _PrinterMenuLabel(
              printer: printer,
              disabledReason: canServe(printer) ? null : incompatibleReason,
            ),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Side by side once the job's name and a printer's name both
                // fit on one line — the form is never tablet-wide.
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heading,
                      SizedBox(height: spacing.sm),
                      picker,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: heading),
                    SizedBox(width: spacing.md),
                    SizedBox(width: 260, child: picker),
                  ],
                );
              },
            ),
            if (holder == null) ...[
              SizedBox(height: spacing.xs),
              unassignedIsWarning
                  ? PointyInlineMessage.warning(
                      message: unassignedMessage,
                      compact: true,
                    )
                  : PointyInlineMessage(
                      message: unassignedMessage,
                      compact: true,
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A printer as a menu item: its name, and why it cannot take the job when
/// it cannot.
class _PrinterMenuLabel extends StatelessWidget {
  const _PrinterMenuLabel({required this.printer, this.disabledReason});

  final DevicePrinter printer;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final disabled = disabledReason != null;
    final name = printerDisplayName(l10n, printer);

    return Row(
      children: [
        Icon(
          printerTransportIcon(printer.endpoint.kind),
          size: 18,
          color: disabled ? colors.mutedInk : colors.primaryStrong,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            disabled ? '$name — $disabledReason' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: disabled ? TextStyle(color: colors.mutedInk) : null,
          ),
        ),
      ],
    );
  }
}

/// A printer on this device: the device behind it, whether it is answering,
/// and the jobs it does.
class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.printer,
    required this.viewModel,
    required this.onEdit,
    required this.onRemove,
  });

  final DevicePrinter printer;
  final PrintingSettingsViewModel viewModel;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final state = viewModel.connectionOf(printer.id);
    final testResult = viewModel.testResultOf(printer.id);
    final stationNames = {
      for (final station in viewModel.kitchenStations) station.id: station.name,
    };
    final jobs = printerJobBadges(l10n, printer, stationNames);

    return PointyDataRow(
      key: ValueKey('printer_card_${printer.id}'),
      leading: PrinterAvatar(endpoint: printer.endpoint, state: state),
      title: printerDisplayName(l10n, printer),
      subtitle:
          '${printerConnectionLine(l10n, printer.endpoint, withName: printer.label.trim().isNotEmpty)}\n'
          '${printerOutputSummary(l10n, printer.endpoint)}',
      onTap: onEdit,
      trailing: PointyStatusPill(
        label: printerConnectionLabel(l10n, state),
        color: printerConnectionColor(colors, state),
      ),
      badges: [
        if (jobs.isEmpty)
          PointyStatusPill(
            label: l10n.printerNoJobs,
            icon: Icons.do_not_disturb_on_outlined,
            color: colors.mutedInk,
          )
        else
          for (final job in jobs)
            PointyStatusPill(label: job.label, icon: job.icon),
        if (testResult != null)
          PointyStatusPill(
            key: ValueKey('printer_test_result_${printer.id}'),
            label: testResult.isSuccess
                ? l10n.printerTestPassedShort
                : l10n.printerTestFailedShort,
            icon: testResult.isSuccess
                ? Icons.check_circle_outline
                : Icons.error_outline,
            color: testResult.isSuccess ? colors.success : colors.danger,
          ),
      ],
      actions: [
        _PrinterTestButton(printer: printer, viewModel: viewModel),
        PopupMenuButton<_PrinterAction>(
          key: ValueKey('printer_menu_${printer.id}'),
          tooltip: l10n.printerMoreActionsTooltip,
          onSelected: (action) {
            switch (action) {
              case _PrinterAction.edit:
                onEdit();
              case _PrinterAction.check:
                unawaited(viewModel.checkConnection(printer.id));
              case _PrinterAction.remove:
                onRemove();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _PrinterAction.edit,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.printerEditAction),
              ),
            ),
            PopupMenuItem(
              value: _PrinterAction.check,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sensors_outlined),
                title: Text(l10n.checkPrinterConnectionButton),
              ),
            ),
            PopupMenuItem(
              value: _PrinterAction.remove,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline, color: colors.danger),
                title: Text(
                  l10n.printerRemoveAction,
                  style: TextStyle(color: colors.danger),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _PrinterAction { edit, check, remove }

/// The card's test print. A printer with one job tests it in one tap; one
/// with several asks which job to test. The old single printer did receipts
/// and labels, and carries both over. A shop that only ever used it for
/// labels is then offered a receipt test first, and a receipt page on a label
/// roll is the wrong thing to feed it.
class _PrinterTestButton extends StatelessWidget {
  const _PrinterTestButton({required this.printer, required this.viewModel});

  final DevicePrinter printer;
  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final testing = viewModel.isTesting(printer.id);
    final kinds = printerTestKinds(printer);
    final icon = testing
        ? const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          )
        : const Icon(Icons.print_outlined, size: 18);

    if (kinds.length < 2) {
      return OutlinedButton.icon(
        key: ValueKey('printer_test_${printer.id}'),
        onPressed: testing ? null : () => viewModel.testPrinter(printer.id),
        icon: icon,
        label: Text(l10n.printerTestButton),
      );
    }
    return MenuAnchor(
      builder: (context, controller, _) => OutlinedButton.icon(
        key: ValueKey('printer_test_${printer.id}'),
        onPressed: testing
            ? null
            : (controller.isOpen ? controller.close : controller.open),
        icon: icon,
        // Says there is a choice behind this before it is pressed.
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.printerTestButton),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
      menuChildren: [
        for (final kind in kinds)
          MenuItemButton(
            key: ValueKey('printer_test_${printer.id}_${kind.name}'),
            onPressed: () => viewModel.testPrinter(printer.id, kind: kind),
            leadingIcon: Icon(printerTestIcon(kind), size: 20),
            child: Text(printerTestButtonLabel(l10n, kind)),
          ),
      ],
    );
  }
}
