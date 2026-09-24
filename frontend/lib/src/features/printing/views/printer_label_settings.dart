import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/printer_config.dart';
import '../../../data/services/barcode_label_calibration.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/printer_editor_view_model.dart';

/// How a printer prints barcode stickers. A raw label printer is told its
/// language and media; a driver printer is told the sticker's geometry, which
/// is measured off calibration sheets rather than guessed.
///
/// Seeded once from the draft: keyed by the editor's device generation, so
/// pointing the printer at another device starts these fields over.
class PrinterLabelSettings extends StatefulWidget {
  const PrinterLabelSettings({super.key, required this.editor});

  final PrinterEditorViewModel editor;

  @override
  State<PrinterLabelSettings> createState() => _PrinterLabelSettingsState();
}

class _PrinterLabelSettingsState extends State<PrinterLabelSettings> {
  late final TextEditingController _widthController;
  late final TextEditingController _heightController;
  late final TextEditingController _gapController;
  late final TextEditingController _dpiController;
  late final TextEditingController _offsetXController;
  late final TextEditingController _offsetYController;
  late final TextEditingController _pitchController;

  PrinterEditorViewModel get _editor => widget.editor;

  @override
  void initState() {
    super.initState();
    final endpoint = _editor.endpoint;
    _widthController = TextEditingController(text: '${endpoint.labelWidthMm}');
    _heightController = TextEditingController(
      text: '${endpoint.labelHeightMm}',
    );
    _gapController = TextEditingController(text: '${endpoint.labelGapMm}');
    _dpiController = TextEditingController(text: '${endpoint.labelDpi}');
    _offsetXController = TextEditingController(
      text: '${endpoint.labelPdfOffsetXMm}',
    );
    _offsetYController = TextEditingController(
      text: '${endpoint.labelPdfOffsetYMm}',
    );
    _pitchController = TextEditingController(
      text: _pitchText(endpoint.labelPdfPitchMm),
    );
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    _gapController.dispose();
    _dpiController.dispose();
    _offsetXController.dispose();
    _offsetYController.dispose();
    _pitchController.dispose();
    super.dispose();
  }

  /// Whole millimetres show without a decimal tail; fractions keep theirs.
  static String _pitchText(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(title: l10n.barcodeLabelPrinterSettingsTitle),
        if (_editor.endpoint.usesDocumentInvoice)
          ..._documentFields(context)
        else
          ..._thermalFields(context),
      ],
    );
  }

  List<Widget> _documentFields(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final endpoint = _editor.endpoint;
    final enabled = !_editor.isBusy;

    return [
      DropdownButtonFormField<BarcodeLabelPdfSize>(
        key: ValueKey(endpoint.labelPdfSize),
        initialValue: endpoint.labelPdfSize,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.printerBarcodeLabelPdfSizeLabel,
          helperText: l10n.printerBarcodeLabelPdfSizeHelper,
          helperMaxLines: 3,
          prefixIcon: const Icon(Icons.label_outline),
        ),
        items: [
          DropdownMenuItem(
            value: BarcodeLabelPdfSize.sticker,
            child: Text(l10n.printerBarcodeLabelPdfSizeSticker),
          ),
          DropdownMenuItem(
            value: BarcodeLabelPdfSize.roll50,
            child: Text(l10n.printerBarcodeLabelPdfSizeRoll50),
          ),
          DropdownMenuItem(
            value: BarcodeLabelPdfSize.roll70,
            child: Text(l10n.printerBarcodeLabelPdfSizeRoll70),
          ),
          DropdownMenuItem(
            value: BarcodeLabelPdfSize.roll80,
            child: Text(l10n.printerBarcodeLabelPdfSizeRoll80),
          ),
          DropdownMenuItem(
            value: BarcodeLabelPdfSize.a4,
            child: Text(l10n.printerBarcodeLabelPdfSizeA4),
          ),
        ],
        onChanged: enabled
            ? (size) {
                if (size != null) {
                  _editor.updateLabelPdfSize(size);
                }
              }
            : null,
      ),
      if (endpoint.labelPdfSize == BarcodeLabelPdfSize.sticker) ...[
        SizedBox(height: spacing.md),
        ResponsiveFormGrid(
          maxColumns: 2,
          children: [
            _numberField(
              controller: _widthController,
              label: l10n.printerLabelWidthLabel,
              helper: l10n.printerBarcodeLabelMediaHelper,
              icon: Icons.width_normal_outlined,
              onChanged: _editor.updateLabelWidth,
            ),
            // Page units, not paper millimetres. Leaving this unsaid once cost
            // a night: a sticker entered at its tape-measured height makes the
            // card centre in a box shorter than the label, and nudging the
            // offset to correct it only walks the print off one edge or the
            // other.
            _numberField(
              controller: _heightController,
              label: l10n.printerLabelHeightLabel,
              helper: l10n.printerBarcodeLabelHeightHelper,
              icon: Icons.height_outlined,
              onChanged: _editor.updateLabelHeight,
            ),
            _numberField(
              controller: _pitchController,
              label: l10n.printerBarcodeLabelPitchLabel,
              helper: l10n.printerBarcodeLabelPitchHelper,
              icon: Icons.straighten_outlined,
              onChanged: _editor.updateLabelPdfPitch,
              decimal: true,
            ),
            _numberField(
              controller: _offsetYController,
              label: l10n.printerBarcodeLabelOffsetYLabel,
              helper: l10n.printerBarcodeLabelOffsetYHelper,
              icon: Icons.vertical_align_top_outlined,
              onChanged: _editor.updateLabelPdfOffsetY,
            ),
            _numberField(
              controller: _offsetXController,
              label: l10n.printerBarcodeLabelOffsetXLabel,
              helper: l10n.printerBarcodeLabelOffsetXHelper,
              icon: Icons.format_indent_increase_outlined,
              onChanged: _editor.updateLabelPdfOffsetX,
            ),
          ],
        ),
        SizedBox(height: spacing.md),
        _LabelCalibrationSection(editor: _editor),
      ],
      SizedBox(height: spacing.md),
      DropdownButtonFormField<int>(
        key: ValueKey(endpoint.labelRotationQuarterTurns),
        initialValue: endpoint.labelRotationQuarterTurns,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.printerBarcodeLabelRotationLabel,
          helperText: l10n.printerBarcodeLabelRotationHelper,
          helperMaxLines: 2,
          prefixIcon: const Icon(Icons.rotate_90_degrees_cw_outlined),
        ),
        items: [
          DropdownMenuItem(
            value: 0,
            child: Text(l10n.printerBarcodeLabelRotation0),
          ),
          DropdownMenuItem(
            value: 1,
            child: Text(l10n.printerBarcodeLabelRotation90),
          ),
          DropdownMenuItem(
            value: 2,
            child: Text(l10n.printerBarcodeLabelRotation180),
          ),
          DropdownMenuItem(
            value: 3,
            child: Text(l10n.printerBarcodeLabelRotation270),
          ),
        ],
        onChanged: enabled
            ? (turns) {
                if (turns != null) {
                  _editor.updateLabelRotation(turns);
                }
              }
            : null,
      ),
    ];
  }

  List<Widget> _thermalFields(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final endpoint = _editor.endpoint;
    final enabled = !_editor.isBusy;

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DropdownButtonFormField<BarcodeLabelPrinterLanguage>(
              key: ValueKey(endpoint.barcodeLabelLanguage),
              initialValue: endpoint.barcodeLabelLanguage,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.printerBarcodeLabelLanguageLabel,
                prefixIcon: const Icon(Icons.label_outline),
              ),
              items: [
                for (final language in BarcodeLabelPrinterLanguage.values)
                  DropdownMenuItem(
                    value: language,
                    child: Text(_languageLabel(l10n, language)),
                  ),
              ],
              onChanged: enabled
                  ? (language) {
                      if (language != null) {
                        _editor.updateBarcodeLabelLanguage(language);
                      }
                    }
                  : null,
            ),
          ),
          SizedBox(width: spacing.sm),
          IconButton.filledTonal(
            key: const ValueKey('printer_detect_label_language'),
            tooltip: l10n.detectBarcodeLabelLanguageButton,
            onPressed: enabled ? _editor.detectLabelLanguage : null,
            icon: _editor.isDetectingLanguage
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
          ),
        ],
      ),
      if (_detectionMessage(l10n) case final message?) ...[
        SizedBox(height: spacing.sm),
        message,
      ],
      SizedBox(height: spacing.md),
      ResponsiveFormGrid(
        maxColumns: 4,
        minChildWidth: 140,
        children: [
          _numberField(
            controller: _widthController,
            label: l10n.printerLabelWidthLabel,
            icon: Icons.width_normal_outlined,
            onChanged: _editor.updateLabelWidth,
          ),
          _numberField(
            controller: _heightController,
            label: l10n.printerLabelHeightLabel,
            icon: Icons.height_outlined,
            onChanged: _editor.updateLabelHeight,
          ),
          _numberField(
            controller: _gapController,
            label: l10n.printerLabelGapLabel,
            icon: Icons.space_bar_outlined,
            onChanged: _editor.updateLabelGap,
          ),
          _numberField(
            controller: _dpiController,
            label: l10n.printerLabelDpiLabel,
            icon: Icons.grid_4x4_outlined,
            onChanged: _editor.updateLabelDpi,
          ),
        ],
      ),
    ];
  }

  Widget? _detectionMessage(AppLocalizations l10n) {
    return switch (_editor.detection) {
      BarcodeLabelLanguageDetectionOutcome.none => null,
      BarcodeLabelLanguageDetectionOutcome.detected =>
        PointyInlineMessage.success(
          message: l10n.barcodeLabelLanguageDetected,
          compact: true,
        ),
      BarcodeLabelLanguageDetectionOutcome.inferred => PointyInlineMessage(
        message: l10n.barcodeLabelLanguageInferred,
        icon: Icons.manage_search_outlined,
        compact: true,
      ),
      BarcodeLabelLanguageDetectionOutcome.unavailable => PointyInlineMessage(
        message: l10n.barcodeLabelLanguageDetectionUnavailable,
        compact: true,
      ),
      BarcodeLabelLanguageDetectionOutcome.failed => PointyInlineMessage.error(
        message: l10n.barcodeLabelLanguageDetectionFailed,
        compact: true,
      ),
    };
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required ValueChanged<String> onChanged,
    String? helper,
    bool decimal = false,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_editor.isBusy,
      keyboardType: decimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.number,
      inputFormatters: [
        decimal
            ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
            : FilteringTextInputFormatter.digitsOnly,
      ],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: helper == null ? null : 4,
        prefixIcon: Icon(icon),
      ),
    );
  }

  static String _languageLabel(
    AppLocalizations l10n,
    BarcodeLabelPrinterLanguage language,
  ) {
    return switch (language) {
      BarcodeLabelPrinterLanguage.auto => l10n.printerBarcodeLabelLanguageAuto,
      BarcodeLabelPrinterLanguage.zpl => l10n.printerBarcodeLabelLanguageZpl,
      BarcodeLabelPrinterLanguage.tspl => l10n.printerBarcodeLabelLanguageTspl,
      BarcodeLabelPrinterLanguage.epl => l10n.printerBarcodeLabelLanguageEpl,
      BarcodeLabelPrinterLanguage.cpcl => l10n.printerBarcodeLabelLanguageCpcl,
      BarcodeLabelPrinterLanguage.escPos =>
        l10n.printerBarcodeLabelLanguageEscPos,
    };
  }
}

/// Calibration prints for die-cut labels.
///
/// Every die-cut number is a measurement — where the roll sits under the head,
/// how tall a sticker is, how far apart they repeat — and a printer that is a
/// millimetre out on any of them walks its labels off the stickers. These
/// sheets put a scale on the labels themselves so the numbers can be read
/// rather than guessed at, one print per unknown.
class _LabelCalibrationSection extends StatelessWidget {
  const _LabelCalibrationSection({required this.editor});

  final PrinterEditorViewModel editor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final enabled = !editor.isBusy;

    Widget sheetButton(
      String label,
      IconData icon,
      BarcodeLabelCalibrationSheet sheet,
    ) {
      return OutlinedButton.icon(
        onPressed: enabled ? () => editor.printCalibration(sheet) : null,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.printerBarcodeLabelCalibrationTitle,
          style: theme.textTheme.titleSmall,
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.printerBarcodeLabelCalibrationHelper,
          style: theme.textTheme.bodySmall?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
        SizedBox(height: spacing.sm),
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            sheetButton(
              l10n.printerBarcodeLabelCalibrationAcross,
              Icons.straighten_outlined,
              BarcodeLabelCalibrationSheet.acrossRuler,
            ),
            sheetButton(
              l10n.printerBarcodeLabelCalibrationFeed,
              Icons.height_outlined,
              BarcodeLabelCalibrationSheet.feedRuler,
            ),
            sheetButton(
              l10n.printerBarcodeLabelCalibrationCombCoarse,
              Icons.view_column_outlined,
              BarcodeLabelCalibrationSheet.pitchCombCoarse,
            ),
            sheetButton(
              l10n.printerBarcodeLabelCalibrationCombFine,
              Icons.view_week_outlined,
              BarcodeLabelCalibrationSheet.pitchCombFine,
            ),
          ],
        ),
      ],
    );
  }
}
