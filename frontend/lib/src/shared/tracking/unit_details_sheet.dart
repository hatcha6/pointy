import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/unit_attribute.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../responsive/responsive.dart';
import 'unit_attribute_form.dart';

/// What the details sheet hands back: the article's facts and, when it was
/// asked for, its own warranty end date (null = the product's days).
class UnitDetailsDraft {
  const UnitDetailsDraft({this.attributes = const {}, this.warrantyOverride});

  final Map<String, Object?> attributes;
  final DateTime? warrantyOverride;
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
/// The two halves are separately switchable because they are separately
/// permitted — describing a handset is counter work, promising a customer a
/// longer cover is not.
Future<UnitDetailsDraft?> showUnitDetailsSheet(
  BuildContext context, {
  required String title,
  List<UnitAttributeDefinition> definitions = const [],
  Map<String, Object?> attributes = const {},
  bool editAttributes = true,
  bool editWarranty = false,
  DateTime? warrantyOverride,
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
    this.onSave,
  });

  final List<UnitAttributeDefinition> definitions;
  final Map<String, Object?> attributes;
  final bool editAttributes;
  final bool editWarranty;
  final DateTime? warrantyOverride;
  final UnitDetailsSaver? onSave;

  @override
  State<UnitDetailsForm> createState() => _UnitDetailsFormState();
}

class _UnitDetailsFormState extends State<UnitDetailsForm> {
  late Map<String, Object?> _values = Map<String, Object?>.from(
    widget.attributes,
  );
  late DateTime? _warranty = widget.warrantyOverride;
  Map<String, String> _errors = const {};
  String _message = '';
  bool _saving = false;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final errors = widget.editAttributes
        ? validateUnitAttributes(widget.definitions, _values, l10n)
        : const <String, String>{};
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
