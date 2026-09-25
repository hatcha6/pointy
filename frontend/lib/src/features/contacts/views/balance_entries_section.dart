import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/balance_entry.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/balance_labels.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/balance_entries_view_model.dart';
import 'balance_entry_dialogs.dart';

/// The opening balance and adjustments on one customer's, supplier's or
/// employee's account — listed for anyone who may see them, written and
/// withdrawn by whoever may — and the cash that settles a side of it.
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
    this.canSettleInCash = false,
    this.cashPayable = 0,
    this.cashCollectable = 0,
    this.onChanged,
  });

  final ContactRepository repository;
  final BalanceParty party;
  final int partyId;
  final bool canManage;
  final bool canCancel;

  /// Whether this user may settle a side of the account in cash, through
  /// their own drawer.
  final bool canSettleInCash;

  /// What the shop can pay out now: a customer's credit, an employee's dues.
  /// Read by the host screen from its own figures, which [onChanged]
  /// refreshes after every write.
  final double cashPayable;

  /// What the shop can take in now: a supplier's credit, an employee's debt.
  final double cashCollectable;
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

  Future<void> _write(BalanceEntryKind kind) async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await showBalanceEntryDialog(
      context,
      party: widget.party,
      kind: kind,
      onSubmit: _viewModel.create,
    );
    if (saved && mounted) {
      _snack(l10n.balanceEntrySaved);
    }
  }

  Future<void> _settle(BalanceDirection settles, double available) async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await showBalanceRefundDialog(
      context,
      party: widget.party,
      settles: settles,
      available: available,
      onSubmit: (amount, note) => _viewModel.refund(
        amount,
        note: note,
        // Only an employee's account runs both ways; for the others the side
        // is the only one there is.
        settles: widget.party == BalanceParty.employee ? settles : null,
      ),
    );
    if (saved && mounted) {
      _snack(BalanceCashWords.of(l10n, widget.party, settles).saved);
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
        final canPay = widget.canSettleInCash && widget.cashPayable > 0.005;
        final canTakeIn =
            widget.canSettleInCash && widget.cashCollectable > 0.005;
        return PointyDetailSection(
          title: l10n.balanceEntriesTitle,
          icon: Icons.account_balance_wallet_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.canManage || canPay || canTakeIn) ...[
                Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.sm,
                  children: [
                    if (widget.canManage &&
                        !viewModel.hasLiveOpening &&
                        !viewModel.isLoading)
                      FilledButton.tonalIcon(
                        key: const ValueKey('add_opening_balance_button'),
                        onPressed: busy
                            ? null
                            : () => _write(BalanceEntryKind.opening),
                        icon: const Icon(Icons.flag_outlined),
                        label: Text(l10n.addOpeningBalanceButton),
                      ),
                    if (widget.canManage)
                      OutlinedButton.icon(
                        key: const ValueKey('add_balance_adjustment_button'),
                        onPressed: busy
                            ? null
                            : () => _write(BalanceEntryKind.adjustment),
                        icon: const Icon(Icons.tune_outlined),
                        label: Text(l10n.addBalanceAdjustmentButton),
                      ),
                    if (canPay)
                      OutlinedButton.icon(
                        key: const ValueKey('balance_pay_out_button'),
                        onPressed: busy
                            ? null
                            : () => _settle(
                                BalanceDirection.weOweThem,
                                widget.cashPayable,
                              ),
                        icon: const Icon(Icons.payments_outlined),
                        label: Text(
                          BalanceCashWords.of(
                            l10n,
                            widget.party,
                            BalanceDirection.weOweThem,
                          ).button,
                        ),
                      ),
                    if (canTakeIn)
                      OutlinedButton.icon(
                        key: const ValueKey('balance_take_in_button'),
                        onPressed: busy
                            ? null
                            : () => _settle(
                                BalanceDirection.theyOweUs,
                                widget.cashCollectable,
                              ),
                        icon: const Icon(Icons.savings_outlined),
                        label: Text(
                          BalanceCashWords.of(
                            l10n,
                            widget.party,
                            BalanceDirection.theyOweUs,
                          ).button,
                        ),
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
      // A refund is cash that already changed hands, in whichever direction
      // its kind says; "they owe us" or "we owe them" would misdescribe it.
      title: balanceEntryTitle(l10n, party, entry),
      subtitle: [
        entry.number,
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
