import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_account_row.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/money_position_view_model.dart';
import 'treasury_ui.dart';

/// Money crossing the boundary of the business, in either direction.
///
/// The owner bringing cash in to fund the shop, and the owner taking money out
/// for themselves. Both were already expressible — a transfer with one side
/// left as "outside the shop" — and both were unfindable, because that is a
/// sentence about a dropdown's null option rather than a thing anyone came to
/// the screen to do. This is the same write with the question asked out loud.
///
/// The hint is not decoration. "إضافة رصيد" looks like income and "سحب" looks
/// like an expense, and neither is: capital in is not a sale and a draw is not
/// a cost. A shop that files them as either gets a profit figure that is wrong
/// by exactly the amount the owner moved.
enum MoneyFundingDirection { addFunds, withdraw }

Future<void> showMoneyFundingSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  required MoneyFundingDirection direction,
  int? accountId,
}) {
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => _MoneyFundingSheet(
      viewModel: viewModel,
      direction: direction,
      accountId: accountId,
    ),
  );
}

class _MoneyFundingSheet extends StatefulWidget {
  const _MoneyFundingSheet({
    required this.viewModel,
    required this.direction,
    this.accountId,
  });

  final MoneyPositionViewModel viewModel;
  final MoneyFundingDirection direction;
  final int? accountId;

  @override
  State<_MoneyFundingSheet> createState() => _MoneyFundingSheetState();
}

class _MoneyFundingSheetState extends State<_MoneyFundingSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();

  int? _accountId;
  bool _submitting = false;

  bool get _isAddingFunds => widget.direction == MoneyFundingDirection.addFunds;

  @override
  void initState() {
    super.initState();
    // The cash box: money an owner brings in or takes out is almost always
    // cash in hand, and the picker is one tap away when it is not.
    _accountId =
        widget.accountId ??
        widget.viewModel.accounts
            .where((entry) => entry.account.isCash)
            .map((entry) => entry.account.id)
            .firstOrNull ??
        widget.viewModel.accounts.map((entry) => entry.account.id).firstOrNull;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final accountId = _accountId;
    if (accountId == null) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);

    final saved = await widget.viewModel.recordTransfer(
      MoneyTransferDraft(
        amount: double.parse(_amountController.text.trim()),
        // One side only. That absent side IS the statement: money with no
        // account behind it came from outside the business, which is what
        // makes capital and a draw different from moving the takings to
        // the bank.
        fromAccountId: _isAddingFunds ? null : accountId,
        toAccountId: _isAddingFunds ? accountId : null,
        reason: _reasonController.text.trim(),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    if (!saved) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.treasuryTransferFailed)),
      );
      return;
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _isAddingFunds
              ? l10n.treasuryAddFundsSaved
              : l10n.treasuryWithdrawSaved,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      top: false,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySectionHeader(
                title: _isAddingFunds
                    ? l10n.treasuryAddFundsTitle
                    : l10n.treasuryWithdrawTitle,
              ),
              SizedBox(height: spacing.sm),
              PointyDetailCallout(
                icon: _isAddingFunds
                    ? Icons.savings_outlined
                    : Icons.outbox_outlined,
                tone: PointyCalloutTone.neutral,
                title: _isAddingFunds
                    ? l10n.treasuryAddFundsHint
                    : l10n.treasuryWithdrawHint,
              ),
              SizedBox(height: spacing.md),
              _AccountField(
                label: _isAddingFunds
                    ? l10n.treasuryAddFundsTo
                    : l10n.treasuryWithdrawFrom,
                accounts: widget.viewModel.accounts,
                value: _accountId,
                onChanged: (value) => setState(() => _accountId = value),
              ),
              SizedBox(height: spacing.sm),
              TextFormField(
                key: const ValueKey('money_funding_amount_field'),
                controller: _amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: l10n.treasuryAddFundsAmount,
                ),
                validator: (value) {
                  final parsed = double.tryParse(value?.trim() ?? '');
                  if (parsed == null || parsed <= 0) {
                    return l10n.treasuryAmountInvalid;
                  }
                  return null;
                },
              ),
              SizedBox(height: spacing.sm),
              TextFormField(
                key: const ValueKey('money_funding_reason_field'),
                controller: _reasonController,
                decoration: InputDecoration(
                  labelText: l10n.treasuryAddFundsReason,
                ),
              ),
              if (_isAddingFunds) ...[
                SizedBox(height: spacing.sm),
                // The three reasons money comes in from outside, so the common
                // case is a tap and the ledger reads in whole words later.
                Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.xs,
                  children: [
                    for (final preset in [
                      l10n.treasuryAddFundsReasonCapital,
                      l10n.treasuryAddFundsReasonOwner,
                      l10n.treasuryAddFundsReasonLoan,
                    ])
                      ActionChip(
                        key: ValueKey('money_funding_reason_$preset'),
                        label: Text(preset),
                        onPressed: () =>
                            setState(() => _reasonController.text = preset),
                      ),
                  ],
                ),
              ],
              SizedBox(height: spacing.md),
              FilledButton.icon(
                key: const ValueKey('money_funding_submit_button'),
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : Icon(_isAddingFunds ? Icons.add : Icons.arrow_outward),
                label: Text(
                  _isAddingFunds
                      ? l10n.treasuryAddFundsSubmit
                      : l10n.treasuryWithdrawSubmit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which account the money lands in — or leaves. Unlike the transfer sheet's
/// picker there is no "outside the shop" option: that side is already decided
/// by which button opened this sheet.
class _AccountField extends StatelessWidget {
  const _AccountField({
    required this.label,
    required this.accounts,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<MoneyAccountPosition> accounts;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int?>(
      key: const ValueKey('money_funding_account_field'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final entry in accounts)
          DropdownMenuItem<int?>(
            value: entry.account.id,
            child: entry.account.isCash
                ? Row(
                    children: [
                      Icon(treasuryAccountIcon(entry.account), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${entry.account.name} · '
                          '${formatMoney(entry.expectedBalance)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : BankAccountRow(
                    account: entry.account.asRef,
                    compact: true,
                    markSize: 20,
                  ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
