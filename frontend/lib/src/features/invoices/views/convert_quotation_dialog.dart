import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';

/// The outcome of the convert-quotation dialog: the chosen sale type and an
/// optional down-payment. For a standard sale the amount equals the total (paid
/// in full); for a credit sale it is an optional partial down-payment.
class ConvertQuotationResult {
  const ConvertQuotationResult({required this.saleType, this.amountReceived});

  final SaleType saleType;
  final double? amountReceived;
}

/// Converts an OPEN quotation into a standard or credit sale. A standard sale is
/// prefilled to the full total (and must be paid in full per the backend); a
/// credit sale may take an optional down-payment.
class ConvertQuotationDialog extends StatefulWidget {
  const ConvertQuotationDialog({super.key, required this.order});

  final SaleOrder order;

  @override
  State<ConvertQuotationDialog> createState() => _ConvertQuotationDialogState();
}

class _ConvertQuotationDialogState extends State<ConvertQuotationDialog> {
  SaleType _saleType = SaleType.standard;
  late final TextEditingController _amountController = TextEditingController(
    text: widget.order.total.toStringAsFixed(2),
  );
  bool _showAmountError = false;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  bool get _isStandard => _saleType == SaleType.standard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      icon: const Icon(Icons.swap_horiz_outlined),
      title: Text(l10n.convertQuotationDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.convertQuotationSaleTypeLabel,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              SegmentedButton<SaleType>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: SaleType.standard,
                    label: Text(l10n.convertQuotationSaleTypeStandard),
                  ),
                  ButtonSegment(
                    value: SaleType.credit,
                    label: Text(l10n.convertQuotationSaleTypeCredit),
                  ),
                ],
                selected: {_saleType},
                onSelectionChanged: (selection) {
                  setState(() {
                    _saleType = selection.first;
                    _showAmountError = false;
                    // Standard must be paid in full; prefill the total. Credit
                    // takes an optional down-payment, so start it empty.
                    _amountController.text = _isStandard
                        ? widget.order.total.toStringAsFixed(2)
                        : '';
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amountController,
                enabled: !_isStandard,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: _isStandard
                      ? l10n.invoicePaymentBalanceValue(
                          formatMoney(widget.order.total),
                        )
                      : l10n.convertQuotationDownPaymentLabel,
                  helperText: _isStandard
                      ? l10n.convertQuotationStandardHint(
                          formatMoney(widget.order.total),
                        )
                      : l10n.convertQuotationDownPaymentHelper,
                  errorText: _showAmountError
                      ? l10n.invoicePaymentAmountError
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.convertQuotationConfirm),
        ),
      ],
    );
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;

    if (_isStandard) {
      // Paid in full: the backend requires amount_received == total.
      Navigator.of(context).pop(
        ConvertQuotationResult(
          saleType: SaleType.standard,
          amountReceived: widget.order.total,
        ),
      );
      return;
    }

    final raw = _amountController.text.trim();
    if (raw.isEmpty) {
      // Credit with no down-payment.
      Navigator.of(
        context,
      ).pop(const ConvertQuotationResult(saleType: SaleType.credit));
      return;
    }

    final amount = double.tryParse(raw);
    if (amount == null || amount < 0 || amount > widget.order.total + 0.005) {
      setState(() => _showAmountError = true);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.invoicePaymentAmountError)));
      return;
    }

    Navigator.of(context).pop(
      ConvertQuotationResult(
        saleType: SaleType.credit,
        amountReceived: amount > 0 ? amount : null,
      ),
    );
  }
}
