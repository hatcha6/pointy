import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/printer_config.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printing_settings_view_model.dart';

class PrintingSettingsPanel extends StatefulWidget {
  const PrintingSettingsPanel({super.key, required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  State<PrintingSettingsPanel> createState() => _PrintingSettingsPanelState();
}

class _PrintingSettingsPanelState extends State<PrintingSettingsPanel> {
  late final TextEditingController _paperWidthController;
  late final TextEditingController _codeTableController;

  @override
  void initState() {
    super.initState();
    final endpoint = widget.viewModel.config.endpoint;
    _paperWidthController = TextEditingController(
      text: '${endpoint.paperWidthMm}',
    );
    _codeTableController = TextEditingController(text: endpoint.codeTable);
  }

  @override
  void dispose() {
    _paperWidthController.dispose();
    _codeTableController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final config = widget.viewModel.config;
        final endpoint = config.endpoint;
        final spacing = AdaptiveSpacing.of(context);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.printerTransportLabel,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            SizedBox(height: spacing.sm),
            SegmentedButton<PrintTransportKind>(
              segments: [
                ButtonSegment(
                  value: PrintTransportKind.serial,
                  icon: const Icon(Icons.usb_outlined),
                  label: Text(l10n.printerTransportSerial),
                ),
                ButtonSegment(
                  value: PrintTransportKind.bluetooth,
                  icon: const Icon(Icons.bluetooth_outlined),
                  label: Text(l10n.printerTransportBluetooth),
                ),
                ButtonSegment(
                  value: PrintTransportKind.wifi,
                  icon: const Icon(Icons.wifi_outlined),
                  label: Text(l10n.printerTransportWifi),
                ),
                ButtonSegment(
                  value: PrintTransportKind.fake,
                  icon: const Icon(Icons.science_outlined),
                  label: Text(l10n.printerTransportFake),
                ),
              ],
              selected: {endpoint.kind},
              onSelectionChanged: widget.viewModel.isTesting
                  ? null
                  : (selection) {
                      widget.viewModel.updateTransportKind(selection.single);
                      _syncEndpointControllers();
                    },
            ),
            SizedBox(height: spacing.md),
            _DiscoveredPrinterPicker(
              printers: widget.viewModel.discoveredPrinters,
              selected: endpoint,
              isDiscovering: widget.viewModel.isDiscovering,
              hasDiscoveryError: widget.viewModel.hasDiscoveryError,
              onDiscover: widget.viewModel.isTesting
                  ? null
                  : widget.viewModel.discoverPrinters,
              onSelected: widget.viewModel.isTesting
                  ? null
                  : (printer) {
                      widget.viewModel.selectDiscoveredPrinter(printer);
                      _syncEndpointControllers();
                    },
            ),
            SizedBox(height: spacing.md),
            _SelectedPrinterSummary(endpoint: endpoint),
            SizedBox(height: spacing.md),
            ResponsiveFormGrid(
              maxColumns: 2,
              children: [
                TextFormField(
                  controller: _paperWidthController,
                  enabled: !widget.viewModel.isTesting,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: widget.viewModel.updatePaperWidth,
                  decoration: InputDecoration(
                    labelText: l10n.paperWidthLabel,
                    prefixIcon: const Icon(Icons.receipt_outlined),
                  ),
                ),
                TextFormField(
                  controller: _codeTableController,
                  enabled: !widget.viewModel.isTesting,
                  onChanged: widget.viewModel.updateCodeTable,
                  decoration: InputDecoration(
                    labelText: l10n.printerCodeTableLabel,
                    prefixIcon: const Icon(Icons.translate_outlined),
                  ),
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            ResponsiveActionBar(
              actions: [
                FilledButton.icon(
                  onPressed: widget.viewModel.isTesting
                      ? null
                      : widget.viewModel.testPrinter,
                  icon: widget.viewModel.isTesting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  label: Text(
                    widget.viewModel.isTesting
                        ? l10n.testingPrinterButton
                        : l10n.testPrinterButton,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: widget.viewModel.isTesting
                      ? null
                      : widget.viewModel.runFakePrint,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(l10n.fakePrintButton),
                ),
              ],
            ),
            if (widget.viewModel.hasConfigSaveError) ...[
              SizedBox(height: spacing.md),
              Text(
                l10n.deviceSettingsSaveError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            _PrinterTestMessage(
              outcome: widget.viewModel.testOutcome,
              transportKind: endpoint.kind,
            ),
          ],
        );
      },
    );
  }

  void _syncEndpointControllers() {
    final endpoint = widget.viewModel.config.endpoint;
    _setText(_paperWidthController, '${endpoint.paperWidthMm}');
    _setText(_codeTableController, endpoint.codeTable);
  }

  void _setText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }
}

class _DiscoveredPrinterPicker extends StatelessWidget {
  const _DiscoveredPrinterPicker({
    required this.printers,
    required this.selected,
    required this.isDiscovering,
    required this.hasDiscoveryError,
    required this.onDiscover,
    required this.onSelected,
  });

  final List<PrinterEndpoint> printers;
  final PrinterEndpoint selected;
  final bool isDiscovering;
  final bool hasDiscoveryError;
  final VoidCallback? onDiscover;
  final ValueChanged<PrinterEndpoint>? onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final spacing = AdaptiveSpacing.of(context);
    final selectedKey = _endpointKey(selected);
    final hasSelectedPrinter = printers.any(
      (printer) => _endpointKey(printer) == selectedKey,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: hasSelectedPrinter ? selectedKey : null,
                decoration: InputDecoration(
                  labelText: l10n.discoveredPrintersLabel,
                  prefixIcon: const Icon(Icons.manage_search_outlined),
                ),
                hint: Text(
                  printers.isEmpty
                      ? l10n.noDiscoveredPrinters
                      : l10n.selectDiscoveredPrinterHint,
                ),
                items: [
                  for (final printer in printers)
                    DropdownMenuItem<String>(
                      value: _endpointKey(printer),
                      child: Row(
                        children: [
                          Icon(_transportIcon(printer.kind), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _printerLabel(printer),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: onSelected == null
                    ? null
                    : (value) {
                        final printer = printers
                            .where((printer) => _endpointKey(printer) == value)
                            .firstOrNull;
                        if (printer != null) {
                          onSelected!(printer);
                        }
                      },
              ),
            ),
            SizedBox(width: spacing.sm),
            IconButton.filledTonal(
              tooltip: l10n.discoverPrintersButton,
              onPressed: isDiscovering ? null : onDiscover,
              icon: isDiscovering
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_outlined),
            ),
          ],
        ),
        if (hasDiscoveryError)
          Padding(
            padding: EdgeInsets.only(top: spacing.sm),
            child: Text(
              l10n.printerDiscoveryError,
              style: TextStyle(color: colorScheme.error),
            ),
          ),
      ],
    );
  }

  String _printerLabel(PrinterEndpoint printer) {
    final name = printer.name.trim().isEmpty ? printer.address : printer.name;
    final details = switch (printer.kind) {
      PrintTransportKind.serial => printer.address,
      PrintTransportKind.bluetooth => printer.address,
      PrintTransportKind.wifi => '${printer.address}:${printer.port}',
      PrintTransportKind.fake => printer.address,
    };
    if (details.isEmpty || details == name) {
      return name;
    }
    return '$name - $details';
  }
}

class _SelectedPrinterSummary extends StatelessWidget {
  const _SelectedPrinterSummary({required this.endpoint});

  final PrinterEndpoint endpoint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = endpoint.name.trim().isEmpty
        ? l10n.noSelectedPrinter
        : endpoint.name.trim();
    final details = _endpointDetails(endpoint);

    return PointyDataRow(
      leading: Icon(_transportIcon(endpoint.kind)),
      title: l10n.selectedPrinterLabel,
      subtitle: details.isEmpty ? name : '$name\n$details',
      minHeight: 68,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
    );
  }

  String _endpointDetails(PrinterEndpoint endpoint) {
    return switch (endpoint.kind) {
      PrintTransportKind.serial => endpoint.address,
      PrintTransportKind.bluetooth => endpoint.address,
      PrintTransportKind.wifi =>
        endpoint.address.isEmpty ? '' : '${endpoint.address}:${endpoint.port}',
      PrintTransportKind.fake => endpoint.address,
    };
  }
}

String _endpointKey(PrinterEndpoint endpoint) {
  return '${endpoint.kind.name}:${endpoint.address}:${endpoint.port}';
}

IconData _transportIcon(PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.serial => Icons.usb_outlined,
    PrintTransportKind.bluetooth => Icons.bluetooth_outlined,
    PrintTransportKind.wifi => Icons.wifi_outlined,
    PrintTransportKind.fake => Icons.science_outlined,
  };
}

class _PrinterTestMessage extends StatelessWidget {
  const _PrinterTestMessage({
    required this.outcome,
    required this.transportKind,
  });

  final PrinterTestOutcome outcome;
  final PrintTransportKind transportKind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final (message, color) = switch (outcome) {
      PrinterTestOutcome.none => (null, null),
      PrinterTestOutcome.success => (
        l10n.printerTestSuccess,
        colorScheme.primary,
      ),
      PrinterTestOutcome.failed => (l10n.printerTestFailure, colorScheme.error),
      PrinterTestOutcome.fakeSuccess => (
        l10n.fakePrintSuccess,
        colorScheme.primary,
      ),
      PrinterTestOutcome.fakeFailed => (
        l10n.fakePrintFailure,
        colorScheme.error,
      ),
    };

    if (message == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: PointyStatusPill(label: message, color: color),
      ),
    );
  }
}
