part of 'purchase_order_details_screen.dart';

class _SupplierPaymentDialog extends StatefulWidget {
  const _SupplierPaymentDialog({required this.order});

  final PurchaseOrder order;

  @override
  State<_SupplierPaymentDialog> createState() => _SupplierPaymentDialogState();
}

class _SupplierPaymentDialogState extends State<_SupplierPaymentDialog> {
  late SupplierPaymentMethod _method = SupplierPaymentMethod.cash;
  late final TextEditingController _amountController = TextEditingController(
    text: widget.order.balanceDue.toStringAsFixed(2),
  );
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  bool _showAmountError = false;

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final methods = const [
      SupplierPaymentMethod.cash,
      SupplierPaymentMethod.transfer,
      SupplierPaymentMethod.card,
      SupplierPaymentMethod.supplierCredit,
    ];

    return AlertDialog(
      icon: const Icon(Icons.account_balance_wallet_outlined),
      title: Text(l10n.supplierPaymentTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<SupplierPaymentMethod>(
                initialValue: _method,
                decoration: InputDecoration(labelText: l10n.paymentMethodLabel),
                items: [
                  for (final method in methods)
                    DropdownMenuItem(
                      value: method,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_supplierPaymentMethodIcon(method), size: 18),
                          const SizedBox(width: 8),
                          Text(_supplierPaymentMethodLabel(l10n, method)),
                        ],
                      ),
                    ),
                ],
                onChanged: (method) {
                  if (method == null) {
                    return;
                  }
                  setState(() => _method = method);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentAmountLabel,
                  errorText: _showAmountError
                      ? l10n.supplierPaymentPositiveAmountError
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _referenceController,
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentReferenceLabel,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: l10n.supplierPaymentNotesLabel,
                ),
                maxLines: 2,
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
        FilledButton(onPressed: _submit, child: Text(l10n.confirmButton)),
      ],
    );
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null ||
        amount <= 0 ||
        amount > widget.order.balanceDue + 0.005) {
      setState(() => _showAmountError = true);
      return;
    }
    Navigator.of(context).pop(
      _SupplierPaymentDialogResult(
        method: _method,
        amount: amount,
        reference: _referenceController.text.trim(),
        notes: _notesController.text.trim(),
      ),
    );
  }
}

class _SupplierPaymentDialogResult {
  const _SupplierPaymentDialogResult({
    required this.method,
    required this.amount,
    required this.reference,
    required this.notes,
  });

  final SupplierPaymentMethod method;
  final double amount;
  final String reference;
  final String notes;
}
