import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/prep_station.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/repositories/prep_station_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
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
            viewModel.isDetectingBarcodeLabelLanguage ||
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
                  icon:
                      viewModel.isTesting &&
                          !viewModel.isTestingBarcodeLabelPrinter
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  label: Text(
                    viewModel.isTesting &&
                            !viewModel.isTestingBarcodeLabelPrinter
                        ? l10n.testingPrinterButton
                        : l10n.testPrinterButton,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !viewModel.hasConfiguredPrinter
                      ? null
                      : viewModel.testBarcodeLabelPrinter,
                  icon: viewModel.isTestingBarcodeLabelPrinter
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.label_outline),
                  label: Text(
                    viewModel.isTestingBarcodeLabelPrinter
                        ? l10n.testingBarcodeLabelPrinterButton
                        : l10n.testBarcodeLabelPrinterButton,
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

/// Lists the shop's prep stations and lets this device bind a thermal printer
/// to each station it serves, reusing the same endpoint editor as the receipt
/// printer. A device only prints chits for stations configured here.
class KitchenPrintersPanel extends StatefulWidget {
  const KitchenPrintersPanel({
    super.key,
    required this.printingRepository,
    required this.prepStationRepository,
    this.analyticsEngine,
  });

  final PrintingRepository printingRepository;
  final PrepStationRepository prepStationRepository;
  final AnalyticsEngine? analyticsEngine;

  @override
  State<KitchenPrintersPanel> createState() => _KitchenPrintersPanelState();
}

class _KitchenPrintersPanelState extends State<KitchenPrintersPanel> {
  bool _isLoading = true;
  bool _hasError = false;
  List<PrepStation> _stations = const [];
  Map<int, PrinterConfig> _configs = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final stationsResult = await widget.prepStationRepository.loadStations();
    final configs = await widget.printingRepository.loadKitchenStationConfigs();
    if (!mounted) {
      return;
    }
    switch (stationsResult) {
      case Ok<List<PrepStation>>():
        setState(() {
          _stations = stationsResult.value
              .where((station) => station.isActive)
              .toList(growable: false);
          _configs = configs;
          _isLoading = false;
        });
      case Error<List<PrepStation>>():
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
    }
  }

  Future<void> _configure(PrepStation station) async {
    final viewModel = PrintingSettingsViewModel(
      widget.printingRepository,
      analyticsEngine: widget.analyticsEngine,
      role: PrinterRole.kitchen,
      stationId: station.id,
    );
    await showDialog<void>(
      context: context,
      builder: (context) => _PrinterRoleDialog(viewModel: viewModel),
    );
    viewModel.dispose();
    await _load();
  }

  Future<void> _test(PrepStation station) async {
    final config = _configs[station.id];
    if (config == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.printingRepository.printKitchenTest(config);
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess ? l10n.printerTestSuccess : l10n.printerTestFailure,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_hasError) {
      return PointyInlineMessage.error(message: l10n.kitchenPrintersLoadError);
    }
    if (_stations.isEmpty) {
      return PointyInlineMessage(
        message: l10n.kitchenPrintersNoStations,
        icon: Icons.info_outline,
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _stations.length; index += 1) ...[
          if (index > 0) SizedBox(height: spacing.sm),
          _KitchenStationPrinterTile(
            station: _stations[index],
            config: _configs[_stations[index].id],
            onConfigure: () => _configure(_stations[index]),
            onTest: _configs[_stations[index].id] == null
                ? null
                : () => _test(_stations[index]),
          ),
        ],
      ],
    );
  }
}

class _KitchenStationPrinterTile extends StatelessWidget {
  const _KitchenStationPrinterTile({
    required this.station,
    required this.config,
    required this.onConfigure,
    required this.onTest,
  });

  final PrepStation station;
  final PrinterConfig? config;
  final VoidCallback onConfigure;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final endpoint = config?.endpoint;
    final summary = endpoint == null
        ? l10n.kitchenStationNotConfigured
        : _printerLabel(endpoint, l10n);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                endpoint == null
                    ? Icons.print_disabled_outlined
                    : _transportIcon(endpoint.kind),
              ),
              title: Text(station.name),
              subtitle: Text(summary),
            ),
            ResponsiveActionBar(
              actions: [
                FilledButton.icon(
                  onPressed: onConfigure,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.configurePrinterRoleButton),
                ),
                OutlinedButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.print_outlined),
                  label: Text(l10n.testPrinterButton),
                ),
              ],
            ),
          ],
        ),
      ),
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
  late final TextEditingController _capabilityProfileController;
  late final TextEditingController _feedLinesController;
  late final TextEditingController _labelWidthController;
  late final TextEditingController _labelHeightController;
  late final TextEditingController _labelGapController;
  late final TextEditingController _labelDpiController;

  @override
  void initState() {
    super.initState();
    final endpoint = widget.viewModel.config.endpoint;
    _paperWidthController = TextEditingController(
      text: '${endpoint.paperWidthMm}',
    );
    _codeTableController = TextEditingController(text: endpoint.codeTable);
    _capabilityProfileController = TextEditingController(
      text: endpoint.capabilityProfile,
    );
    _feedLinesController = TextEditingController(text: '${endpoint.feedLines}');
    _labelWidthController = TextEditingController(
      text: '${endpoint.labelWidthMm}',
    );
    _labelHeightController = TextEditingController(
      text: '${endpoint.labelHeightMm}',
    );
    _labelGapController = TextEditingController(text: '${endpoint.labelGapMm}');
    _labelDpiController = TextEditingController(text: '${endpoint.labelDpi}');
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
    _capabilityProfileController.dispose();
    _feedLinesController.dispose();
    _labelWidthController.dispose();
    _labelHeightController.dispose();
    _labelGapController.dispose();
    _labelDpiController.dispose();
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
                      TextFormField(
                        controller: _capabilityProfileController,
                        enabled: !widget.viewModel.isTesting,
                        onChanged: widget.viewModel.updateCapabilityProfile,
                        decoration: InputDecoration(
                          labelText: l10n.printerCapabilityProfileLabel,
                          helperText: l10n.printerCapabilityProfileHelper,
                          prefixIcon: const Icon(Icons.tune_outlined),
                        ),
                      ),
                      DropdownButtonFormField<ReceiptCutMode>(
                        key: ValueKey(endpoint.cutMode),
                        initialValue: endpoint.cutMode,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.printerCutModeLabel,
                          prefixIcon: const Icon(Icons.content_cut_outlined),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: ReceiptCutMode.partial,
                            child: Text(l10n.printerCutModePartial),
                          ),
                          DropdownMenuItem(
                            value: ReceiptCutMode.full,
                            child: Text(l10n.printerCutModeFull),
                          ),
                          DropdownMenuItem(
                            value: ReceiptCutMode.none,
                            child: Text(l10n.printerCutModeNone),
                          ),
                        ],
                        onChanged: widget.viewModel.isTesting
                            ? null
                            : (mode) {
                                if (mode != null) {
                                  widget.viewModel.updateCutMode(mode);
                                }
                              },
                      ),
                      TextFormField(
                        controller: _feedLinesController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: widget.viewModel.updateFeedLines,
                        decoration: InputDecoration(
                          labelText: l10n.printerFeedLinesLabel,
                          helperText: l10n.printerFeedLinesHelper,
                          prefixIcon: const Icon(Icons.density_medium_outlined),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: spacing.md),
                  Text(
                    l10n.barcodeLabelPrinterSettingsTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  SizedBox(height: spacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child:
                            DropdownButtonFormField<
                              BarcodeLabelPrinterLanguage
                            >(
                              key: ValueKey(endpoint.barcodeLabelLanguage),
                              initialValue: endpoint.barcodeLabelLanguage,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText:
                                    l10n.printerBarcodeLabelLanguageLabel,
                                prefixIcon: const Icon(Icons.label_outline),
                              ),
                              items: [
                                for (final language
                                    in BarcodeLabelPrinterLanguage.values)
                                  DropdownMenuItem(
                                    value: language,
                                    child: Text(
                                      _barcodeLabelLanguageLabel(
                                        l10n,
                                        language,
                                      ),
                                    ),
                                  ),
                              ],
                              onChanged: widget.viewModel.isTesting
                                  ? null
                                  : (language) {
                                      if (language != null) {
                                        widget.viewModel
                                            .updateBarcodeLabelLanguage(
                                              language,
                                            );
                                      }
                                    },
                            ),
                      ),
                      SizedBox(width: spacing.sm),
                      IconButton.filledTonal(
                        tooltip: l10n.detectBarcodeLabelLanguageButton,
                        onPressed:
                            widget.viewModel.isTesting ||
                                widget
                                    .viewModel
                                    .isDetectingBarcodeLabelLanguage ||
                                !widget.viewModel.hasConfiguredPrinter
                            ? null
                            : widget.viewModel.detectBarcodeLabelLanguage,
                        icon: widget.viewModel.isDetectingBarcodeLabelLanguage
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_fix_high_outlined),
                      ),
                    ],
                  ),
                  _BarcodeLabelLanguageDetectionMessage(
                    viewModel: widget.viewModel,
                  ),
                  SizedBox(height: spacing.md),
                  ResponsiveFormGrid(
                    maxColumns: 4,
                    children: [
                      TextFormField(
                        controller: _labelWidthController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: widget.viewModel.updateLabelWidth,
                        decoration: InputDecoration(
                          labelText: l10n.printerLabelWidthLabel,
                          prefixIcon: const Icon(Icons.width_normal_outlined),
                        ),
                      ),
                      TextFormField(
                        controller: _labelHeightController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: widget.viewModel.updateLabelHeight,
                        decoration: InputDecoration(
                          labelText: l10n.printerLabelHeightLabel,
                          prefixIcon: const Icon(Icons.height_outlined),
                        ),
                      ),
                      TextFormField(
                        controller: _labelGapController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: widget.viewModel.updateLabelGap,
                        decoration: InputDecoration(
                          labelText: l10n.printerLabelGapLabel,
                          prefixIcon: const Icon(Icons.space_bar_outlined),
                        ),
                      ),
                      TextFormField(
                        controller: _labelDpiController,
                        enabled: !widget.viewModel.isTesting,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: widget.viewModel.updateLabelDpi,
                        decoration: InputDecoration(
                          labelText: l10n.printerLabelDpiLabel,
                          prefixIcon: const Icon(Icons.grid_4x4_outlined),
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
    _setText(_capabilityProfileController, endpoint.capabilityProfile);
    _setText(_feedLinesController, '${endpoint.feedLines}');
    _setText(_labelWidthController, '${endpoint.labelWidthMm}');
    _setText(_labelHeightController, '${endpoint.labelHeightMm}');
    _setText(_labelGapController, '${endpoint.labelGapMm}');
    _setText(_labelDpiController, '${endpoint.labelDpi}');
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
                            _printerLabel(printer, l10n),
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
        ? _printerLabel(endpoint, l10n)
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
    final transport = switch (endpoint.kind) {
      PrintTransportKind.serial =>
        '${l10n.printerTransportSerial} - ${endpoint.address}',
      PrintTransportKind.bluetooth =>
        '${l10n.printerTransportBluetooth} - ${endpoint.address}',
      PrintTransportKind.wifi =>
        endpoint.address.isEmpty
            ? l10n.printerTransportWifi
            : '${l10n.printerTransportWifi} - ${endpoint.address}:${endpoint.port}',
      PrintTransportKind.system =>
        endpoint.address.isEmpty
            ? l10n.printerTransportSystem
            : '${l10n.printerTransportSystem} - ${endpoint.address}',
      PrintTransportKind.usb =>
        endpoint.address.isEmpty
            ? l10n.printerTransportUsb
            : '${l10n.printerTransportUsb} - ${endpoint.address}',
      PrintTransportKind.fake => l10n.printerTransportFake,
    };
    final outputMode = endpoint.usesDocumentInvoice
        ? l10n.printerOutputA4Pdf
        : l10n.printerOutputThermalReceipt;
    if (endpoint.usesDocumentInvoice) {
      return '$transport\n$outputMode';
    }
    final barcodeLanguage = l10n.printerBarcodeLanguageSummary(
      _barcodeLabelLanguageLabel(l10n, endpoint.barcodeLabelLanguage),
    );
    final labelGeometry = l10n.printerLabelGeometrySummary(
      endpoint.labelWidthMm,
      endpoint.labelHeightMm,
      endpoint.labelGapMm,
      endpoint.labelDpi,
    );
    return '$transport\n$outputMode\n$barcodeLanguage\n$labelGeometry';
  }
}

class _BarcodeLabelLanguageDetectionMessage extends StatelessWidget {
  const _BarcodeLabelLanguageDetectionMessage({required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final outcome = viewModel.barcodeLabelLanguageDetectionOutcome;
    if (outcome == BarcodeLabelLanguageDetectionOutcome.none) {
      return const SizedBox.shrink();
    }
    final (message, icon, isError) = switch (outcome) {
      BarcodeLabelLanguageDetectionOutcome.detected => (
        l10n.barcodeLabelLanguageDetected,
        Icons.check_circle_outline,
        false,
      ),
      BarcodeLabelLanguageDetectionOutcome.inferred => (
        l10n.barcodeLabelLanguageInferred,
        Icons.manage_search_outlined,
        false,
      ),
      BarcodeLabelLanguageDetectionOutcome.unavailable => (
        l10n.barcodeLabelLanguageDetectionUnavailable,
        Icons.info_outline,
        false,
      ),
      BarcodeLabelLanguageDetectionOutcome.failed => (
        l10n.barcodeLabelLanguageDetectionFailed,
        Icons.error_outline,
        true,
      ),
      BarcodeLabelLanguageDetectionOutcome.none => (
        '',
        Icons.info_outline,
        false,
      ),
    };
    return Padding(
      padding: EdgeInsets.only(top: spacing.sm),
      child: isError
          ? PointyInlineMessage.error(message: message, compact: true)
          : PointyInlineMessage(message: message, icon: icon, compact: true),
    );
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
    final colors = context.pointyColors;
    final (message, color) = switch (outcome) {
      PrinterTestOutcome.none => (null, null),
      PrinterTestOutcome.success => (
        l10n.printerTestSuccess,
        colors.primaryStrong,
      ),
      PrinterTestOutcome.failed => (l10n.printerTestFailure, colors.danger),
      PrinterTestOutcome.barcodeLabelSuccess => (
        l10n.barcodeLabelTestSuccess,
        colors.primaryStrong,
      ),
      PrinterTestOutcome.barcodeLabelFailed => (
        l10n.barcodeLabelTestFailure,
        colors.danger,
      ),
      PrinterTestOutcome.fakeSuccess => (
        l10n.fakePrintSuccess,
        colors.primaryStrong,
      ),
      PrinterTestOutcome.fakeFailed => (l10n.fakePrintFailure, colors.danger),
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
  return '${endpoint.kind.name}:${endpoint.outputMode.name}:${endpoint.address}:${endpoint.port}';
}

String _printerLabel(PrinterEndpoint printer, AppLocalizations l10n) {
  final name = printer.name.trim().isEmpty
      ? printer.kind == PrintTransportKind.system
            ? l10n.systemDefaultPrinterLabel
            : printer.address
      : printer.name;
  final details = switch (printer.kind) {
    PrintTransportKind.serial => printer.address,
    PrintTransportKind.bluetooth => printer.address,
    PrintTransportKind.wifi => '${printer.address}:${printer.port}',
    PrintTransportKind.system => printer.address,
    PrintTransportKind.usb => printer.address,
    PrintTransportKind.fake => printer.address,
  };
  if (details.isEmpty || details == name) {
    return name;
  }
  return '$name - $details';
}

IconData _transportIcon(PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.serial => Icons.cable_outlined,
    PrintTransportKind.bluetooth => Icons.bluetooth_outlined,
    PrintTransportKind.wifi => Icons.wifi_outlined,
    PrintTransportKind.system => Icons.print_outlined,
    PrintTransportKind.usb => Icons.usb,
    PrintTransportKind.fake => Icons.science_outlined,
  };
}

String _barcodeLabelLanguageLabel(
  AppLocalizations l10n,
  BarcodeLabelPrinterLanguage language,
) {
  return switch (language) {
    BarcodeLabelPrinterLanguage.auto => l10n.printerBarcodeLabelLanguageAuto,
    BarcodeLabelPrinterLanguage.zpl => l10n.printerBarcodeLabelLanguageZpl,
    BarcodeLabelPrinterLanguage.tspl => l10n.printerBarcodeLabelLanguageTspl,
    BarcodeLabelPrinterLanguage.epl => l10n.printerBarcodeLabelLanguageEpl,
    BarcodeLabelPrinterLanguage.cpcl => l10n.printerBarcodeLabelLanguageCpcl,
  };
}
