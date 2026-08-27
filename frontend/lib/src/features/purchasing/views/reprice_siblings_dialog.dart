import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/purchase_view_model.dart';
import '../../../shared/components/pointy_progress.dart';

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
  double? _suggestedPrice;
  late final double _baseUnitCost = _computeBaseUnitCost();
  bool _loading = true;
  bool _submitting = false;

  /// The line's cost expressed per base unit. [PurchaseDraftLine.unitCost] is per
  /// the selected purchase unit (e.g. per carton), but selling prices are stored
  /// per base unit, so the recommendation must be based on the base-unit cost.
  double _computeBaseUnitCost() {
    final line = widget.line;
    final factor = line.unitFactor > 0 ? line.unitFactor : 1;
    return line.unitCost / factor;
  }

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
      _baseUnitCost,
      productId: line.variant.productId,
    );
    if (!mounted) {
      return;
    }
    final variants = siblings.isEmpty ? [line.variant] : siblings;
    for (final variant in variants) {
      // Pre-fill with the variant's *current* price so that leaving the dialog
      // untouched never overwrites a real price with the recommendation — the
      // suggestion is applied only when the user taps it.
      _controllers[variant.id] = TextEditingController(
        text: variant.unitPrice.toStringAsFixed(2),
      );
    }
    setState(() {
      _variants = variants;
      _markupPercent = suggestion.markupPercent;
      _suggestedPrice = suggestion.suggestedPrice;
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
            ? const SizedBox(height: 96, child: Center(child: PointySpinner()))
            : Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.repriceSiblingsSubtitle(formatMoney(_baseUnitCost)),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
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
                                  suggestedPrice: _suggestedPrice,
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
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _submitting || _loading || _variants.isEmpty
              ? null
              : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: PointySpinner(strokeWidth: 2),
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
    this.suggestedPrice,
  });

  final ProductVariant variant;
  final TextEditingController controller;
  final FormFieldValidator<String> validator;

  /// Recommended base-unit price for this product, if the shop has enough data.
  /// Offered as an opt-in — tapping applies it; the field itself defaults to the
  /// variant's current price so nothing is overwritten unless the user chooses.
  final double? suggestedPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    final suggestion = suggestedPrice;
    // Only offer the suggestion when it differs from the current price.
    final showSuggestion =
        suggestion != null && (suggestion - variant.unitPrice).abs() >= 0.005;

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
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 160,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: [DecimalTextInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.changePricesNewPriceLabel,
                  prefixIcon: const Icon(Icons.sell_outlined),
                ),
                validator: validator,
              ),
              if (showSuggestion) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () {
                      controller.text = suggestion.toStringAsFixed(2);
                      controller.selection = TextSelection.collapsed(
                        offset: controller.text.length,
                      );
                    },
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(
                      l10n.repriceSiblingsUseSuggested(formatMoney(suggestion)),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
