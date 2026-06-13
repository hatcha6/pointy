import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/units.dart';

/// Asks for the weight/volume of a metric product before it enters the cart.
///
/// Returns the quantity in the product's base unit (kg, l, …) or null.
Future<double?> showWeightEntrySheet(
  BuildContext context, {
  required ProductVariant variant,
  double? initialQuantity,
}) {
  return showDialog<double>(
    context: context,
    builder: (dialogContext) => _WeightEntryDialog(
      variant: variant,
      initialQuantity: initialQuantity,
    ),
  );
}

class _WeightEntryDialog extends StatefulWidget {
  const _WeightEntryDialog({required this.variant, this.initialQuantity});

  final ProductVariant variant;
  final double? initialQuantity;

  @override
  State<_WeightEntryDialog> createState() => _WeightEntryDialogState();
}

class _WeightEntryDialogState extends State<_WeightEntryDialog> {
  late final TextEditingController _controller;
  var _showError = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialQuantity == null
          ? ''
          : formatQuantity(widget.initialQuantity!),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _quantity => double.tryParse(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final quantity = _quantity;
    final total = quantity == null
        ? null
        : widget.variant.unitPrice * quantity;

    return AlertDialog(
      icon: const Icon(Icons.scale_outlined),
      title: Text(widget.variant.displayLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.posWeightDialogTitle,
              suffixText: unitLabel(l10n, widget.variant.unit),
              errorText: _showError ? l10n.posWeightInvalid : null,
            ),
            onChanged: (_) => setState(() => _showError = false),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Text(
            '${formatMoney(widget.variant.unitPrice)}'
            ' / ${unitLabel(l10n, widget.variant.unit)}'
            '${total == null ? '' : ' = ${formatMoney(total)}'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.confirmButton),
        ),
      ],
    );
  }

  void _submit() {
    final quantity = _quantity;
    if (quantity == null || quantity <= 0) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(context).pop(quantity);
  }
}
