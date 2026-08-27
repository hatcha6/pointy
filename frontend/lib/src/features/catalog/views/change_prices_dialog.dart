import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/product_details_view_model.dart';
import '../../../shared/components/pointy_progress.dart';

/// Opens the "Change prices" dialog for a product: every variant is listed with
/// its lowest/highest/last cost (read-only) and an editable new-price field so
/// the owner can reprice with full context. Returns true when prices were saved.
Future<bool?> showChangePricesDialog(
  BuildContext context,
  ProductDetailsViewModel viewModel,
) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => _ChangePricesDialog(viewModel: viewModel),
  );
}

class _ChangePricesDialog extends StatefulWidget {
  const _ChangePricesDialog({required this.viewModel});

  final ProductDetailsViewModel viewModel;

  @override
  State<_ChangePricesDialog> createState() => _ChangePricesDialogState();
}

class _ChangePricesDialogState extends State<_ChangePricesDialog> {
  final _formKey = GlobalKey<FormState>();
  final Map<int, TextEditingController> _controllers = {};
  late List<VariantCostSummary> _rows;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Prefer the loaded cost summaries (they carry costs); fall back to the
    // product's variants so the dialog still works before the summary lands.
    final summaries = widget.viewModel.costSummaries;
    if (summaries.isNotEmpty) {
      _rows = summaries;
    } else {
      _rows = [
        for (final variant in widget.viewModel.variants)
          VariantCostSummary(
            productId: widget.viewModel.product.id,
            variantId: variant.id,
            variantName: variant.displayLabel,
            unitPrice: variant.unitPrice,
            purchasesCount: 0,
          ),
      ];
    }
    for (final row in _rows) {
      _controllers[row.variantId] = TextEditingController(
        text: row.unitPrice.toStringAsFixed(2),
      );
    }
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
    // Only send prices that actually changed.
    final changes = <int, double>{};
    for (final row in _rows) {
      final newPrice = parseDecimal(_controllers[row.variantId]!.text);
      if (newPrice != null && newPrice != row.unitPrice) {
        changes[row.variantId] = newPrice;
      }
    }
    if (changes.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final success = await widget.viewModel.setVariantPrices(changes);
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
      title: Text(l10n.changePricesTitle),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.changePricesSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
              const SizedBox(height: 12),
              if (_rows.isEmpty)
                Text(l10n.changePricesNoVariants)
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (var i = 0; i < _rows.length; i++) ...[
                          if (i > 0) const Divider(height: 24),
                          _PriceRow(
                            summary: _rows[i],
                            controller: _controllers[_rows[i].variantId]!,
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
          onPressed: _submitting || _rows.isEmpty ? null : _submit,
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

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.summary,
    required this.controller,
    required this.validator,
  });

  final VariantCostSummary summary;
  final TextEditingController controller;
  final FormFieldValidator<String> validator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final empty = l10n.shopSettingsEmptyValue;
    String money(double? value) => value == null ? empty : formatMoney(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          summary.variantName.isEmpty
              ? l10n.productPriceTitle
              : summary.variantName,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _CostChip(label: l10n.lowestCostLabel, value: money(summary.lowestCost)),
            _CostChip(label: l10n.highestCostLabel, value: money(summary.highestCost)),
            _CostChip(label: l10n.lastCostLabel, value: money(summary.lastCost)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  '${l10n.currentPriceLabel}: ${formatMoney(summary.unitPrice)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 160,
              child: TextFormField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
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
        ),
      ],
    );
  }
}

class _CostChip extends StatelessWidget {
  const _CostChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
        ),
        Text(value, style: textTheme.titleSmall),
      ],
    );
  }
}
