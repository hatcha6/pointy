import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/unit_options.dart';
import '../../../shared/units.dart';

/// The unit + quantity chosen for a cart line.
class UnitQuantitySelection {
  const UnitQuantitySelection({required this.unit, required this.quantity});

  final UnitOption unit;
  final double quantity;
}

/// Fast unit + quantity picker. Shows a chip per sellable unit (default
/// preselected) and a quantity field, recomputing the per-unit price and total
/// live. For a single-unit product it is just a quantity entry. Returns the
/// selection, or null if dismissed.
Future<UnitQuantitySelection?> showUnitQuantitySheet(
  BuildContext context, {
  required Product product,
  required ProductVariant variant,
  String? initialUnitCode,
  double? initialQuantity,
}) {
  final options = sellableUnitOptions(
    AppLocalizations.of(context)!,
    product,
    variant.unitPrice,
  );
  return showModalBottomSheet<UnitQuantitySelection>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _UnitQuantitySheet(
      title: product.sellableName,
      options: options,
      initialUnitCode:
          initialUnitCode ??
          (product.defaultSaleUnit.isEmpty
              ? product.unit
              : product.defaultSaleUnit),
      initialQuantity: initialQuantity,
    ),
  );
}

class _UnitQuantitySheet extends StatefulWidget {
  const _UnitQuantitySheet({
    required this.title,
    required this.options,
    required this.initialUnitCode,
    this.initialQuantity,
  });

  final String title;
  final List<UnitOption> options;
  final String initialUnitCode;
  final double? initialQuantity;

  @override
  State<_UnitQuantitySheet> createState() => _UnitQuantitySheetState();
}

class _UnitQuantitySheetState extends State<_UnitQuantitySheet> {
  late final TextEditingController _controller;
  late UnitOption _unit;
  var _showError = false;

  @override
  void initState() {
    super.initState();
    _unit = defaultUnitOption(widget.options, widget.initialUnitCode);
    _controller = TextEditingController(
      text: widget.initialQuantity == null
          ? '1'
          : formatQuantity(widget.initialQuantity!),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _quantity => double.tryParse(_controller.text.trim());

  void _selectUnit(UnitOption unit) {
    setState(() {
      _unit = unit;
      _showError = false;
      // Drop any fraction when moving to a whole-only unit.
      if (!unit.allowsFractional) {
        final quantity = _quantity;
        if (quantity != null && quantity != quantity.roundToDouble()) {
          _controller.text = quantity.floor().clamp(1, 1 << 31).toString();
        }
      }
    });
  }

  void _nudge(int delta) {
    final current = _quantity ?? 0;
    final next = (current + delta).clamp(
      _unit.allowsFractional ? 0.0 : 1.0,
      1e9,
    );
    _controller.text = formatQuantity(next.toDouble());
    setState(() => _showError = false);
  }

  void _submit() {
    final quantity = _quantity;
    if (quantity == null || quantity <= 0) {
      setState(() => _showError = true);
      return;
    }
    if (!_unit.allowsFractional && quantity != quantity.roundToDouble()) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(
      context,
    ).pop(UnitQuantitySelection(unit: _unit, quantity: quantity));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final quantity = _quantity;
    final total = quantity == null ? null : _unit.unitPrice * quantity;
    final hasMultipleUnits = widget.options.length > 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            widget.title,
            style: theme.textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasMultipleUnits) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      l10n.posUnitSelectLabel,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Wrap(
                    spacing: spacing.sm,
                    runSpacing: spacing.sm,
                    children: [
                      for (final option in widget.options)
                        ChoiceChip(
                          label: Text(
                            '${option.label} · ${formatMoney(option.unitPrice)}',
                          ),
                          selected:
                              option.code == _unit.code &&
                              option.isBase == _unit.isBase,
                          onSelected: (_) => _selectUnit(option),
                        ),
                    ],
                  ),
                  SizedBox(height: spacing.md),
                ],
                Text(
                  l10n.posUnitQuantityLabel,
                  style: theme.textTheme.titleSmall,
                ),
                SizedBox(height: spacing.sm),
                Row(
                  children: [
                    _StepButton(icon: Icons.remove, onTap: () => _nudge(-1)),
                    SizedBox(width: spacing.sm),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.numberWithOptions(
                          decimal: _unit.allowsFractional,
                        ),
                        inputFormatters: _unit.allowsFractional
                            ? [DecimalTextInputFormatter()]
                            : [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          suffixText: _unit.label,
                          errorText: _showError ? l10n.posWeightInvalid : null,
                        ),
                        onChanged: (_) => setState(() => _showError = false),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    SizedBox(width: spacing.sm),
                    _StepButton(icon: Icons.add, onTap: () => _nudge(1)),
                  ],
                ),
                SizedBox(height: spacing.sm),
                _PriceLine(unit: _unit, quantity: quantity, total: total),
                SizedBox(height: spacing.md),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(
              l10n.posUnitSheetAdd(formatMoney(total ?? _unit.unitPrice)),
            ),
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
        child: Icon(icon),
      ),
    );
  }
}

class _PriceLine extends StatelessWidget {
  const _PriceLine({
    required this.unit,
    required this.quantity,
    required this.total,
  });

  final UnitOption unit;
  final double? quantity;
  final double? total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perUnit = '${formatMoney(unit.unitPrice)} / ${unit.label}';
    final totalText = total == null ? '' : ' = ${formatMoney(total!)}';
    return Text('$perUnit$totalText', style: theme.textTheme.titleSmall);
  }
}
