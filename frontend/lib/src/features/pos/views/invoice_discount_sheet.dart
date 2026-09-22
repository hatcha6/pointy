import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/formatters.dart';

/// Take a flat amount off the whole invoice, mid-sale.
///
/// The counter equivalent of the one-off discount a purchase order already has
/// — the haggle, the rounded-down total, the regular who gets five dinars off.
/// It is not the discount engine: no rule, no coupon, no eligibility, just a
/// number the cashier decided on and is accountable for.
///
/// The shop bounds it with `ShopSettings.maxInvoiceDiscountAmount`, and this
/// sheet enforces that bound while the cashier types rather than letting
/// checkout refuse the sale afterwards. The server enforces it again, because a
/// limit that only lives in the client is not a limit.
///
/// [roomOnTheSale] is what this cart can still carry: its value **less
/// whatever the shop's own rules and coupons already took off it**, not its
/// subtotal. On a cart a rule has already discounted, the two are different
/// numbers and the subtotal is the wrong one — it would tell the cashier a
/// bigger discount is available than the sale can actually absorb.
///
/// Returns the new amount (0 to clear it), or null if the cashier backed out.
Future<double?> showInvoiceDiscountSheet(
  BuildContext context, {
  required double currentAmount,
  required double roomOnTheSale,
  double? limit,
}) {
  return showAdaptiveFormSurface<double>(
    context: context,
    size: AdaptiveModalSize.compact,
    builder: (context) => Padding(
      // The keyboard covers a bottom sheet on a phone-sized till, and this
      // sheet is nothing but a field and two buttons.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _InvoiceDiscountForm(
        currentAmount: currentAmount,
        roomOnTheSale: roomOnTheSale,
        limit: limit,
      ),
    ),
  );
}

class _InvoiceDiscountForm extends StatefulWidget {
  const _InvoiceDiscountForm({
    required this.currentAmount,
    required this.roomOnTheSale,
    this.limit,
  });

  final double currentAmount;
  final double roomOnTheSale;
  final double? limit;

  @override
  State<_InvoiceDiscountForm> createState() => _InvoiceDiscountFormState();
}

class _InvoiceDiscountFormState extends State<_InvoiceDiscountForm> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    // Pre-selected, like the reprice sheet: a cashier opens this to say a NEW
    // number, so the first digit they type should replace what is there rather
    // than land beside it. Empty when there is no discount yet, so the field
    // does not start with a 0.00 to delete.
    final current = widget.currentAmount > 0
        ? widget.currentAmount.toStringAsFixed(2)
        : '';
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

  double get _typed {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) {
      return 0;
    }
    return value;
  }

  /// Over the shop's ceiling. Blocks the save — this is the one the owner set.
  bool get _isOverLimit {
    final limit = widget.limit;
    return limit != null && _typed > limit;
  }

  /// More than the goods are worth. Not an error: the server takes what the
  /// sale can carry and the notice below says so, which is friendlier at a
  /// counter than refusing a round number the cashier meant as "make it free".
  bool get _exceedsCart => _typed > widget.roomOnTheSale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final limit = widget.limit;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.invoiceDiscountDialogTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.invoiceDiscountFieldHint,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('invoice_discount_field'),
            controller: _controller,
            autofocus: true,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            onChanged: (_) => setState(() {}),
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.invoiceDiscountFieldLabel,
              prefixIcon: const Icon(Icons.discount_outlined),
              errorText: _isOverLimit
                  ? l10n.invoiceDiscountOverLimitError(formatMoney(limit!))
                  : null,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.invoiceDiscountCartTotal(formatMoney(widget.roomOnTheSale)),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (limit != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.invoiceDiscountLimitHint(formatMoney(limit)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
          if (_exceedsCart && !_isOverLimit) ...[
            const SizedBox(height: 12),
            PointyInlineMessage.warning(
              message: l10n.invoiceDiscountCappedNotice(
                formatMoney(widget.roomOnTheSale),
              ),
              compact: true,
            ),
          ],
          const SizedBox(height: 20),
          // Clear on its own line, above the pair: it is a different kind of
          // action, and three buttons in a row overflow this compact surface.
          if (widget.currentAmount > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('invoice_discount_clear'),
                onPressed: () => Navigator.of(context).pop(0.0),
                icon: const Icon(Icons.undo, size: 18),
                label: Text(l10n.invoiceDiscountClearAction),
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
                key: const ValueKey('invoice_discount_save'),
                onPressed: _isOverLimit ? null : _submit,
                child: Text(l10n.saveButton),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (_isOverLimit) {
      return;
    }
    Navigator.of(context).pop(_typed);
  }
}
