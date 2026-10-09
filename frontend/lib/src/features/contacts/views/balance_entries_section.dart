import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/balance_entry.dart';
import '../../../data/models/money_source.dart';
import '../../../data/models/sale_order.dart' show PaymentMethod;
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/balance_labels.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payment_labels.dart';
import '../../../shared/payments/record_payment_dialog.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/balance_entries_view_model.dart';
import 'account_money_actions.dart';
import 'balance_entry_dialogs.dart';

/// One customer's, supplier's or employee's account: «استلام مبلغ» and
/// «دفع مبلغ», the opening balance, and every entry written on it — listed for
/// anyone who may see them, withdrawn by whoever may.
///
/// Owns its view model: the details screens only need to know when the
/// account changed, which [onChanged] tells them.
class BalanceEntriesSection extends StatefulWidget {
  const BalanceEntriesSection({
    super.key,
    required this.repository,
    required this.party,
    required this.partyId,
    required this.canManage,
    required this.canCancel,
    this.canUseDrawer = false,
    this.canUseTreasury = false,
    this.cashPayable = 0,
    this.cashCollectable = 0,
    this.receive,
    this.pay,
    this.onChanged,
  });

  final ContactRepository repository;
  final BalanceParty party;
  final int partyId;
  final bool canManage;
  final bool canCancel;

  /// Whether this user may move cash through their own drawer.
  final bool canUseDrawer;

  /// Whether this user may move money through the treasury: the cash box, or
  /// a bank account by transfer.
  final bool canUseTreasury;

  /// What the shop can pay out now: a customer's credit, an employee's dues.
  /// Read by the host screen from its own figures, which [onChanged]
  /// refreshes after every write.
  final double cashPayable;

  /// What the shop can take in now: a supplier's credit, an employee's debt.
  final double cashCollectable;

  /// The host's own way of moving money on this side, when the account has
  /// one — a customer's collection, a supplier's account payment. Otherwise
  /// the side is settled as a balance refund ([cashPayable] /
  /// [cashCollectable]) where the party has one.
  final AccountMoneyFlow? receive;
  final AccountMoneyFlow? pay;
  final Future<void> Function()? onChanged;

  @override
  State<BalanceEntriesSection> createState() => _BalanceEntriesSectionState();
}

class _BalanceEntriesSectionState extends State<BalanceEntriesSection> {
  late final BalanceEntriesViewModel _viewModel = BalanceEntriesViewModel(
    repository: widget.repository,
    party: widget.party,
    partyId: widget.partyId,
    onChanged: widget.onChanged,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Set<MoneySource> get _cashSources => {
    if (widget.canUseDrawer) MoneySource.drawer,
    if (widget.canUseTreasury) MoneySource.treasury,
  };

  /// A side settled as a balance refund. Only where the party has such a
  /// side: a customer's credit paid out, a supplier paying back, an employee
  /// either way. Needs the right to write balances, and somewhere for the
  /// money to go.
  AccountMoneyFlow? _refundFlow(AppLocalizations l10n, {required bool paying}) {
    final available = paying ? widget.cashPayable : widget.cashCollectable;
    final hasSide = switch (widget.party) {
      BalanceParty.customer => paying,
      BalanceParty.supplier => !paying,
      BalanceParty.employee => true,
    };
    if (!hasSide || !widget.canManage || _cashSources.isEmpty) {
      return null;
    }
    final settles = paying
        ? BalanceDirection.weOweThem
        : BalanceDirection.theyOweUs;
    return AccountMoneyFlow(
      available: available,
      methods: [
        for (final method in [
          PaymentMethod.cash,
          // A transfer never passes a drawer: it is the treasury's.
          if (widget.canUseTreasury) PaymentMethod.transfer,
        ])
          RecordPaymentMethodOption(
            apiValue: method.apiValue,
            label: paymentMethodLabel(l10n, method),
            icon: paymentMethodIcon(method),
            usesBankAccount: method != PaymentMethod.cash,
          ),
      ],
      showNotes: true,
      onSubmit: (result) async {
        final failure = await _viewModel.refund(
          result.amount,
          note: result.notes,
          // Only an employee's account runs both ways; for the others the
          // side is the only one there is.
          settles: widget.party == BalanceParty.employee ? settles : null,
          method: result.methodApiValue,
          source: result.source,
          moneyAccountId: result.moneyAccountId,
        );
        return failure == null
            ? null
            : balanceFailureMessage(
                l10n,
                failure,
                fallback: l10n.accountMoneyError,
              );
      },
    );
  }

  Future<void> _writeOpening() async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await showBalanceEntryDialog(
      context,
      party: widget.party,
      kind: BalanceEntryKind.opening,
      onSubmit: _viewModel.create,
    );
    if (saved && mounted) {
      _snack(l10n.balanceEntrySaved);
    }
  }

  Future<void> _cancel(BalanceEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final cancelled = await showCancelBalanceEntryDialog(
      context,
      entry: entry,
      onSubmit: (reason) => _viewModel.cancel(entry, reason),
    );
    if (cancelled && mounted) {
      _snack(l10n.balanceEntryCancelled);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final viewModel = _viewModel;
        final busy = viewModel.isSaving || viewModel.isLoading;
        final money = AccountMoneyActions(
          receive: widget.receive ?? _refundFlow(l10n, paying: false),
          pay: widget.pay ?? _refundFlow(l10n, paying: true),
          cashSources: _cashSources,
          onAccountOnly: widget.canManage ? viewModel.create : null,
          offersDeductionLimit: widget.party == BalanceParty.employee,
          busy: busy,
        );
        final offersOpening =
            widget.canManage &&
            !viewModel.hasLiveOpening &&
            !viewModel.isLoading;
        return PointyDetailSection(
          title: l10n.balanceEntriesTitle,
          icon: Icons.account_balance_wallet_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (money.hasActions || offersOpening) ...[
                Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (money.hasActions) money,
                    if (offersOpening)
                      OutlinedButton.icon(
                        key: const ValueKey('add_opening_balance_button'),
                        onPressed: busy ? null : _writeOpening,
                        icon: const Icon(Icons.flag_outlined),
                        label: Text(l10n.addOpeningBalanceButton),
                      ),
                  ],
                ),
                SizedBox(height: spacing.md),
              ],
              _BalanceEntriesList(
                viewModel: viewModel,
                party: widget.party,
                canCancel: widget.canCancel,
                onCancel: _cancel,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BalanceEntriesList extends StatelessWidget {
  const _BalanceEntriesList({
    required this.viewModel,
    required this.party,
    required this.canCancel,
    required this.onCancel,
  });

  final BalanceEntriesViewModel viewModel;
  final BalanceParty party;
  final bool canCancel;
  final ValueChanged<BalanceEntry> onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.entries.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasError && viewModel.entries.isEmpty) {
      return PointyInlineMessage.error(message: l10n.balanceEntriesLoadError);
    }
    if (viewModel.entries.isEmpty) {
      return PointyEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.balanceEntriesEmpty,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in viewModel.entries) ...[
          _BalanceEntryRow(
            entry: entry,
            party: party,
            onCancel: canCancel && entry.canCancel && !viewModel.isSaving
                ? () => onCancel(entry)
                : null,
          ),
          SizedBox(height: spacing.xs),
        ],
        if (viewModel.hasMore)
          Align(
            alignment: AlignmentDirectional.center,
            child: TextButton(
              onPressed: viewModel.isLoadingMore ? null : viewModel.loadMore,
              child: viewModel.isLoadingMore
                  ? const SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : Text(l10n.balanceEntriesLoadMoreButton),
            ),
          ),
      ],
    );
  }
}

class _BalanceEntryRow extends StatelessWidget {
  const _BalanceEntryRow({
    required this.entry,
    required this.party,
    this.onCancel,
  });

  final BalanceEntry entry;
  final BalanceParty party;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final owedToUs = entry.direction == BalanceDirection.theyOweUs;
    final tone = entry.isCancelled
        ? colors.mutedInk
        : entry.isRefund
        ? colors.ink
        : owedToUs
        ? colors.warning
        : colors.success;

    return PointyDataRow(
      key: ValueKey('balance_entry_${entry.id}'),
      leading: Icon(
        entry.isRefund
            ? Icons.payments_outlined
            : balanceDirectionIcon(entry.direction),
        color: tone,
      ),
      title: balanceEntryTitle(l10n, party, entry),
      subtitle: [
        entry.number,
        ?balanceSettledThrough(l10n, entry),
        if (entry.effectiveDate != null)
          l10n.balanceEntryEffectiveValue(formatDate(entry.effectiveDate!)),
        if (entry.note.isNotEmpty) entry.note,
        if (!entry.isCancelled &&
            !entry.isRefund &&
            entry.settledAmount > 0.005) ...[
          l10n.balanceEntrySettledValue(formatMoney(entry.settledAmount)),
          l10n.balanceEntryRemainingValue(formatMoney(entry.remainingAmount)),
        ],
        if (!entry.isCancelled && entry.payrollDeductionLimit != null)
          l10n.balanceDeductionLimitValue(
            formatMoney(entry.payrollDeductionLimit!),
          ),
        if (!entry.isCancelled && entry.scheduledAmount > 0.005)
          l10n.balanceScheduledValue(formatMoney(entry.scheduledAmount)),
        if (entry.createdByUsername.isNotEmpty)
          l10n.balanceEntryCreatedByValue(entry.createdByUsername),
        if (entry.isCancelled && entry.cancelReason.isNotEmpty)
          l10n.balanceEntryCancelReasonValue(entry.cancelReason),
      ].join(' • '),
      badges: [
        if (entry.isCancelled)
          PointyStatusPill(
            label: l10n.balanceEntryCancelledBadge,
            icon: Icons.block_outlined,
            color: colors.mutedInk,
          ),
      ],
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatMoney(entry.amount),
            style: TextStyle(
              color: tone,
              fontWeight: FontWeight.w600,
              decoration: entry.isCancelled
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
            ),
          ),
          if (onCancel != null)
            IconButton(
              key: ValueKey('cancel_balance_entry_${entry.id}'),
              tooltip: l10n.balanceEntryCancelAction,
              icon: const Icon(Icons.undo_outlined),
              onPressed: onCancel,
            ),
        ],
      ),
    );
  }
}
