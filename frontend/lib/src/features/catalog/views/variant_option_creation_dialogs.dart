import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/variant_option.dart';
import '../../../data/models/variant_option_draft.dart';
import '../../../data/models/variant_option_value.dart';
import '../../../data/models/variant_option_value_draft.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/design/design.dart';
import '../../../shared/components/pointy_progress.dart';

Future<VariantOption?> showCreateVariantOptionDialog({
  required BuildContext context,
  required CatalogRepository catalogRepository,
  required List<VariantOption> existingOptions,
}) {
  return showDialog<VariantOption>(
    context: context,
    builder: (_) => _CreateVariantOptionDialog(
      catalogRepository: catalogRepository,
      displayOrder: _nextDisplayOrder(existingOptions),
    ),
  );
}

Future<VariantOptionValue?> showCreateVariantOptionValueDialog({
  required BuildContext context,
  required CatalogRepository catalogRepository,
  required VariantOption option,
}) {
  return showDialog<VariantOptionValue>(
    context: context,
    builder: (_) => _CreateVariantOptionValueDialog(
      catalogRepository: catalogRepository,
      option: option,
      displayOrder: _nextDisplayOrder(option.values),
    ),
  );
}

class _CreateVariantOptionDialog extends StatefulWidget {
  const _CreateVariantOptionDialog({
    required this.catalogRepository,
    required this.displayOrder,
  });

  final CatalogRepository catalogRepository;
  final int displayOrder;

  @override
  State<_CreateVariantOptionDialog> createState() =>
      _CreateVariantOptionDialogState();
}

class _CreateVariantOptionDialogState
    extends State<_CreateVariantOptionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  var _isSaving = false;
  var _hasError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.newVariantOptionTitle),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.variantOptionNameLabel,
                hintText: l10n.variantOptionNameHint,
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _codeController,
              decoration: InputDecoration(
                labelText: l10n.variantOptionCodeLabel,
                hintText: l10n.variantOptionCodeHint,
              ),
            ),
            if (_hasError) ...[
              const SizedBox(height: 8),
              Text(
                l10n.variantOptionCreateError,
                style: TextStyle(color: context.pointyColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : _submit,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(l10n.createVariantOptionButton),
        ),
      ],
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _hasError = false;
    });

    final result = await widget.catalogRepository.createVariantOption(
      VariantOptionDraft(
        name: _nameController.text.trim(),
        code: _cleanCode(_codeController.text, fallbackPrefix: 'option'),
        displayOrder: widget.displayOrder,
      ),
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<VariantOption>():
        Navigator.of(context).pop(result.value);
      case Error<VariantOption>():
        setState(() {
          _isSaving = false;
          _hasError = true;
        });
    }
  }
}

class _CreateVariantOptionValueDialog extends StatefulWidget {
  const _CreateVariantOptionValueDialog({
    required this.catalogRepository,
    required this.option,
    required this.displayOrder,
  });

  final CatalogRepository catalogRepository;
  final VariantOption option;
  final int displayOrder;

  @override
  State<_CreateVariantOptionValueDialog> createState() =>
      _CreateVariantOptionValueDialogState();
}

class _CreateVariantOptionValueDialogState
    extends State<_CreateVariantOptionValueDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  var _isSaving = false;
  var _hasError = false;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.newVariantOptionValueTitle),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.variantOptionValueNameLabel,
                hintText: l10n.variantOptionValueNameHint,
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _codeController,
              decoration: InputDecoration(
                labelText: l10n.variantOptionValueCodeLabel,
                hintText: l10n.variantOptionValueCodeHint,
              ),
            ),
            if (_hasError) ...[
              const SizedBox(height: 8),
              Text(
                l10n.variantOptionValueCreateError,
                style: TextStyle(color: context.pointyColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : _submit,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(l10n.createVariantOptionValueButton),
        ),
      ],
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _hasError = false;
    });

    final result = await widget.catalogRepository.createVariantOptionValue(
      VariantOptionValueDraft(
        optionId: widget.option.id,
        name: _nameController.text.trim(),
        code: _cleanCode(_codeController.text, fallbackPrefix: 'value'),
        displayOrder: widget.displayOrder,
      ),
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<VariantOptionValue>():
        Navigator.of(context).pop(result.value);
      case Error<VariantOptionValue>():
        setState(() {
          _isSaving = false;
          _hasError = true;
        });
    }
  }
}

int _nextDisplayOrder(List<dynamic> items) {
  var highest = 0;
  for (final item in items) {
    final order = switch (item) {
      VariantOption(:final displayOrder) => displayOrder,
      VariantOptionValue(:final displayOrder) => displayOrder,
      _ => 0,
    };
    if (order > highest) {
      highest = order;
    }
  }
  return highest + 10;
}

String _cleanCode(String value, {required String fallbackPrefix}) {
  final normalized = value.trim().toLowerCase();
  final matches = RegExp(r'[a-z0-9]+').allMatches(normalized);
  final cleaned = matches.map((match) => match.group(0)!).join('-');
  if (cleaned.isNotEmpty) {
    return cleaned;
  }
  return '$fallbackPrefix-${DateTime.now().millisecondsSinceEpoch}';
}
