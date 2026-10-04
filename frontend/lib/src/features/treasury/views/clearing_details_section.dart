import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../core/authorization.dart';
import '../../../data/models/card_settlement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/clearing_details_view_model.dart';
import '../view_models/money_position_view_model.dart';
import 'held_day_tile.dart';
import 'treasury_ui.dart';

/// What a clearing account's detail sheet adds to its balance: the held days
/// still waiting for the processor, and the deposits recorded so far — each
/// undoable, which puts its sales back among the held ones.
class ClearingDetailsSection extends StatefulWidget {
  const ClearingDetailsSection({
    super.key,
    required this.positionViewModel,
    required this.capabilities,
    required this.accountId,
    required this.balance,
  });

  final MoneyPositionViewModel positionViewModel;
  final AuthorizationCapabilities capabilities;
  final int accountId;

  /// The account's balance as the screen shows it. When it moves — a deposit
  /// recorded from the quick actions, say — this section reads its lists again.
  final double balance;

  @override
  State<ClearingDetailsSection> createState() => _ClearingDetailsSectionState();
}

class _ClearingDetailsSectionState extends State<ClearingDetailsSection> {
  late final ClearingDetailsViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = ClearingDetailsViewModel(
      widget.positionViewModel.repository,
      accountId: widget.accountId,
    )..load();
  }

  @override
  void didUpdateWidget(ClearingDetailsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.balance != widget.balance) {
      _viewModel.load();
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _cancel(CardSettlement settlement) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _askReason(context);
    if (reason == null) {
      return;
    }
    final cancelled = await _viewModel.cancel(settlement, reason: reason);
    if (!mounted) {
      return;
    }
    if (cancelled) {
      await widget.positionViewModel.load();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          cancelled
              ? l10n.treasuryClearingCancelled
              : l10n.treasuryClearingCancelFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final vm = _viewModel;
        if (vm.isLoading && vm.held == null) {
          return PointySkeleton(
            child: Column(
              children: [
                for (var i = 0; i < 3; i++) ...[
                  const PointySkeletonListTile(),
                  SizedBox(height: spacing.xs),
                ],
              ],
            ),
          );
        }
        final held = vm.held?.days ?? const <HeldDay>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySectionHeader(title: l10n.treasuryClearingHeldTitle),
            SizedBox(height: spacing.sm),
            if (held.isEmpty)
              PointyInlineMessage(
                message: l10n.treasuryClearingNothingHeld,
                icon: Icons.check_circle_outline,
              )
            else
              for (final day in held) HeldDayTile(day: day),
            SizedBox(height: spacing.lg),
            PointySectionHeader(title: l10n.treasuryClearingSettlementsTitle),
            SizedBox(height: spacing.sm),
            if (vm.hasError)
              PointyInlineMessage.error(
                message: l10n.treasuryClearingSettlementsError,
              )
            else if (vm.settlements.isEmpty)
              PointyInlineMessage(
                message: l10n.treasuryClearingSettlementsEmpty,
                icon: Icons.inbox_outlined,
              )
            else
              for (final settlement in vm.settlements)
                _SettlementRow(
                  settlement: settlement,
                  busy: vm.isCancelling(settlement.id),
                  onCancel:
                      widget.capabilities.canCancelCardSettlement &&
                          !settlement.isCancelled
                      ? () => _cancel(settlement)
                      : null,
                ),
          ],
        );
      },
    );
  }
}

class _SettlementRow extends StatelessWidget {
  const _SettlementRow({
    required this.settlement,
    required this.busy,
    this.onCancel,
  });

  final CardSettlement settlement;
  final bool busy;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final first = settlement.firstDay;
    final last = settlement.lastDay;
    final days = first == null
        ? ''
        : (last == null || last == first)
        ? treasuryDayLabel(l10n, first)
        : '${treasuryDayLabel(l10n, first)} – ${treasuryDayLabel(l10n, last)}';

    return Card(
      key: ValueKey('treasury_settlement_${settlement.id}'),
      margin: EdgeInsets.only(bottom: spacing.sm),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Row(
          children: [
            Icon(Icons.credit_score_outlined, color: colors.mutedInk),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    treasuryDayLabel(l10n, settlement.settledOn),
                    style: textTheme.bodyLarge?.copyWith(
                      decoration: settlement.isCancelled
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  Text(
                    l10n.treasuryClearingSettlementSubtitle(
                      settlement.paymentCount,
                      days,
                    ),
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  if (settlement.isCancelled ||
                      settlement.differenceCents != 0) ...[
                    SizedBox(height: spacing.xs),
                    Wrap(
                      spacing: spacing.xs,
                      children: [
                        if (settlement.isCancelled)
                          PointyStatusPill(
                            label: l10n.treasuryClearingSettlementCancelled,
                            icon: Icons.undo,
                            color: colors.mutedInk,
                          ),
                        if (settlement.differenceCents != 0)
                          PointyStatusPill(
                            label: l10n.treasuryClearingSettlementDifference(
                              treasurySignedMoney(
                                centsToDouble(settlement.differenceCents),
                              ),
                            ),
                            icon: Icons.percent,
                            color: settlement.differenceCents < 0
                                ? colors.danger
                                : colors.success,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Text(
              formatMoney(centsToDouble(settlement.amountReceivedCents)),
              style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (onCancel != null)
              busy
                  ? Padding(
                      padding: EdgeInsets.all(spacing.sm),
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: PointySpinner(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      key: ValueKey(
                        'treasury_settlement_cancel_${settlement.id}',
                      ),
                      tooltip: l10n.treasuryClearingCancelAction,
                      onPressed: onCancel,
                      icon: const Icon(Icons.undo),
                    ),
          ],
        ),
      ),
    );
  }
}

/// Asks for the reason a settlement is being undone. Null when dismissed.
Future<String?> _askReason(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => const _CancelReasonDialog(),
  );
}

/// Owns its text controller, so the field outlives the dialog's closing
/// animation instead of being disposed under it.
class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog();

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return AlertDialog(
      title: Text(l10n.treasuryClearingCancelTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.treasuryClearingCancelMessage),
          SizedBox(height: spacing.sm),
          TextField(
            key: const ValueKey('treasury_settlement_cancel_reason'),
            controller: _controller,
            decoration: InputDecoration(
              labelText: l10n.treasuryClearingCancelReasonLabel,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('treasury_settlement_cancel_confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.treasuryClearingCancelAction),
        ),
      ],
    );
  }
}
