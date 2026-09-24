import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/device_printers.dart';
import '../../../data/models/prep_station.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/order/pointy_order_toggle_row.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printer_editor_view_model.dart';
import '../view_models/printing_settings_view_model.dart';
import 'printer_device_picker.dart';
import 'printer_label_settings.dart';
import 'printer_presentation.dart';
import 'printer_receipt_settings.dart';

enum PrinterEditorAction { added, saved, removed }

class PrinterEditorOutcome {
  const PrinterEditorOutcome(this.action, this.printer);

  final PrinterEditorAction action;
  final DevicePrinter printer;
}

/// Opens the printer editor: a new printer when [printer] is null. Resolves
/// to what happened, or null when it was closed without a change.
Future<PrinterEditorOutcome?> showPrinterEditor(
  BuildContext context, {
  required PrintingSettingsViewModel settings,
  DevicePrinter? printer,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<PrinterEditorOutcome>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.94,
    title: printer == null ? l10n.addPrinterTitle : l10n.editPrinterTitle,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: PrinterEditorSheet(settings: settings, printer: printer),
    ),
  );
}

/// Asks before a printer goes, naming the jobs that will be left without one.
Future<bool> confirmPrinterRemoval(
  BuildContext context,
  PrintingSettingsViewModel settings,
  DevicePrinter printer,
) async {
  final l10n = AppLocalizations.of(context)!;
  final stationNames = {
    for (final station in settings.kitchenStations) station.id: station.name,
  };
  final jobs = printerJobBadges(
    l10n,
    printer,
    stationNames,
  ).map((job) => job.label).join('، ');
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => PointyDestructiveConfirmationDialog(
      title: l10n.removePrinterTitle(printerDisplayName(l10n, printer)),
      message: jobs.isEmpty
          ? l10n.removePrinterMessage
          : l10n.removePrinterJobsMessage(jobs),
      confirmLabel: l10n.removePrinterConfirm,
      icon: Icons.print_disabled_outlined,
    ),
  );
  return confirmed ?? false;
}

class PrinterEditorSheet extends StatefulWidget {
  const PrinterEditorSheet({super.key, required this.settings, this.printer});

  final PrintingSettingsViewModel settings;
  final DevicePrinter? printer;

  @override
  State<PrinterEditorSheet> createState() => _PrinterEditorSheetState();
}

class _PrinterEditorSheetState extends State<PrinterEditorSheet> {
  late final PrinterEditorViewModel _editor;
  late final TextEditingController _labelController;

  @override
  void initState() {
    super.initState();
    _editor = PrinterEditorViewModel(widget.settings, printer: widget.printer);
    _labelController = TextEditingController(text: widget.printer?.label ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editor.start();
      }
    });
  }

  @override
  void dispose() {
    _editor.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    if (!await _editor.save() || !mounted) {
      return;
    }
    navigator.pop(
      PrinterEditorOutcome(
        _editor.isNew ? PrinterEditorAction.added : PrinterEditorAction.saved,
        _editor.draft,
      ),
    );
  }

  Future<void> _remove() async {
    final printer = widget.printer;
    if (printer == null) {
      return;
    }
    final navigator = Navigator.of(context);
    if (!await confirmPrinterRemoval(context, widget.settings, printer)) {
      return;
    }
    if (await widget.settings.removePrinter(printer.id) && mounted) {
      navigator.pop(PrinterEditorOutcome(PrinterEditorAction.removed, printer));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    // The save path pops with an explicit Navigator.pop, which the guard does
    // not intercept — so saving still closes normally.
    return PointyUnsavedChangesGuard(
      isDirty: () => _editor.isDirty && !_editor.isSaving,
      child: ListenableBuilder(
        listenable: Listenable.merge([_editor, widget.settings]),
        builder: (context, _) {
          final hasDevice = _editor.hasDevice;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    spacing.md,
                    spacing.sm,
                    spacing.md,
                    spacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PrinterDevicePicker(editor: _editor),
                      SizedBox(height: spacing.md),
                      TextField(
                        key: const ValueKey('printer_name_field'),
                        controller: _labelController,
                        onChanged: _editor.setLabel,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: l10n.printerNameLabel,
                          helperText: l10n.printerNameHelper,
                          hintText: hasDevice
                              ? printerDeviceName(l10n, _editor.endpoint)
                              : null,
                          prefixIcon: const Icon(Icons.badge_outlined),
                        ),
                      ),
                      SizedBox(height: spacing.lg),
                      _PrinterJobsSection(editor: _editor),
                      if (hasDevice && _editor.showsReceiptSettings) ...[
                        SizedBox(height: spacing.lg),
                        PrinterReceiptSettings(
                          key: ValueKey(
                            'receipt_settings_${_editor.deviceGeneration}',
                          ),
                          editor: _editor,
                        ),
                      ],
                      if (hasDevice && _editor.showsLabelSettings) ...[
                        SizedBox(height: spacing.lg),
                        PrinterLabelSettings(
                          key: ValueKey(
                            'label_settings_${_editor.deviceGeneration}',
                          ),
                          editor: _editor,
                        ),
                      ],
                      SizedBox(height: spacing.lg),
                      _PrinterTestSection(editor: _editor),
                      if (!_editor.isNew) ...[
                        SizedBox(height: spacing.lg),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            key: const ValueKey('printer_remove_button'),
                            onPressed: _editor.isSaving ? null : _remove,
                            style: TextButton.styleFrom(
                              foregroundColor: context.pointyColors.danger,
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: Text(l10n.removePrinterConfirm),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              PointyStickyActionFooter(
                summary: _editor.hasSaveError
                    ? PointyInlineMessage.error(
                        message: l10n.deviceSettingsSaveError,
                        compact: true,
                      )
                    : null,
                secondaryActions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(l10n.cancelButton),
                  ),
                ],
                primaryAction: FilledButton.icon(
                  key: const ValueKey('printer_save_button'),
                  onPressed: _editor.canSave ? _save : null,
                  icon: _editor.isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : Icon(_editor.isNew ? Icons.add : Icons.check),
                  label: Text(
                    _editor.isNew
                        ? l10n.addPrinterConfirmButton
                        : l10n.saveButton,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What this printer prints: each job with what it covers, where it prints
/// now, and — when ticking it would take it from another printer — that it
/// moves.
class _PrinterJobsSection extends StatelessWidget {
  const _PrinterJobsSection({required this.editor});

  final PrinterEditorViewModel editor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final draft = editor.draft;
    final stations = editor.settings.kitchenStations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.printerJobsSectionTitle),
        for (final role in PrinterRole.values) ...[
          _JobOption(
            key: ValueKey('printer_job_${printerRoleToJson(role)}'),
            icon: printerRoleIcon(role),
            title: printerRoleTitle(l10n, role),
            selected: draft.holds(role),
            enabled: editor.canTake(role),
            note: _roleNote(l10n, role),
            onChanged: (selected) => editor.setRole(role, selected),
          ),
          SizedBox(height: spacing.sm),
        ],
        if (stations.isNotEmpty) ...[
          SizedBox(height: spacing.xs),
          Text(
            l10n.printerKitchenStationsLabel,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: spacing.sm),
          for (final station in stations) ...[
            _JobOption(
              key: ValueKey('printer_job_kitchen_${station.id}'),
              icon: kitchenStationIcon,
              title: l10n.printerRoleKitchen(station.name),
              selected: draft.servesKitchenStation(station.id),
              enabled: editor.canTakeKitchen,
              note: _stationNote(l10n, station),
              onChanged: (selected) =>
                  editor.setKitchenStation(station.id, selected),
            ),
            SizedBox(height: spacing.sm),
          ],
        ],
        if (!draft.hasJobs)
          PointyInlineMessage(
            key: const ValueKey('printer_no_jobs_message'),
            message: l10n.printerJobsNoneSelected,
            compact: true,
          ),
      ],
    );
  }

  _JobNote _roleNote(AppLocalizations l10n, PrinterRole role) {
    if (!editor.canTake(role)) {
      return _JobNote(l10n.printerJobDocumentsNeedsPdf);
    }
    final other = editor.otherHolderOf(role);
    if (other == null) {
      return _JobNote(printerRoleDescription(l10n, role));
    }
    final otherName = printerDisplayName(l10n, other);
    return editor.draft.holds(role)
        ? _JobNote(
            l10n.printerJobMovesFrom(printerRoleTitle(l10n, role), otherName),
            warns: true,
          )
        : _JobNote(l10n.printerJobCurrentlyOn(otherName));
  }

  _JobNote _stationNote(AppLocalizations l10n, PrepStation station) {
    if (!editor.canTakeKitchen) {
      return _JobNote(l10n.printerJobKitchenNeedsThermal);
    }
    final other = editor.otherKitchenPrinterFor(station.id);
    if (other == null) {
      return _JobNote(l10n.printerRoleKitchenDescription);
    }
    final otherName = printerDisplayName(l10n, other);
    return editor.draft.servesKitchenStation(station.id)
        ? _JobNote(
            l10n.printerJobMovesFrom(
              l10n.printerRoleKitchen(station.name),
              otherName,
            ),
            warns: true,
          )
        : _JobNote(l10n.printerJobCurrentlyOn(otherName));
  }
}

class _JobNote {
  const _JobNote(this.text, {this.warns = false});

  final String text;
  final bool warns;
}

/// One job as a selectable card, drawn like the device-usage choices on the
/// same settings screen.
class _JobOption extends StatelessWidget {
  const _JobOption({
    super.key,
    required this.icon,
    required this.title,
    required this.selected,
    required this.enabled,
    required this.note,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final bool enabled;
  final _JobNote note;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);

    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.35)
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: selected ? colors.primaryStrong : colors.line),
      ),
      child: InkWell(
        onTap: enabled ? () => onChanged(!selected) : null,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Padding(
          padding: EdgeInsetsDirectional.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: enabled ? colors.primaryStrong : colors.mutedInk,
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: enabled ? colors.ink : colors.mutedInk,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note.text,
                      style: textTheme.bodySmall?.copyWith(
                        color: note.warns ? colors.warning : colors.mutedInk,
                        fontWeight: note.warns ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              PointyCheckBox(value: selected, enabled: enabled),
            ],
          ),
        ),
      ),
    );
  }
}

/// A test print per job, run on the draft — so a printer is proven before it
/// is saved, not after the first receipt fails to come out.
class _PrinterTestSection extends StatelessWidget {
  const _PrinterTestSection({required this.editor});

  final PrinterEditorViewModel editor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final lastTest = editor.lastTest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.printerTestSectionTitle),
        if (!editor.hasDevice)
          PointyInlineMessage(
            message: l10n.printerTestNeedsDevice,
            compact: true,
          )
        else ...[
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.sm,
            children: [
              for (final kind in editor.availableTests)
                OutlinedButton.icon(
                  key: ValueKey('printer_editor_test_${kind.name}'),
                  onPressed: editor.isBusy ? null : () => editor.runTest(kind),
                  icon: editor.runningTest == kind
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : Icon(printerTestIcon(kind), size: 18),
                  label: Text(printerTestButtonLabel(l10n, kind)),
                ),
            ],
          ),
          if (lastTest != null) ...[
            SizedBox(height: spacing.sm),
            lastTest.isSuccess
                ? PointyInlineMessage.success(
                    key: const ValueKey('printer_editor_test_result'),
                    message: printerTestResultMessage(l10n, lastTest),
                    compact: true,
                  )
                : PointyInlineMessage.error(
                    key: const ValueKey('printer_editor_test_result'),
                    message: printerTestResultMessage(l10n, lastTest),
                    compact: true,
                  ),
          ],
        ],
      ],
    );
  }
}
