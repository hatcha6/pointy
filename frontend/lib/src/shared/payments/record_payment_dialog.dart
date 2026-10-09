import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/parsing.dart';
import '../../data/models/money_source.dart';
import '../../data/models/purchase_submission.dart' show SupplierPaymentMethod;
import '../../data/models/money_position.dart';
import '../../data/models/sale_order.dart' show PaymentMethod;
import '../../features/pos/views/payment/card_receipt_validation_dialog.dart';
import '../formatters.dart';
import '../payment_labels.dart';
import '../../features/treasury/view_models/bank_routing.dart';
import '../components/pointy_choice_buttons.dart';
import '../opening_balance_fields.dart'
    show DeductionLimitField, parseDeductionLimit;
import 'bank_account_picker.dart';
import '../tutor/anchors.dart';
import '../tutor/tutor_target.dart';

/// One selectable payment method in [RecordPaymentDialog]. Method-enum agnostic
/// (carries the backend api value as a string) so the same dialog serves
/// customer (`PaymentMethod`) and supplier (`SupplierPaymentMethod`) flows.
class RecordPaymentMethodOption {
  const RecordPaymentMethodOption({
    required this.apiValue,
    required this.label,
    required this.icon,
    this.allowsCardReceipt = false,
    this.usesBankAccount = false,
    this.accountOnly = false,
  });

  /// «بدون مبلغ نقدي»: nothing changes hands, the amount is only written on
  /// the account. Uncapped (there is no money to run out of), and it must say
  /// why, the way an adjustment always has.
  factory RecordPaymentMethodOption.accountOnly(AppLocalizations l10n) {
    return RecordPaymentMethodOption(
      apiValue: accountOnlyMethodApiValue,
      label: l10n.paymentMethodAccountOnly,
      icon: Icons.edit_note_outlined,
      accountOnly: true,
    );
  }

  static const accountOnlyMethodApiValue = 'account_only';

  final String apiValue;
  final String label;
  final IconData icon;

  /// When true and this method is chosen, the dialog scans + validates the POS
  /// terminal receipt (Moamalat QR) before resolving, capturing its URL. Used
  /// for customer card collections (money IN); left false for supplier card
  /// pay-outs (money OUT — there's no shop-terminal receipt to scan).
  final bool allowsCardReceipt;

  /// Whether this method moves money through a bank account the shop can name.
  /// Cash never does (it is the drawer), and neither does supplier credit,
  /// which is a promise rather than a payment.
  final bool usesBankAccount;

  /// No money moves; see [RecordPaymentMethodOption.accountOnly].
  final bool accountOnly;

  /// Notes and coins: the one method that can go through a drawer.
  bool get isCash => !usesBankAccount && !accountOnly && apiValue == 'cash';
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
    this.moneyAccountId,
    this.source = MoneySource.drawer,
    this.payrollDeductionLimit,
  });

  /// Nothing changed hands: the amount is only written on the account.
  bool get isAccountOnly =>
      methodApiValue == RecordPaymentMethodOption.accountOnlyMethodApiValue;

  final String methodApiValue;
  final double amount;
  final String reference;
  final String notes;
  final String cardReceiptUrl;
  final bool printProof;

  /// Which of the shop's bank accounts the money moved through. Null on cash,
  /// and whenever the shop has not configured accounts worth choosing between.
  final int? moneyAccountId;

  /// Through the payer's own drawer, or the treasury. Cash takes what was
  /// chosen; bank money is the treasury's whenever the user may use it.
  final MoneySource source;

  /// An employee's debt recorded without money: the most one payroll run
  /// takes of it. Null means as much as the pay can carry.
  final double? payrollDeductionLimit;
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
  Set<MoneySource> cashSources = const {MoneySource.drawer},
  bool offersDeductionLimit = false,
}) {
  // The shop's bank accounts, read from the ambient routing store. Absent in
  // previews and tests, and empty until an owner configures more than the one
  // account every install is seeded with — in both cases this dialog is
  // exactly what it was.
  final bankAccounts = BankRoutingScope.accountsOf(context);
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
      bankAccounts: bankAccounts,
      cashSources: cashSources,
      offersDeductionLimit: offersDeductionLimit,
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
    required this.bankAccounts,
    required this.cashSources,
    required this.offersDeductionLimit,
  });

  final String title;
  final double maxAmount;
  final List<RecordPaymentMethodOption> methods;
  final String? balanceLabel;
  final bool showReference;
  final bool showNotes;
  final String? proofToggleLabel;
  final List<String> trustedCardTerminalIds;
  final List<MoneyAccount> bankAccounts;

  /// Where cash may move. Both offered only to someone who may use the
  /// treasury; a cashier sees no choice and pays through their drawer.
  final Set<MoneySource> cashSources;

  /// An employee's debt recorded without money comes off their wage, so it
  /// may say how much one payroll run takes.
  final bool offersDeductionLimit;

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  late String _method = widget.methods.first.apiValue;
  late final TextEditingController _amountController = TextEditingController(
    text: widget.maxAmount > 0.005 ? widget.maxAmount.toStringAsFixed(2) : '',
  );
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _limitController = TextEditingController();
  bool _showAmountError = false;
  bool _printProof = false;
  bool _showNotesError = false;
  late MoneySource _source = widget.cashSources.contains(MoneySource.drawer)
      ? MoneySource.drawer
      : MoneySource.treasury;
  late int? _moneyAccountId = BankAccountPicker.initialSelection(
    widget.bankAccounts,
  );

  RecordPaymentMethodOption get _selectedMethod =>
      widget.methods.firstWhere((option) => option.apiValue == _method);

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    _limitController.dispose();
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
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.paymentMethodLabel),
                items: [
                  for (final option in widget.methods)
                    DropdownMenuItem(
                      value: option.apiValue,
                      child: Row(
                        children: [
                          Icon(option.icon, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              option.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
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
              if (_selectedMethod.accountOnly) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.accountOnlyHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_selectedMethod.isCash && widget.cashSources.length > 1) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.moneySourceLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                PointyChoiceButtons<MoneySource>(
                  key: const ValueKey('record_payment_source'),
                  options: [
                    PointyChoiceOption(
                      value: MoneySource.drawer,
                      label: l10n.moneySourceDrawer,
                      icon: Icons.point_of_sale_outlined,
                    ),
                    PointyChoiceOption(
                      value: MoneySource.treasury,
                      label: l10n.moneySourceTreasury,
                      icon: Icons.savings_outlined,
                    ),
                  ],
                  value: _source,
                  onChanged: (source) => setState(() => _source = source),
                ),
              ],
              // Only for the methods that reach a bank. A cash collection has
              // no account to name, and offering one would invite an answer
              // the server is right to refuse.
              if (_selectedMethod.usesBankAccount &&
                  BankAccountPicker.isUseful(widget.bankAccounts)) ...[
                const SizedBox(height: 12),
                BankAccountPicker(
                  accounts: widget.bankAccounts,
                  selectedId: _moneyAccountId,
                  onChanged: (value) => setState(() => _moneyAccountId = value),
                  dense: true,
                ),
              ],
              const SizedBox(height: 12),
              TutorTarget(
                anchor: TutorAnchor.recordPaymentAmountField,
                child: TextField(
                  key: const ValueKey('record_payment_amount_field'),
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  // The error names the ceiling rather than just refusing: the
                  // supplier flow passes no balance line at all, so without the
                  // number the cashier is told there is a limit they were never
                  // shown.
                  decoration: InputDecoration(
                    labelText: l10n.invoicePaymentAmountLabel,
                    errorText: !_showAmountError
                        ? null
                        : _selectedMethod.accountOnly
                        ? l10n.balanceEntryAmountInvalid
                        : l10n.recordPaymentAmountMaxError(
                            formatMoney(widget.maxAmount),
                          ),
                  ),
                  onChanged: (_) {
                    if (_showAmountError) {
                      setState(() => _showAmountError = false);
                    }
                  },
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
              // Required without money: an amount written on an account with
              // no reason is exactly what somebody later asks about.
              if (widget.showNotes || _selectedMethod.accountOnly) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('record_payment_notes_field'),
                  controller: _notesController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: _selectedMethod.accountOnly
                        ? l10n.balanceEntryNoteLabel
                        : l10n.supplierPaymentNotesLabel,
                    errorText: _showNotesError
                        ? l10n.balanceEntryNoteRequired
                        : null,
                  ),
                  onChanged: (_) {
                    if (_showNotesError) {
                      setState(() => _showNotesError = false);
                    }
                  },
                ),
              ],
              if (widget.offersDeductionLimit &&
                  _selectedMethod.accountOnly) ...[
                const SizedBox(height: 12),
                DeductionLimitField(
                  key: const ValueKey('record_payment_limit_field'),
                  controller: _limitController,
                ),
              ],
              if (widget.proofToggleLabel != null &&
                  !_selectedMethod.accountOnly) ...[
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
        TutorTarget(
          anchor: TutorAnchor.recordPaymentConfirmButton,
          child: FilledButton(
            key: const ValueKey('record_payment_confirm'),
            onPressed: _submit,
            child: Text(l10n.confirmButton),
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final method = _selectedMethod;
    final amount = parseDecimal(_amountController.text);
    if (amount == null ||
        amount <= 0 ||
        (!method.accountOnly && amount > widget.maxAmount + 0.005)) {
      setState(() => _showAmountError = true);
      return;
    }
    if (method.accountOnly && _notesController.text.trim().isEmpty) {
      setState(() => _showNotesError = true);
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
        printProof:
            widget.proofToggleLabel != null &&
            _printProof &&
            !method.accountOnly,
        moneyAccountId: method.usesBankAccount ? _moneyAccountId : null,
        payrollDeductionLimit: widget.offersDeductionLimit && method.accountOnly
            ? parseDeductionLimit(_limitController.text)
            : null,
        source: method.isCash
            ? _source
            : widget.cashSources.contains(MoneySource.treasury)
            ? MoneySource.treasury
            : MoneySource.drawer,
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
        usesBankAccount: method != PaymentMethod.cash,
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
        // Supplier credit is a promise, not money leaving a bank.
        usesBankAccount:
            method == SupplierPaymentMethod.transfer ||
            method == SupplierPaymentMethod.card,
      ),
  ];
}
