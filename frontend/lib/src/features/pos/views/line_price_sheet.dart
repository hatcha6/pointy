import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/formatters.dart';

/// Change what one cart line sells for, before the sale.
///
/// A shop asked for this because the alternative was walking to the products
/// screen mid-sale to change a price for one customer — which changes it for
/// everyone, and is the wrong edit. This one is per line, per sale, and the
/// server records what the line would otherwise have sold for.
///
/// Returns the new per-unit price, or [_clearedPrice] when the cashier put the
/// line back on the shop's own price. Null means they cancelled — which is not
/// the same as clearing, and collapsing the two would make "reset" impossible
/// to reach from a sheet that can also be dismissed.
Future<double?> showLinePriceSheet(
  BuildContext context, {
  required CartLine line,
  double? unitCost,
}) {
  return showAdaptiveFormSurface<double>(
    context: context,
    size: AdaptiveModalSize.compact,
    builder: (context) => Padding(
      // The keyboard covers a bottom sheet on a phone-sized till, and this
      // sheet is nothing but a field and two buttons.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _LinePriceForm(line: line, unitCost: unitCost),
    ),
  );
}

/// What a cleared price resolves to. Negative so it can never be mistaken for
/// a real one; callers translate it to null.
const double clearedLinePrice = -1;

class _LinePriceForm extends StatefulWidget {
  const _LinePriceForm({required this.line, this.unitCost});

  final CartLine line;
  final double? unitCost;

  @override
  State<_LinePriceForm> createState() => _LinePriceFormState();
}

class _LinePriceFormState extends State<_LinePriceForm> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.line.unitPrice.toStringAsFixed(2);
    // Focused with the whole value selected, so the first digit a cashier
    // types replaces the price instead of landing next to it. They open this
    // to say a NEW number, essentially always — clearing the field by hand
    // first is a step, and a step at the counter with a customer waiting.
    _controller = TextEditingController.fromValue(
      TextEditingValue(
        text: current,
        selection: TextSelection(baseOffset: 0, extentOffset: current.length),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _typed =>
      double.tryParse(_controller.text.trim().replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final cost = widget.unitCost;
    final typed = _typed;
    final belowCost = cost != null && typed != null && typed < cost;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.editLinePriceTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.line.variant.productLabel,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('line_price_field'),
            controller: _controller,
            autofocus: true,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            onChanged: (_) => setState(() => _error = null),
            onFieldSubmitted: (_) => _submit(l10n),
            decoration: InputDecoration(
              labelText: l10n.editLinePriceFieldLabel,
              errorText: _error,
              prefixIcon: const Icon(Icons.sell_outlined),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.editLinePriceListPrice(formatMoney(widget.line.listUnitPrice)),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (cost != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.cartLineCostLabel(formatMoney(cost)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
          if (belowCost) ...[
            const SizedBox(height: 12),
            // A warning, not a block. Whether selling under cost is allowed at
            // all is the shop's `prevent_selling_at_loss` setting, enforced
            // server-side at checkout; this is so the cashier knows before the
            // customer does rather than meeting a refusal at payment.
            PointyInlineMessage.warning(
              message: l10n.editLinePriceBelowCostWarning,
              compact: true,
            ),
          ],
          const SizedBox(height: 20),
          // Reset above rather than beside: three buttons on one row in a
          // compact dialog overflowed it by 111 pixels, and the one that
          // disappeared off the edge was the way back to the shop's own price.
          // It is also a different kind of action from the other two, which is
          // why it reads better on its own line.
          if (widget.line.isRepriced)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('line_price_reset'),
                onPressed: () => Navigator.of(context).pop(clearedLinePrice),
                icon: const Icon(Icons.undo, size: 18),
                label: Text(l10n.editLinePriceReset),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancelButton),
              ),
              FilledButton(
                key: const ValueKey('line_price_save'),
                onPressed: () => _submit(l10n),
                child: Text(l10n.confirmButton),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _submit(AppLocalizations l10n) {
    final value = _typed;
    // Zero is a real price — a warranty replacement handed over at no charge —
    // so only a missing or negative number is rejected.
    if (value == null || value < 0) {
      setState(() => _error = l10n.editLinePriceInvalid);
      return;
    }
    Navigator.of(context).pop(value);
  }
}
