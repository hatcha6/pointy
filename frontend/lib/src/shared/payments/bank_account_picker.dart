import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/money_position.dart';
import '../design/design.dart';
import '../formatters.dart';
import 'bank_account_details_sheet.dart';
import 'bank_account_row.dart';

/// Which of the shop's bank accounts a card or transfer lands in.
///
/// ## When this is not shown at all
///
/// Almost always, and that is the point. A shop with the one generic bank
/// account every install is seeded with has nothing to choose between, and a
/// dropdown with a single option on the busiest screen in the shop is a step
/// added to every sale for no answer. [isUseful] is the test: more than one
/// account, or a single account the owner has actually identified (picked a
/// bank, typed an IBAN or an account number) and would therefore want to show
/// a customer.
///
/// ## Why it sends the account even when there is only one
///
/// An untagged payment follows whichever account is the default *today*. Pin
/// it, and a shop that later opens a second account and makes it the default
/// does not watch a year of card takings jump banks. So the moment the control
/// is shown, the answer travels with the payment.
class BankAccountPicker extends StatelessWidget {
  const BankAccountPicker({
    super.key,
    required this.accounts,
    required this.selectedId,
    required this.onChanged,
    this.autoSelectedTerminal,
    this.enabled = true,
    this.dense = false,
  });

  /// Active bank accounts, in the shop's own order.
  final List<MoneyAccount> accounts;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  /// The terminal whose slip chose this account, when one did. Shown so the
  /// cashier can see the till decided — and can tell, at a glance, that it
  /// decided the way they expected.
  final String? autoSelectedTerminal;

  final bool enabled;

  /// A tighter presentation for a dialog, where the picker is one field among
  /// several rather than a decision of its own.
  final bool dense;

  /// Whether this control has anything worth asking. See the class doc.
  static bool isUseful(List<MoneyAccount> accounts) {
    final active = accounts.where((account) => account.isActive).toList();
    if (active.length > 1) {
      return true;
    }
    return active.any(
      (account) =>
          account.bankSlug.isNotEmpty ||
          account.iban.isNotEmpty ||
          account.accountNumber.isNotEmpty,
    );
  }

  /// The account a fresh payment should start on: the shop's default, or its
  /// only account. Null when the control would not be shown at all.
  static int? initialSelection(List<MoneyAccount> accounts) {
    final active = accounts.where((account) => account.isActive).toList();
    if (active.isEmpty || !isUseful(active)) {
      return null;
    }
    for (final account in active) {
      if (account.isDefault) {
        return account.id;
      }
    }
    return active.first.id;
  }

  MoneyAccount? get _selected {
    for (final account in accounts) {
      if (account.id == selectedId) {
        return account;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final active = accounts.where((account) => account.isActive).toList();
    if (!isUseful(active)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final selected = _selected;

    final field = active.length == 1
        ? _SingleAccountField(account: active.first)
        : DropdownButtonFormField<int?>(
            key: const ValueKey('payment_bank_account_field'),
            initialValue: selectedId,
            isExpanded: true,
            decoration: InputDecoration(
              // No prefix icon: every row already carries its bank's own mark,
              // and a generic bank glyph beside it is the same statement twice
              // — once uselessly, in the place the eye lands first.
              labelText: l10n.paymentBankAccountLabel,
              isDense: dense,
            ),
            items: [
              for (final account in active)
                DropdownMenuItem<int?>(
                  value: account.id,
                  child: BankAccountRow(
                    account: account.asRef,
                    compact: true,
                    markSize: 20,
                  ),
                ),
            ],
            onChanged: enabled ? onChanged : null,
          );

    final canShowDetails =
        selected != null &&
        (selected.iban.isNotEmpty || selected.accountNumber.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        if (autoSelectedTerminal != null || canShowDetails) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (autoSelectedTerminal != null)
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 14,
                        color: colors.success,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          key: const ValueKey('payment_bank_account_auto'),
                          l10n.paymentBankAccountAuto(
                            ltrIsolated(autoSelectedTerminal!),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.success),
                        ),
                      ),
                    ],
                  ),
                )
              else
                const Spacer(),
              if (canShowDetails)
                TextButton.icon(
                  key: const ValueKey('payment_bank_account_details_button'),
                  onPressed: () =>
                      showBankAccountDetailsSheet(context, account: selected),
                  icon: const Icon(Icons.qr_code_2_outlined, size: 18),
                  label: Text(l10n.paymentBankAccountShowDetails),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One account, stated rather than asked. There is nothing to choose, but the
/// cashier — and the customer leaning over the counter — should still see
/// which bank this transfer is going to.
class _SingleAccountField extends StatelessWidget {
  const _SingleAccountField({required this.account});

  final MoneyAccount account;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return InputDecorator(
      key: const ValueKey('payment_bank_account_single'),
      decoration: InputDecoration(
        labelText: l10n.paymentBankAccountLabel,
        isDense: true,
      ),
      child: BankAccountRow(
        account: account.asRef,
        compact: true,
        markSize: 20,
      ),
    );
  }
}
