import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/balance_entry.dart';
import '../../../data/models/money_source.dart';
import '../../../shared/balance_labels.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/responsive/responsive.dart';

/// One way real money moves on an account: what can move now, by which
/// methods, and what recording it does. A customer's collection, a supplier's
/// account payment, or a balance settled in cash are each one of these.
class AccountMoneyFlow {
  const AccountMoneyFlow({
    required this.available,
    required this.methods,
    required this.onSubmit,
    this.availableLabel,
    this.showReference = false,
    this.showNotes = false,
    this.proofToggleLabel,
    this.loadTrustedCardTerminalIds,
  });

  /// The most real money this flow can move now; nothing above it.
  final double available;
  final List<RecordPaymentMethodOption> methods;

  /// Records the money: null once recorded, or why it was refused, in words.
  final Future<String?> Function(RecordPaymentResult result) onSubmit;
  final String? availableLabel;
  final bool showReference;
  final bool showNotes;
  final String? proofToggleLabel;
  final Future<List<String>> Function()? loadTrustedCardTerminalIds;

  bool get canMove => available > 0.005 && methods.isNotEmpty;
}

/// «استلام مبلغ» and «دفع مبلغ» on a customer's, supplier's or employee's
/// account, named from the shop's side. Each opens one dialog that moves real
/// money — through the drawer or the treasury — or, offered to whoever may
/// write balances, records an amount on the account with none changing hands.
///
/// What a recorded amount without money means follows from the button: the
/// shop received value, so the party is owed (`weOweThem`); or the shop gave
/// it, so the party owes (`theyOweUs`).
class AccountMoneyActions extends StatelessWidget {
  const AccountMoneyActions({
    super.key,
    this.receive,
    this.pay,
    this.cashSources = const {MoneySource.drawer},
    this.onAccountOnly,
    this.offersDeductionLimit = false,
    this.busy = false,
  });

  final AccountMoneyFlow? receive;
  final AccountMoneyFlow? pay;

  /// Where cash may move for this user: their drawer, the treasury, or both.
  final Set<MoneySource> cashSources;

  /// Writes an amount on the account with no money moving. Null when this
  /// user may not write balances, which takes the option out of the dialogs.
  final Future<BalanceFailure?> Function(BalanceEntryDraft draft)?
  onAccountOnly;

  /// An employee's account: a debt recorded on it without money may say how
  /// much one payroll run takes.
  final bool offersDeductionLimit;
  final bool busy;

  bool _offers(AccountMoneyFlow? flow) =>
      (flow?.canMove ?? false) || onAccountOnly != null;

  /// Whether either button would show — hosts leave the row out otherwise.
  bool get hasActions => _offers(receive) || _offers(pay);

  Future<void> _open(BuildContext context, {required bool receiving}) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final flow = receiving ? receive : pay;
    final moves = flow?.canMove ?? false;
    final trusted = moves && flow!.loadTrustedCardTerminalIds != null
        ? await flow.loadTrustedCardTerminalIds!()
        : const <String>[];
    if (!context.mounted) {
      return;
    }
    final result = await showRecordPaymentDialog(
      context,
      title: receiving
          ? l10n.accountReceiveMoneyButton
          : l10n.accountPayMoneyButton,
      maxAmount: moves ? flow!.available : 0,
      balanceLabel: !moves
          ? l10n.accountMoneyNothingDue
          : flow!.availableLabel ??
                (receiving
                    ? l10n.accountMoneyReceivableValue(
                        formatMoney(flow.available),
                      )
                    : l10n.accountMoneyPayableValue(
                        formatMoney(flow.available),
                      )),
      methods: [
        if (moves) ...flow!.methods,
        if (onAccountOnly != null) RecordPaymentMethodOption.accountOnly(l10n),
      ],
      showReference: moves && flow!.showReference,
      showNotes: moves && flow!.showNotes,
      proofToggleLabel: moves ? flow!.proofToggleLabel : null,
      trustedCardTerminalIds: trusted,
      cashSources: cashSources,
      // Only a debt — «دفع مبلغ» without money — comes off the wage.
      offersDeductionLimit: offersDeductionLimit && !receiving,
    );
    if (result == null || !context.mounted) {
      return;
    }

    String? error;
    if (result.isAccountOnly) {
      final failure = await onAccountOnly!(
        BalanceEntryDraft(
          kind: BalanceEntryKind.adjustment,
          direction: receiving
              ? BalanceDirection.weOweThem
              : BalanceDirection.theyOweUs,
          amount: result.amount,
          note: result.notes,
          payrollDeductionLimit: result.payrollDeductionLimit,
        ),
      );
      if (failure != null) {
        error = balanceFailureMessage(
          l10n,
          failure,
          fallback: l10n.accountMoneyError,
        );
      }
    } else {
      error = await flow!.onSubmit(result);
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(error ?? l10n.accountMoneySaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Wrap(
      spacing: spacing.sm,
      runSpacing: spacing.sm,
      children: [
        if (_offers(receive))
          FilledButton.tonalIcon(
            key: const ValueKey('account_receive_money_button'),
            onPressed: busy ? null : () => _open(context, receiving: true),
            icon: const Icon(Icons.south_west_rounded),
            label: Text(l10n.accountReceiveMoneyButton),
          ),
        if (_offers(pay))
          FilledButton.tonalIcon(
            key: const ValueKey('account_pay_money_button'),
            onPressed: busy ? null : () => _open(context, receiving: false),
            icon: const Icon(Icons.north_east_rounded),
            label: Text(l10n.accountPayMoneyButton),
          ),
      ],
    );
  }
}
