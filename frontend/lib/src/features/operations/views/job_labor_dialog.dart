import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import 'variant_picker_sheet.dart';

/// Charging for work on a job: say what it was and what it costs.
///
/// The counter types it — "screen replacement, 50" — and that is enough: a
/// repair shop cannot be expected to put every job it will ever do in the
/// catalog before it can charge for one (field export, 2026-09-25: the only way
/// to add labour was a catalog service product, the shop had none, and the
/// cashier could not make one). A shop that has priced its services can still
/// pick one, and the price is filled in and stays editable.
///
/// A widget rather than a builder inside the caller, so the two controllers
/// outlive `showDialog`'s await — see `_PromptDialog` on the job screen.
class JobLaborDialog extends StatefulWidget {
  const JobLaborDialog({super.key, required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<JobLaborDialog> createState() => _JobLaborDialogState();
}

class _JobLaborDialogState extends State<JobLaborDialog> {
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  ProductVariant? _service;
  var _showErrors = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  double? get _price => double.tryParse(_priceController.text.trim());

  /// Labour typed by hand needs words and a price above zero; a catalog
  /// service already has its name, and may be agreed at no charge.
  bool get _descriptionMissing =>
      _service == null && _descriptionController.text.trim().isEmpty;

  bool get _priceInvalid {
    final price = _price;
    if (price == null) {
      return true;
    }
    return _service == null ? price <= 0 : price < 0;
  }

  Future<void> _pickService() async {
    final l10n = AppLocalizations.of(context)!;
    final variant = await showVariantPickerSheet(
      context,
      catalogRepository: widget.catalogRepository,
      title: l10n.jobServicePickerTitle,
      // Only service products: a screen added as "labour" would be billed
      // without moving any stock, and the phone on the bench would still be
      // waiting for a part the system thinks was fitted.
      where: (variant) => variant.isService,
      emptyMessage: l10n.jobNoServiceProductsMessage,
    );
    if (variant == null || !mounted) {
      return;
    }
    setState(() {
      _service = variant;
      _priceController.text = variant.unitPrice.toStringAsFixed(2);
    });
  }

  void _submit() {
    if (_descriptionMissing || _priceInvalid) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.of(context).pop(
      JobServiceDraft(
        variant: _service?.id,
        note: _descriptionController.text.trim(),
        unitPrice: _price,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final service = _service;

    return AlertDialog(
      icon: const Icon(Icons.handyman_outlined),
      title: Text(l10n.jobLaborDialogTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (service != null) ...[
                InputChip(
                  avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: Text(service.displayLabel),
                  onDeleted: () => setState(() => _service = null),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _descriptionController,
                autofocus: true,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: service == null
                      ? l10n.jobLaborDescriptionLabel
                      : l10n.jobLaborNoteLabel,
                  hintText: l10n.jobLaborDescriptionHint,
                  counterText: '',
                  errorText: _showErrors && _descriptionMissing
                      ? l10n.jobLaborDescriptionRequired
                      : null,
                ),
                onChanged: (_) {
                  if (_showErrors) {
                    setState(() {});
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.jobLaborPriceLabel,
                  suffixText: currencySymbol,
                  errorText: _showErrors && _priceInvalid
                      ? l10n.jobLaborPriceRequired
                      : null,
                ),
                onChanged: (_) {
                  if (_showErrors) {
                    setState(() {});
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
              if (service == null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _pickService,
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: Text(l10n.jobLaborPickServiceButton),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.jobLaborAddConfirm)),
      ],
    );
  }
}
