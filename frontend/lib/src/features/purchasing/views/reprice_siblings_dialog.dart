import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/purchase_view_model.dart';

/// Opens the reprice-siblings dialog for a purchase draft [line]: lists every
/// variant of the line's product with an editable selling price, pre-filled from
/// the line's (new) cost × the shop's typical markup, and writes the changed
/// prices back via [PurchaseViewModel.repriceProductVariants]. Returns true when
/// prices were saved.
Future<bool?> showRepriceSiblingsDialog(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required PurchaseDraftLine line,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _RepriceSiblingsDialog(viewModel: viewModel, line: line),
  );
}

class _RepriceSiblingsDialog extends StatefulWidget {
  const _RepriceSiblingsDialog({required this.viewModel, required this.line});

  final PurchaseViewModel viewModel;
  final PurchaseDraftLine line;

  @override
  State<_RepriceSiblingsDialog> createState() => _RepriceSiblingsDialogState();
}

class _RepriceSiblingsDialogState extends State<_RepriceSiblingsDialog> {
  final _formKey = GlobalKey<FormState>();
  final Map<int, TextEditingController> _controllers = {};
  List<ProductVariant> _variants = const [];
  double? _markupPercent;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final line = widget.line;
    // Siblings aren't embedded on the line's variant (the catalog summary omits
    // them), so fetch them; fall back to just this line's variant if the fetch
    // comes back empty so the dialog still works.
    final siblings = await widget.viewModel.loadSiblingVariants(
      line.variant.productId,
    );
    final suggestion = await widget.viewModel.loadPricingSuggestion(
      line.unitCost,
    );
    if (!mounted) {
      return;
    }
    final variants = siblings.isEmpty ? [line.variant] : siblings;
    for (final variant in variants) {
      final prefill = suggestion.suggestedPrice ?? variant.unitPrice;
      _controllers[variant.id] = TextEditingController(
        text: prefill.toStringAsFixed(2),
      );
    }
    setState(() {
      _variants = variants;
      _markupPercent = suggestion.markupPercent;
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _validatePrice(String? value) {
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.invalidNumber;
    }
    return null;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    // Send only the variants whose price actually changed.
    final changes = <int, double>{};
    for (final variant in _variants) {
      final newPrice = parseDecimal(_controllers[variant.id]!.text);
      if (newPrice != null && newPrice != variant.unitPrice) {
        changes[variant.id] = newPrice;
      }
    }
    if (changes.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final success = await widget.viewModel.repriceProductVariants(
      widget.line.variant.productId,
      changes,
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.changePricesSuccess : l10n.changePricesError,
        ),
      ),
    );
    if (success) {
      navigator.pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return AlertDialog(
      title: Text(l10n.repriceSiblingsTitle),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(
                height: 96,
                child: Center(child: CircularProgressIndicator()),
              )
            : Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.repriceSiblingsSubtitle(
                        formatMoney(widget.line.unitCost),
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                    if (_markupPercent != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        l10n.repriceSiblingsMarkupHint(
                          _markupPercent!.toStringAsFixed(0),
                        ),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_variants.isEmpty)
                      Text(l10n.changePricesNoVariants)
                    else
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (var i = 0; i < _variants.length; i++) ...[
                                if (i > 0) const Divider(height: 24),
                                _VariantPriceRow(
                                  variant: _variants[i],
                                  controller: _controllers[_variants[i].id]!,
                                  validator: _validatePrice,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _submitting || _loading || _variants.isEmpty ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.changePricesSaveButton),
        ),
      ],
    );
  }
}

class _VariantPriceRow extends StatelessWidget {
  const _VariantPriceRow({
    required this.variant,
    required this.controller,
    required this.validator,
  });

  final ProductVariant variant;
  final TextEditingController controller;
  final FormFieldValidator<String> validator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  variant.displayLabel.isEmpty
                      ? l10n.productPriceTitle
                      : variant.displayLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${l10n.currentPriceLabel}: ${formatMoney(variant.unitPrice)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 160,
          child: TextFormField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.changePricesNewPriceLabel,
              prefixIcon: const Icon(Icons.sell_outlined),
            ),
            validator: validator,
          ),
        ),
      ],
    );
  }
}
