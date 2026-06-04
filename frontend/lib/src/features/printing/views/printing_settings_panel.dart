import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/printer_config.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printing_settings_view_model.dart';

class PrintingSettingsPanel extends StatelessWidget {
  const PrintingSettingsPanel({super.key, required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final endpoint = viewModel.config.endpoint;
        final busy =
            viewModel.isTesting ||
            viewModel.isDiscovering ||
            viewModel.isSavingConfig;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDataRow(
              leading: const Icon(Icons.receipt_long_outlined),
              title: l10n.posReceiptPrinterRoleTitle,
              subtitle: l10n.posReceiptPrinterRoleDescription,
              minHeight: 72,
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
            ),
            SizedBox(height: spacing.md),
            _SelectedPrinterSummary(
              endpoint: endpoint,
              hasConfiguredPrinter: viewModel.hasConfiguredPrinter,
            ),
            SizedBox(height: spacing.md),
            _PrinterConnectionMessage(viewModel: viewModel),
            SizedBox(height: spacing.md),
            ResponsiveActionBar(
              actions: [
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => _showPrinterRoleDialog(context, viewModel),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.configurePrinterRoleButton),
                ),
                OutlinedButton.icon(
                  onPressed:
                      busy ||
                          viewModel.isCheckingConnection ||
                          !viewModel.hasConfiguredPrinter
                      ? null
                      : viewModel.checkPrinterConnection,
                  icon: viewModel.isCheckingConnection
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sensors_outlined),
                  label: Text(l10n.checkPrinterConnectionButton),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !viewModel.hasConfiguredPrinter
                      ? null
                      : viewModel.testPrinter,
                  icon: viewModel.isTesting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  label: Text(
                    viewModel.isTesting
                        ? l10n.testingPrinterButton
                        : l10n.testPrinterButton,
                  ),
                ),
              ],
            ),
            if (viewModel.hasConfigSaveError) ...[
              SizedBox(height: spacing.md),
              PointyInlineMessage.error(message: l10n.deviceSettingsSaveError),
            ],
            _PrinterTestMessage(outcome: viewModel.testOutcome),
          ],
        );
      },
    );
  }

  Future<void> _showPrinterRoleDialog(
    BuildContext context,
    PrintingSettingsViewModel viewModel,
  ) {
    return showDialog<void>(
      context: context,
      builder: (context) => _PrinterRoleDialog(viewModel: viewModel),
    );
  }
}

class _PrinterRoleDialog extends StatefulWidget {
  const _PrinterRoleDialog({required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  State<_PrinterRoleDialog> createState() => _PrinterRoleDialogState();
}

class _PrinterRoleDialogState extends State<_PrinterRoleDialog> {
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
    if (widget.viewModel.discoveredPrinters.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.viewModel.discoveredPrinters.isEmpty) {
          unawaited(widget.viewModel.discoverPrinters());
        }
      });
    }
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
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final endpoint = widget.viewModel.config.endpoint;
        final availableDialogWidth = math.max(
          280.0,
          MediaQuery.sizeOf(context).width - spacing.xl * 2,
        );
        final dialogWidth = math.min(availableDialogWidth, 560.0);
        return AlertDialog(
          title: Text(l10n.printerRoleDialogTitle),
          content: SizedBox(
            width: dialogWidth,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DiscoveredPrinterDropdown(
                    printers: widget.viewModel.discoveredPrinters,
                    selected: endpoint,
                    includeSelected: widget.viewModel.hasConfiguredPrinter,
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
                  ResponsiveFormGrid(
                    maxColumns: 2,
                    children: [
                      TextFormField(
                        controller: _paperWidthController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
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
                  _SelectedPrinterSummary(
                    endpoint: endpoint,
                    hasConfiguredPrinter: widget.viewModel.hasConfiguredPrinter,
                  ),
                  if (widget.viewModel.hasConfigSaveError) ...[
                    SizedBox(height: spacing.md),
                    PointyInlineMessage.error(
                      message: l10n.deviceSettingsSaveError,
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.printerRoleDialogDoneButton),
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

class _DiscoveredPrinterDropdown extends StatelessWidget {
  const _DiscoveredPrinterDropdown({
    required this.printers,
    required this.selected,
    required this.includeSelected,
    required this.isDiscovering,
    required this.hasDiscoveryError,
    required this.onDiscover,
    required this.onSelected,
  });

  final List<PrinterEndpoint> printers;
  final PrinterEndpoint selected;
  final bool includeSelected;
  final bool isDiscovering;
  final bool hasDiscoveryError;
  final VoidCallback? onDiscover;
  final ValueChanged<PrinterEndpoint>? onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final options = _printerOptions();
    final selectedKey = _endpointKey(selected);
    final hasSelectedPrinter = options.any(
      (printer) => _endpointKey(printer) == selectedKey,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('$selectedKey:${options.length}'),
                initialValue: hasSelectedPrinter ? selectedKey : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.discoveredPrintersLabel,
                  prefixIcon: const Icon(Icons.print_outlined),
                ),
                hint: Text(
                  options.isEmpty
                      ? l10n.noDiscoveredPrinters
                      : l10n.selectDiscoveredPrinterHint,
                ),
                items: [
                  for (final printer in options)
                    DropdownMenuItem<String>(
                      value: _endpointKey(printer),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_transportIcon(printer.kind), size: 20),
                          const SizedBox(width: 8),
                          Text(
                            _printerLabel(printer),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: onSelected == null
                    ? null
                    : (value) {
                        final printer = options
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
            child: PointyInlineMessage.error(
              message: l10n.printerDiscoveryError,
              compact: true,
            ),
          ),
      ],
    );
  }

  List<PrinterEndpoint> _printerOptions() {
    final options = <String, PrinterEndpoint>{};
    if (includeSelected) {
      options[_endpointKey(selected)] = selected;
    }
    for (final printer in printers) {
      options[_endpointKey(printer)] = printer;
    }
    return options.values.toList(growable: false);
  }
}

class _SelectedPrinterSummary extends StatelessWidget {
  const _SelectedPrinterSummary({
    required this.endpoint,
    required this.hasConfiguredPrinter,
  });

  final PrinterEndpoint endpoint;
  final bool hasConfiguredPrinter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = hasConfiguredPrinter
        ? _printerLabel(endpoint)
        : l10n.noSelectedPrinter;
    final details = hasConfiguredPrinter ? _endpointDetails(context) : '';

    return PointyDataRow(
      leading: Icon(_transportIcon(endpoint.kind)),
      title: l10n.selectedPrinterLabel,
      subtitle: details.isEmpty ? title : '$title\n$details',
      minHeight: 68,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
    );
  }

  String _endpointDetails(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch (endpoint.kind) {
      PrintTransportKind.serial =>
        '${l10n.printerTransportSerial} - ${endpoint.address}',
      PrintTransportKind.bluetooth =>
        '${l10n.printerTransportBluetooth} - ${endpoint.address}',
      PrintTransportKind.wifi =>
        endpoint.address.isEmpty
            ? l10n.printerTransportWifi
            : '${l10n.printerTransportWifi} - ${endpoint.address}:${endpoint.port}',
      PrintTransportKind.fake => l10n.printerTransportFake,
    };
  }
}

class _PrinterConnectionMessage extends StatelessWidget {
  const _PrinterConnectionMessage({required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch (viewModel.connectionState) {
      PrinterConnectionState.connected => PointyInlineMessage.success(
        message: l10n.printerStatusConnected,
        compact: true,
      ),
      PrinterConnectionState.disconnected => PointyInlineMessage.warning(
        message: l10n.printerStatusDisconnected,
        compact: true,
      ),
      PrinterConnectionState.checking => PointyInlineMessage(
        message: l10n.printerStatusChecking,
        icon: Icons.sensors_outlined,
        compact: true,
      ),
      PrinterConnectionState.notConfigured => PointyInlineMessage(
        message: l10n.printerStatusNotConfigured,
        icon: Icons.info_outline,
        compact: true,
      ),
      PrinterConnectionState.unknown => PointyInlineMessage(
        message: l10n.printerStatusUnknown,
        icon: Icons.info_outline,
        compact: true,
      ),
    };
  }
}

class _PrinterTestMessage extends StatelessWidget {
  const _PrinterTestMessage({required this.outcome});

  final PrinterTestOutcome outcome;

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

String _endpointKey(PrinterEndpoint endpoint) {
  return '${endpoint.kind.name}:${endpoint.address}:${endpoint.port}';
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

IconData _transportIcon(PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.serial => Icons.usb_outlined,
    PrintTransportKind.bluetooth => Icons.bluetooth_outlined,
    PrintTransportKind.wifi => Icons.wifi_outlined,
    PrintTransportKind.fake => Icons.science_outlined,
  };
}
