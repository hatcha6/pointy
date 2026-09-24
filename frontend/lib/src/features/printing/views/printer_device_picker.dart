import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/printer_config.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printer_editor_view_model.dart';
import '../view_models/printing_settings_view_model.dart';
import 'printer_presentation.dart';

/// Which device a printer talks to: one found on this machine, or a network
/// printer typed in by address — many cheap network printers never announce
/// themselves, and there used to be no way to add one.
class PrinterDevicePicker extends StatefulWidget {
  const PrinterDevicePicker({super.key, required this.editor});

  final PrinterEditorViewModel editor;

  @override
  State<PrinterDevicePicker> createState() => _PrinterDevicePickerState();
}

class _PrinterDevicePickerState extends State<PrinterDevicePicker> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late bool _showsNetworkEntry;

  PrinterEditorViewModel get _editor => widget.editor;

  @override
  void initState() {
    super.initState();
    final endpoint = _editor.endpoint;
    final isNetwork = endpoint.kind == PrintTransportKind.wifi;
    _hostController = TextEditingController(
      text: isNetwork ? endpoint.address : '',
    );
    _portController = TextEditingController(
      text: '${isNetwork ? endpoint.port : 9100}',
    );
    _showsNetworkEntry = false;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _useNetworkAddress() {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      return;
    }
    _editor.useNetworkAddress(
      host,
      port: int.tryParse(_portController.text.trim()) ?? 9100,
    );
    setState(() => _showsNetworkEntry = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final settings = _editor.settings;
    final options = _deviceOptions(settings.discoveredPrinters);
    final selectedKey = _editor.hasDevice ? _deviceKey(_editor.endpoint) : null;
    final duplicate = _editor.duplicateOf;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: l10n.printerDeviceSectionTitle,
          subtitle: l10n.printerDeviceSectionHint,
        ),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'printer_device_${selectedKey}_${options.length}',
                ),
                initialValue: selectedKey,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.discoveredPrintersLabel,
                  prefixIcon: const Icon(Icons.print_outlined),
                ),
                hint: Text(
                  options.isEmpty
                      ? l10n.noDiscoveredPrinters
                      : l10n.selectDiscoveredPrinterHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // The field has its own printer icon; the selected device shows
                // as text beside it rather than a second icon.
                selectedItemBuilder: (context) => [
                  for (final option in options)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        printerConnectionLine(l10n, option),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                items: [
                  for (final option in options)
                    DropdownMenuItem<String>(
                      value: _deviceKey(option),
                      child: Row(
                        children: [
                          Icon(printerTransportIcon(option.kind), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              printerConnectionLine(l10n, option),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: _editor.isBusy
                    ? null
                    : (key) {
                        final device = options
                            .where((option) => _deviceKey(option) == key)
                            .firstOrNull;
                        if (device != null) {
                          _editor.selectDevice(device);
                        }
                      },
              ),
            ),
            SizedBox(width: spacing.sm),
            IconButton.filledTonal(
              key: const ValueKey('printer_discover_button'),
              tooltip: l10n.discoverPrintersButton,
              onPressed: settings.isDiscovering
                  ? null
                  : _editor.discoverPrinters,
              icon: settings.isDiscovering
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_outlined),
            ),
          ],
        ),
        if (settings.hasDiscoveryError) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.error(
            message: l10n.printerDiscoveryError,
            compact: true,
          ),
        ],
        if (duplicate != null) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.warning(
            message: l10n.printerDuplicateDevice(
              printerDisplayName(l10n, duplicate),
            ),
            compact: true,
          ),
        ],
        if (_editor.hasDevice) ...[
          SizedBox(height: spacing.sm),
          Row(
            children: [
              PointyStatusPill(
                key: const ValueKey('printer_editor_connection'),
                label: printerConnectionLabel(l10n, _editor.connection),
                color: printerConnectionColor(colors, _editor.connection),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Text(
                  printerOutputSummary(l10n, _editor.endpoint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ),
              TextButton.icon(
                onPressed: _editor.connection == PrinterConnectionState.checking
                    ? null
                    : _editor.checkConnection,
                icon: const Icon(Icons.sensors_outlined, size: 18),
                label: Text(l10n.checkPrinterConnectionButton),
              ),
            ],
          ),
        ],
        SizedBox(height: spacing.xs),
        if (!_showsNetworkEntry)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('printer_manual_network_button'),
              onPressed: _editor.isBusy
                  ? null
                  : () => setState(() => _showsNetworkEntry = true),
              icon: const Icon(Icons.lan_outlined, size: 18),
              label: Text(l10n.printerManualNetworkButton),
            ),
          )
        else ...[
          SizedBox(height: spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('printer_network_host_field'),
                  controller: _hostController,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _useNetworkAddress(),
                  decoration: InputDecoration(
                    labelText: l10n.printerNetworkAddressLabel,
                    hintText: '192.168.1.100',
                    prefixIcon: const Icon(Icons.lan_outlined),
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              SizedBox(
                width: 96,
                child: TextField(
                  key: const ValueKey('printer_network_port_field'),
                  controller: _portController,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _useNetworkAddress(),
                  decoration: InputDecoration(
                    labelText: l10n.printerNetworkPortLabel,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonalIcon(
              key: const ValueKey('printer_network_use_button'),
              onPressed: _useNetworkAddress,
              icon: const Icon(Icons.check),
              label: Text(l10n.printerNetworkUseButton),
            ),
          ),
        ],
      ],
    );
  }

  /// The devices to offer: what discovery found, plus the one the printer
  /// already talks to, which may not be around right now and must still be
  /// shown as the choice it is.
  List<PrinterEndpoint> _deviceOptions(List<PrinterEndpoint> discovered) {
    final options = <String, PrinterEndpoint>{};
    if (_editor.hasDevice) {
      options[_deviceKey(_editor.endpoint)] = _editor.endpoint;
    }
    for (final device in discovered) {
      options.putIfAbsent(_deviceKey(device), () => device);
    }
    return options.values.toList(growable: false);
  }

  static String _deviceKey(PrinterEndpoint endpoint) {
    return '${endpoint.kind.name}:${endpoint.outputMode.name}:'
        '${endpoint.address}:${endpoint.port}';
  }
}
