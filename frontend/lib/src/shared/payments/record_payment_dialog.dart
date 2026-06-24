import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/parsing.dart';
import '../../data/models/purchase_submission.dart' show SupplierPaymentMethod;
import '../../data/models/sale_order.dart' show PaymentMethod;
import '../../features/pos/views/payment/card_receipt_validation_dialog.dart';
import '../payment_labels.dart';

/// One selectable payment method in [RecordPaymentDialog]. Method-enum agnostic
/// (carries the backend api value as a string) so the same dialog serves
/// customer (`PaymentMethod`) and supplier (`SupplierPaymentMethod`) flows.
class RecordPaymentMethodOption {
  const RecordPaymentMethodOption({
    required this.apiValue,
    required this.label,
    required this.icon,
    this.allowsCardReceipt = false,
  });

  final String apiValue;
  final String label;
  final IconData icon;

  /// When true and this method is chosen, the dialog scans + validates the POS
  /// terminal receipt (Moamalat QR) before resolving, capturing its URL. Used
  /// for customer card collections (money IN); left false for supplier card
  /// pay-outs (money OUT — there's no shop-terminal receipt to scan).
  final bool allowsCardReceipt;
}

/// The cashier's intent from [RecordPaymentDialog]. Printing/idempotency are the
/// caller's concern — the dialog just returns what was entered.
class RecordPaymentResult {
  const RecordPaymentResult({
    required this.methodApiValue,
    required this.amount,
    this.reference = '',
    this.notes = '',
    this.cardReceiptUrl = '',
    this.printProof = false,
  });

  final String methodApiValue;
  final double amount;
  final String reference;
  final String notes;
  final String cardReceiptUrl;
  final bool printProof;
}

/// The single record-payment dialog shared by every flow (customer per-invoice,
/// customer account, supplier). Supports cash/card/transfer/credit methods, the
/// terminal-receipt QR scan for card collections, an optional proof-of-payment
/// print toggle, and optional reference/notes — all toggled per call site.
Future<RecordPaymentResult?> showRecordPaymentDialog(
  BuildContext context, {
  required String title,
  required double maxAmount,
  required List<RecordPaymentMethodOption> methods,
  String? balanceLabel,
  bool showReference = false,
  bool showNotes = false,
  String? proofToggleLabel,
  List<String> trustedCardTerminalIds = const [],
}) {
  return showDialog<RecordPaymentResult>(
    context: context,
    builder: (_) => _RecordPaymentDialog(
      title: title,
      maxAmount: maxAmount,
      methods: methods,
      balanceLabel: balanceLabel,
      showReference: showReference,
      showNotes: showNotes,
      proofToggleLabel: proofToggleLabel,
      trustedCardTerminalIds: trustedCardTerminalIds,
    ),
  );
}

class _RecordPaymentDialog extends StatefulWidget {
  const _RecordPaymentDialog({
    required this.title,
    required this.maxAmount,
    required this.methods,
    required this.balanceLabel,
    required this.showReference,
    required this.showNotes,
    required this.proofToggleLabel,
    required this.trustedCardTerminalIds,
  });

  final String title;
  final double maxAmount;
  final List<RecordPaymentMethodOption> methods;
  final String? balanceLabel;
  final bool showReference;
  final bool showNotes;
  final String? proofToggleLabel;
  final List<String> trustedCardTerminalIds;

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  late String _method = widget.methods.first.apiValue;
  late final TextEditingController _amountController = TextEditingController(
    text: widget.maxAmount.toStringAsFixed(2),
  );
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  bool _showAmountError = false;
  bool _printProof = false;

  RecordPaymentMethodOption get _selectedMethod =>
      widget.methods.firstWhere((option) => option.apiValue == _method);

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

    return AlertDialog(
      icon: const Icon(Icons.account_balance_wallet_outlined),
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.balanceLabel != null) ...[
                Text(
                  widget.balanceLabel!,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<String>(
                key: const ValueKey('record_payment_method_field'),
                initialValue: _method,
                decoration: InputDecoration(labelText: l10n.paymentMethodLabel),
                items: [
                  for (final option in widget.methods)
                    DropdownMenuItem(
                      value: option.apiValue,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(option.icon, size: 18),
                          const SizedBox(width: 8),
                          Text(option.label),
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
                key: const ValueKey('record_payment_amount_field'),
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l10n.invoicePaymentAmountLabel,
                  errorText: _showAmountError
                      ? l10n.invoicePaymentAmountError
                      : null,
                ),
              ),
              if (widget.showReference) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _referenceController,
                  decoration: InputDecoration(
                    labelText: l10n.invoicePaymentReferenceLabel,
                  ),
                ),
              ],
              if (widget.showNotes) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _notesController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.supplierPaymentNotesLabel,
                  ),
                ),
              ],
              if (widget.proofToggleLabel != null) ...[
                const SizedBox(height: 4),
                SwitchListTile(
                  key: const ValueKey('record_payment_print_proof_toggle'),
                  contentPadding: EdgeInsets.zero,
                  value: _printProof,
                  onChanged: (value) => setState(() => _printProof = value),
                  title: Text(widget.proofToggleLabel!),
                  secondary: const Icon(Icons.receipt_outlined),
                ),
              ],
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

  Future<void> _submit() async {
    final amount = parseDecimal(_amountController.text);
    if (amount == null || amount <= 0 || amount > widget.maxAmount + 0.005) {
      setState(() => _showAmountError = true);
      return;
    }

    // Card collections must be backed by a validated terminal receipt — scan it
    // (reusing the POS receipt dialog) and capture its URL before resolving.
    var cardReceiptUrl = '';
    if (_selectedMethod.allowsCardReceipt) {
      final receipt = await showCardReceiptValidationDialog(
        context: context,
        expectedAmount: amount,
        trustedTerminalIds: widget.trustedCardTerminalIds,
      );
      if (receipt == null || !mounted) {
        return;
      }
      cardReceiptUrl = receipt.sourceUrl;
    }

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(
      RecordPaymentResult(
        methodApiValue: _method,
        amount: amount,
        reference: _referenceController.text.trim(),
        notes: _notesController.text.trim(),
        cardReceiptUrl: cardReceiptUrl,
        printProof: widget.proofToggleLabel != null && _printProof,
      ),
    );
  }
}

/// The standard customer payment methods — cash, card (with terminal-receipt
/// scan for proof), transfer — shared by the per-invoice and account collection
/// flows so they're always identical.
List<RecordPaymentMethodOption> customerPaymentMethodOptions(
  AppLocalizations l10n,
) {
  return [
    for (final method in const [
      PaymentMethod.cash,
      PaymentMethod.card,
      PaymentMethod.transfer,
    ])
      RecordPaymentMethodOption(
        apiValue: method.apiValue,
        label: paymentMethodLabel(l10n, method),
        icon: paymentMethodIcon(method),
        allowsCardReceipt: method == PaymentMethod.card,
      ),
  ];
}

/// The supplier payment methods — cash, transfer, card, supplier credit. Card
/// pay-outs are money OUT (the shop pays the supplier), so there's no
/// shop-terminal receipt to scan and [allowsCardReceipt] stays false for all.
List<RecordPaymentMethodOption> supplierPaymentMethodOptions(
  AppLocalizations l10n,
) {
  return [
    for (final method in const [
      SupplierPaymentMethod.cash,
      SupplierPaymentMethod.transfer,
      SupplierPaymentMethod.card,
      SupplierPaymentMethod.supplierCredit,
    ])
      RecordPaymentMethodOption(
        apiValue: method.apiValue,
        label: supplierPaymentMethodLabel(l10n, method),
        icon: supplierPaymentMethodIcon(method),
      ),
  ];
}
