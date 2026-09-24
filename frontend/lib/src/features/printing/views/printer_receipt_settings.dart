import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/device_printers.dart';
import '../../../data/models/printer_config.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printer_editor_view_model.dart';

/// How a printer prints a receipt — and a kitchen chit, which comes off the
/// same roll. A thermal printer is told its paper and how to finish a slip;
/// a driver printer is told the page to lay the receipt out on.
///
/// Seeded once from the draft: keyed by the editor's device generation, so
/// pointing the printer at another device starts these fields over.
class PrinterReceiptSettings extends StatefulWidget {
  const PrinterReceiptSettings({super.key, required this.editor});

  final PrinterEditorViewModel editor;

  @override
  State<PrinterReceiptSettings> createState() => _PrinterReceiptSettingsState();
}

class _PrinterReceiptSettingsState extends State<PrinterReceiptSettings> {
  late final TextEditingController _paperWidthController;
  late final TextEditingController _codeTableController;
  late final TextEditingController _capabilityProfileController;
  late final TextEditingController _feedLinesController;

  PrinterEditorViewModel get _editor => widget.editor;

  @override
  void initState() {
    super.initState();
    final endpoint = _editor.endpoint;
    _paperWidthController = TextEditingController(
      text: '${endpoint.paperWidthMm}',
    );
    _codeTableController = TextEditingController(text: endpoint.codeTable);
    _capabilityProfileController = TextEditingController(
      text: endpoint.capabilityProfile,
    );
    _feedLinesController = TextEditingController(text: '${endpoint.feedLines}');
  }

  @override
  void dispose() {
    _paperWidthController.dispose();
    _codeTableController.dispose();
    _capabilityProfileController.dispose();
    _feedLinesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final endpoint = _editor.endpoint;
    final enabled = !_editor.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.printerReceiptSettingsTitle),
        if (endpoint.usesDocumentInvoice)
          DropdownButtonFormField<PdfPageSize>(
            key: ValueKey(endpoint.pdfPageSize),
            initialValue: endpoint.pdfPageSize,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.printerPdfPageSizeLabel,
              helperText: l10n.printerPdfPageSizeHelper,
              helperMaxLines: 3,
              prefixIcon: const Icon(Icons.picture_as_pdf_outlined),
            ),
            items: [
              DropdownMenuItem(
                value: PdfPageSize.a4,
                child: Text(l10n.printerPdfPageSizeA4),
              ),
              DropdownMenuItem(
                value: PdfPageSize.roll58,
                child: Text(l10n.printerPdfPageSizeRoll58),
              ),
              DropdownMenuItem(
                value: PdfPageSize.roll70,
                child: Text(l10n.printerPdfPageSizeRoll70),
              ),
              DropdownMenuItem(
                value: PdfPageSize.roll80,
                child: Text(l10n.printerPdfPageSizeRoll80),
              ),
            ],
            onChanged: enabled
                ? (size) {
                    if (size != null) {
                      _editor.updatePdfPageSize(size);
                    }
                  }
                : null,
          )
        else
          ResponsiveFormGrid(
            maxColumns: 2,
            children: [
              TextFormField(
                key: const ValueKey('printer_paper_width_field'),
                controller: _paperWidthController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: _editor.updatePaperWidth,
                decoration: InputDecoration(
                  labelText: l10n.paperWidthLabel,
                  prefixIcon: const Icon(Icons.receipt_outlined),
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
                onChanged: enabled
                    ? (mode) {
                        if (mode != null) {
                          _editor.updateCutMode(mode);
                        }
                      }
                    : null,
              ),
            ],
          ),
        // Kitchen chits ignore the compact layout by design, so the switch
        // belongs to the receipt job alone.
        if (_editor.draft.holds(PrinterRole.posReceipt))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: endpoint.compactReceipt,
            title: Text(l10n.printerCompactReceiptLabel),
            subtitle: Text(l10n.printerCompactReceiptHelper),
            secondary: const Icon(Icons.density_small_outlined),
            onChanged: enabled ? _editor.updateCompactReceipt : null,
          ),
        if (!endpoint.usesDocumentInvoice)
          ExpansionTile(
            key: const ValueKey('printer_advanced_settings'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.only(bottom: spacing.sm),
            leading: const Icon(Icons.tune_outlined),
            title: Text(l10n.printerAdvancedSettingsTitle),
            children: [
              ResponsiveFormGrid(
                maxColumns: 2,
                children: [
                  TextFormField(
                    controller: _codeTableController,
                    enabled: enabled,
                    onChanged: _editor.updateCodeTable,
                    decoration: InputDecoration(
                      labelText: l10n.printerCodeTableLabel,
                      prefixIcon: const Icon(Icons.translate_outlined),
                    ),
                  ),
                  TextFormField(
                    controller: _feedLinesController,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: _editor.updateFeedLines,
                    decoration: InputDecoration(
                      labelText: l10n.printerFeedLinesLabel,
                      helperText: l10n.printerFeedLinesHelper,
                      helperMaxLines: 2,
                      prefixIcon: const Icon(Icons.density_medium_outlined),
                    ),
                  ),
                  TextFormField(
                    controller: _capabilityProfileController,
                    enabled: enabled,
                    onChanged: _editor.updateCapabilityProfile,
                    decoration: InputDecoration(
                      labelText: l10n.printerCapabilityProfileLabel,
                      helperText: l10n.printerCapabilityProfileHelper,
                      helperMaxLines: 3,
                      prefixIcon: const Icon(Icons.memory_outlined),
                    ),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
