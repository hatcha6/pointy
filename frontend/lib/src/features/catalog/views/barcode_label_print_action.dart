import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/components/pointy_progress.dart';

class BarcodeLabelPrintDialogResult {
  const BarcodeLabelPrintDialogResult({
    required this.copies,
    required this.includePrice,
    required this.expiryDate,
  });

  final int copies;
  final bool includePrice;
  final DateTime? expiryDate;

  bool get includeExpiryDate => expiryDate != null;

  BarcodeLabelPrintLine toPrintLine(BarcodeLabelDraft label) {
    return BarcodeLabelPrintLine(
      label: label,
      copies: copies,
      includePrice: includePrice,
      expiryDate: expiryDate,
    );
  }
}

Future<BarcodeLabelPrintDialogResult?> showBarcodeLabelPrintDialog({
  required BuildContext context,
  required BarcodeLabelDraft label,
  required bool tracksExpiry,
}) {
  return showDialog<BarcodeLabelPrintDialogResult>(
    context: context,
    builder: (dialogContext) {
      return _BarcodeLabelPrintOptionsDialog(
        label: label,
        tracksExpiry: tracksExpiry,
      );
    },
  );
}

enum BarcodeLabelPrintButtonStyle { filled, outlined, icon }

class BarcodeLabelPrintButton extends StatefulWidget {
  const BarcodeLabelPrintButton({
    super.key,
    required this.label,
    required this.printingRepository,
    required this.productId,
    required this.productName,
    required this.entityType,
    required this.entityId,
    required this.source,
    this.variantId,
    this.tracksExpiry = false,
    this.analyticsEngine,
    this.style = BarcodeLabelPrintButtonStyle.filled,
    this.labelText,
    this.tooltip,
    this.width,
  });

  final BarcodeLabelDraft label;
  final PrintingRepository printingRepository;
  final int productId;
  final String productName;
  final int? variantId;
  final String entityType;
  final int entityId;
  final String source;
  final bool tracksExpiry;
  final AnalyticsEngine? analyticsEngine;
  final BarcodeLabelPrintButtonStyle style;
  final String? labelText;
  final String? tooltip;
  final double? width;

  @override
  State<BarcodeLabelPrintButton> createState() =>
      _BarcodeLabelPrintButtonState();
}

class _BarcodeLabelPrintButtonState extends State<BarcodeLabelPrintButton> {
  bool _isPrinting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasBarcode = widget.label.barcode.trim().isNotEmpty;
    final onPressed = hasBarcode && !_isPrinting ? _printLabel : null;
    final tooltip = hasBarcode
        ? widget.tooltip ?? l10n.barcodeLabelPrintButton
        : l10n.barcodeLabelPrintNoBarcodeShort;

    if (widget.style == BarcodeLabelPrintButtonStyle.icon) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: _isPrinting
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.print_outlined),
      );
    }

    final label = Text(
      _isPrinting
          ? l10n.barcodeLabelPrintInProgressButton
          : widget.labelText ?? l10n.barcodeLabelPrintButton,
    );
    final icon = _isPrinting
        ? const SizedBox.square(
            dimension: 18,
            child: PointySpinner(strokeWidth: 2),
          )
        : const Icon(Icons.print_outlined);
    final button = widget.style == BarcodeLabelPrintButtonStyle.outlined
        ? OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label)
        : FilledButton.icon(onPressed: onPressed, icon: icon, label: label);

    final constrainedButton = widget.width == null
        ? button
        : SizedBox(width: widget.width, child: button);
    return Tooltip(message: tooltip, child: constrainedButton);
  }

  Future<void> _printLabel() async {
    final options = await showBarcodeLabelPrintDialog(
      context: context,
      label: widget.label,
      tracksExpiry: widget.tracksExpiry,
    );
    if (options == null) {
      return;
    }
    if (!mounted) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isPrinting = true);

    final result = await widget.printingRepository.printBarcodeLabels([
      options.toPrintLine(widget.label),
    ]);
    _trackBarcodeLabelsPrinted(options: options, success: result.isSuccess);

    if (!mounted) {
      return;
    }
    setState(() => _isPrinting = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? l10n.barcodeLabelPrintSuccess(options.copies)
              : l10n.barcodeLabelPrintError,
        ),
      ),
    );
  }

  void _trackBarcodeLabelsPrinted({
    required BarcodeLabelPrintDialogResult options,
    required bool success,
  }) {
    trackAuditEvent(
      widget.analyticsEngine,
      name: success
          ? 'printing.barcode_labels.printed'
          : 'printing.barcode_labels.failed',
      severity: success
          ? AnalyticsEventSeverity.info
          : AnalyticsEventSeverity.warning,
      entityType: widget.entityType,
      entityId: widget.entityId,
      attributes: {
        'product_id': widget.productId,
        'product_name': widget.productName,
        if (widget.variantId != null) 'variant_id': widget.variantId,
        'sku': widget.label.sku,
        'barcode_present': widget.label.barcode.trim().isNotEmpty,
        'include_price': options.includePrice,
        'include_expiry_date': options.includeExpiryDate,
        'source': widget.source,
      },
      metrics: {'copies': options.copies, 'label_count': options.copies},
      flushImmediately: !success,
    );
  }
}

class _BarcodeLabelPrintOptionsDialog extends StatefulWidget {
  const _BarcodeLabelPrintOptionsDialog({
    required this.label,
    required this.tracksExpiry,
  });

  final BarcodeLabelDraft label;
  final bool tracksExpiry;

  @override
  State<_BarcodeLabelPrintOptionsDialog> createState() =>
      _BarcodeLabelPrintOptionsDialogState();
}

class _BarcodeLabelPrintOptionsDialogState
    extends State<_BarcodeLabelPrintOptionsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _copiesController = TextEditingController(text: '1');
  final _expiryController = TextEditingController();
  bool _includePrice = true;
  late bool _includeExpiryDate;
  DateTime? _expiryDate;

  @override
  void initState() {
    super.initState();
    _includeExpiryDate = widget.tracksExpiry;
  }

  @override
  void dispose() {
    _copiesController.dispose();
    _expiryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final availableDialogWidth = math.max(
      280.0,
      MediaQuery.sizeOf(context).width - 48,
    );
    final dialogWidth = math.min(availableDialogWidth, 440.0);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(l10n.barcodeLabelCopiesDialogTitle),
        content: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _copiesController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l10n.barcodeLabelCopiesLabel,
                      hintText: l10n.barcodeLabelCopiesHint,
                      prefixIcon: const Icon(Icons.tag_outlined),
                    ),
                    validator: (value) {
                      final copies = int.tryParse(value ?? '');
                      if (copies == null || copies <= 0) {
                        return l10n.invalidNumber;
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _includePrice,
                    onChanged: (value) => setState(() => _includePrice = value),
                    secondary: const Icon(Icons.price_check_outlined),
                    title: Text(l10n.barcodeLabelIncludePriceLabel),
                    subtitle: Text(l10n.barcodeLabelIncludePriceHint),
                  ),
                  const Divider(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _includeExpiryDate,
                    onChanged: (value) {
                      setState(() {
                        _includeExpiryDate = value;
                        if (!value) {
                          _expiryDate = null;
                          _expiryController.clear();
                        }
                      });
                    },
                    secondary: const Icon(Icons.event_available_outlined),
                    title: Text(l10n.barcodeLabelIncludeExpiryLabel),
                    subtitle: Text(l10n.barcodeLabelIncludeExpiryHint),
                  ),
                  if (_includeExpiryDate) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _expiryController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: l10n.barcodeLabelExpiryDateLabel,
                        prefixIcon: const Icon(Icons.calendar_month_outlined),
                        suffixIcon: IconButton(
                          tooltip: l10n.barcodeLabelExpiryDatePickerTooltip,
                          onPressed: _pickExpiryDate,
                          icon: const Icon(Icons.edit_calendar_outlined),
                        ),
                      ),
                      validator: (_) {
                        if (_includeExpiryDate && _expiryDate == null) {
                          return l10n.barcodeLabelExpiryDateRequired;
                        }
                        return null;
                      },
                      onTap: _pickExpiryDate,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _BarcodeLabelPreview(
                    label: widget.label,
                    includePrice: _includePrice,
                    expiryDate: _includeExpiryDate ? _expiryDate : null,
                    awaitingExpiryDate:
                        _includeExpiryDate && _expiryDate == null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.print_outlined),
            label: Text(l10n.barcodeLabelCopiesPrintButton),
          ),
        ],
      ),
    );
  }

  Future<void> _pickExpiryDate() async {
    final now = DateTime.now();
    final initialDate = _expiryDate ?? DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 20),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _expiryDate = picked;
      _expiryController.text = formatDate(picked);
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      BarcodeLabelPrintDialogResult(
        copies: int.parse(_copiesController.text),
        includePrice: _includePrice,
        expiryDate: _includeExpiryDate ? _expiryDate : null,
      ),
    );
  }
}

class _BarcodeLabelPreview extends StatelessWidget {
  const _BarcodeLabelPreview({
    required this.label,
    required this.includePrice,
    required this.expiryDate,
    required this.awaitingExpiryDate,
  });

  final BarcodeLabelDraft label;
  final bool includePrice;
  final DateTime? expiryDate;
  final bool awaitingExpiryDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final details = [
      if (includePrice)
        l10n.barcodeLabelPreviewPrice(formatMoney(label.unitPrice)),
      if (expiryDate != null)
        l10n.barcodeLabelPreviewExpiry(formatDate(expiryDate!))
      else if (awaitingExpiryDate)
        l10n.barcodeLabelExpiryDateRequired,
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withOpacity(0.45),
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.barcodeLabelPreviewTitle,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Text(
              label.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                details.join('  |  '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              label.barcode,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                letterSpacing: 0,
                color: colors.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
