import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/unit_attribute.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../formatters.dart';
import '../responsive/responsive.dart';
import 'unit_attribute_form.dart';

/// What the details sheet hands back: the article's facts and, when they were
/// asked for, its own warranty end date and its own selling price (null = the
/// product's warranty days / the product's price).
class UnitDetailsDraft {
  const UnitDetailsDraft({
    this.attributes = const {},
    this.warrantyOverride,
    this.listPrice,
  });

  final Map<String, Object?> attributes;
  final DateTime? warrantyOverride;
  final double? listPrice;
}

/// How a save went: nothing to say, or the server's refusal — per field where
/// it named fields, as one sentence where it did not.
class UnitDetailsSaveOutcome {
  const UnitDetailsSaveOutcome.saved() : fieldErrors = const {}, message = '';
  const UnitDetailsSaveOutcome.refused({
    this.fieldErrors = const {},
    this.message = '',
  });

  final Map<String, String> fieldErrors;
  final String message;

  bool get isSaved => fieldErrors.isEmpty && message.isEmpty;
}

typedef UnitDetailsSaver =
    Future<UnitDetailsSaveOutcome> Function(UnitDetailsDraft draft);

/// The condition checklist and the warranty date of one article, as a form.
///
/// Shared by the unit page (where [onSave] writes to the server and the sheet
/// stays open on a refusal, showing it beside the field) and the capture sheet
/// at intake (no [onSave]: the draft rides back to be sent with the receipt).
/// The halves are separately switchable because they are separately
/// permitted — describing a handset is counter work, promising a customer a
/// longer cover is not, and neither is pricing it ([editListPrice] follows the
/// unit page's reprice permission). Intake is the one caller that asks for the
/// price: a used handset is priced as it is described, one at a time.
Future<UnitDetailsDraft?> showUnitDetailsSheet(
  BuildContext context, {
  required String title,
  List<UnitAttributeDefinition> definitions = const [],
  Map<String, Object?> attributes = const {},
  bool editAttributes = true,
  bool editWarranty = false,
  DateTime? warrantyOverride,
  bool editListPrice = false,
  double? listPrice,

  /// The product's own price, named in the price field's hint so a blank
  /// field reads as a decision rather than a gap.
  double? productPrice,
  UnitDetailsSaver? onSave,
}) {
  return showAdaptiveFormSurface<UnitDetailsDraft>(
    context: context,
    title: title,
    builder: (context) => UnitDetailsForm(
      definitions: definitions,
      attributes: attributes,
      editAttributes: editAttributes,
      editWarranty: editWarranty,
      warrantyOverride: warrantyOverride,
      editListPrice: editListPrice,
      listPrice: listPrice,
      productPrice: productPrice,
      onSave: onSave,
    ),
  );
}

class UnitDetailsForm extends StatefulWidget {
  const UnitDetailsForm({
    super.key,
    required this.definitions,
    required this.attributes,
    required this.editAttributes,
    required this.editWarranty,
    this.warrantyOverride,
    this.editListPrice = false,
    this.listPrice,
    this.productPrice,
    this.onSave,
  });

  final List<UnitAttributeDefinition> definitions;
  final Map<String, Object?> attributes;
  final bool editAttributes;
  final bool editWarranty;
  final DateTime? warrantyOverride;
  final bool editListPrice;
  final double? listPrice;
  final double? productPrice;
  final UnitDetailsSaver? onSave;

  @override
  State<UnitDetailsForm> createState() => _UnitDetailsFormState();
}

class _UnitDetailsFormState extends State<UnitDetailsForm> {
  late Map<String, Object?> _values = Map<String, Object?>.from(
    widget.attributes,
  );
  late DateTime? _warranty = widget.warrantyOverride;
  late final TextEditingController _price = TextEditingController(
    text: widget.listPrice?.toStringAsFixed(2) ?? '',
  );
  Map<String, String> _errors = const {};
  String _message = '';
  bool _saving = false;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final errors = <String, String>{
      if (widget.editAttributes)
        ...validateUnitAttributes(widget.definitions, _values, l10n),
    };
    final priceText = _price.text.trim();
    final price = priceText.isEmpty ? null : double.tryParse(priceText);
    if (widget.editListPrice &&
        priceText.isNotEmpty &&
        (price == null || price < 0)) {
      errors['list_price'] = l10n.unitDetailsPriceInvalid;
    }
    if (errors.isNotEmpty) {
      setState(() {
        _errors = errors;
        _message = '';
      });
      return;
    }
    final draft = UnitDetailsDraft(
      attributes: _values,
      warrantyOverride: _warranty,
      listPrice: widget.editListPrice ? price : widget.listPrice,
    );
    final save = widget.onSave;
    if (save == null) {
      Navigator.of(context).pop(draft);
      return;
    }
    setState(() {
      _saving = true;
      _errors = const {};
      _message = '';
    });
    final outcome = await save(draft);
    if (!mounted) return;
    if (outcome.isSaved) {
      Navigator.of(context).pop(draft);
      return;
    }
    setState(() {
      _saving = false;
      _errors = outcome.fieldErrors;
      _message = outcome.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                spacing.md,
                spacing.sm,
                spacing.md,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_message.isNotEmpty) ...[
                    PointyInlineMessage.error(message: _message, compact: true),
                    SizedBox(height: spacing.sm),
                  ],
                  if (widget.editListPrice) ...[
                    _ListPriceField(
                      controller: _price,
                      productPrice: widget.productPrice,
                      error: _errors['list_price'],
                      enabled: !_saving,
                    ),
                    if (widget.editAttributes || widget.editWarranty) ...[
                      SizedBox(height: spacing.md),
                      const Divider(height: 1),
                      SizedBox(height: spacing.md),
                    ],
                  ],
                  if (widget.editAttributes)
                    if (widget.definitions.isEmpty)
                      Text(
                        l10n.unitAttributesNoDefinitions,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.mutedInk,
                        ),
                      )
                    else
                      UnitAttributeForm(
                        definitions: widget.definitions,
                        values: _values,
                        errors: _errors,
                        enabled: !_saving,
                        onChanged: (values) => setState(() {
                          _values = values;
                        }),
                      ),
                  if (widget.editWarranty) ...[
                    if (widget.editAttributes) ...[
                      SizedBox(height: spacing.md),
                      const Divider(height: 1),
                      SizedBox(height: spacing.md),
                    ],
                    UnitDateField(
                      key: const ValueKey('unit-warranty-override'),
                      label: l10n.unitWarrantyOverrideLabel,
                      helperText: l10n.unitWarrantyOverrideHelp,
                      value: _warranty,
                      error: _errors['warranty_override_expires_on'],
                      enabled: !_saving,
                      onChanged: (value) => setState(() => _warranty = value),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                SizedBox(width: spacing.sm),
                FilledButton.icon(
                  key: const ValueKey('unit-details-save'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(l10n.saveButton),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// This one article's selling price, typed as it is described. Blank sells it
/// at the product's price, which the hint names.
class _ListPriceField extends StatelessWidget {
  const _ListPriceField({
    required this.controller,
    required this.productPrice,
    required this.error,
    required this.enabled,
  });

  final TextEditingController controller;
  final double? productPrice;
  final String? error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final price = productPrice;
    return TextField(
      key: const ValueKey('unit-details-list-price'),
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textDirection: TextDirection.ltr,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(
        labelText: l10n.unitDetailsPriceLabel,
        prefixIcon: const Icon(Icons.sell_outlined),
        helperText: price == null
            ? l10n.unitDetailsPriceHelpNoProductPrice
            : l10n.unitDetailsPriceHelp(formatMoney(price)),
        helperMaxLines: 2,
        errorText: error,
      ),
    );
  }
}
