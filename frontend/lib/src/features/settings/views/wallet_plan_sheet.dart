import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';
import 'wallet_top_up_sheet.dart';

/// The lengths offered, in periods, where the plan allows them.
const _periodChoices = [1, 3, 6, 12];

/// Pay for a plan — remote access or the assistant — from the main wallet: one
/// or more periods, added after whatever the shop already has. The sheet shows
/// the total, what the wallet holds before and after, and when the plan will
/// end; a wallet that cannot pay is sent to top up first. Returns the plan as
/// it now stands once it is paid for.
Future<WalletPlan?> showWalletPlanSheet({
  required BuildContext context,
  required WalletViewModel wallet,
  required String planKey,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  wallet.spending.beginPurchase();
  if (wallet.overview == null && !wallet.isLoading) {
    unawaited(wallet.load());
  }
  final outcome = await showAdaptiveFormSurface<_PlanSheetOutcome>(
    context: context,
    title: l10n.walletPlanSheetTitle(walletPlanTitle(planKey, l10n)),
    builder: (_) => WalletPlanForm(wallet: wallet, planKey: planKey),
  );
  final paid = outcome?.plan;
  if (!context.mounted) {
    return paid;
  }
  if (paid != null) {
    final until = paid.until;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.walletPlanPaidMessage(
            walletPlanTitle(planKey, l10n),
            until == null ? '—' : formatDate(until),
          ),
        ),
      ),
    );
  } else if (outcome?.topUpFirst ?? false) {
    await showWalletTopUpSheet(context: context, viewModel: wallet);
  }
  return paid;
}

/// What the plan sheet came to: the plan paid for, or a top-up wanted first.
class _PlanSheetOutcome {
  const _PlanSheetOutcome.paid(WalletPlan this.plan) : topUpFirst = false;
  const _PlanSheetOutcome.topUpFirst() : plan = null, topUpFirst = true;

  final WalletPlan? plan;
  final bool topUpFirst;
}

class WalletPlanForm extends StatefulWidget {
  const WalletPlanForm({
    super.key,
    required this.wallet,
    required this.planKey,
    this.now,
  });

  final WalletViewModel wallet;
  final String planKey;

  /// Today, for the end date shown; injected by tests and the preview.
  final DateTime Function()? now;

  @override
  State<WalletPlanForm> createState() => _WalletPlanFormState();
}

class _WalletPlanFormState extends State<WalletPlanForm> {
  int _periods = 1;

  Future<void> _pay() async {
    final bought = await widget.wallet.spending.purchasePlan(
      widget.planKey,
      _periods,
    );
    if (bought != null && mounted) {
      Navigator.of(context).pop(_PlanSheetOutcome.paid(bought));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = widget.wallet;
    return ListenableBuilder(
      listenable: Listenable.merge([wallet, wallet.spending]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;
        final textTheme = Theme.of(context).textTheme;
        final overview = wallet.overview;
        final plan = overview?.planFor(widget.planKey);
        if (overview == null || plan == null) {
          return Padding(
            padding: EdgeInsets.all(spacing.lg),
            child: wallet.isLoading
                ? const Center(
                    child: SizedBox.square(
                      dimension: 28,
                      child: PointySpinner(),
                    ),
                  )
                : PointyInlineMessage(message: l10n.walletPlanNotSold),
          );
        }
        final busy = wallet.spending.isPurchasing;
        final error = wallet.spending.purchaseError;
        final choices = [
          for (final periods in _periodChoices)
            if (periods <= plan.maxPeriods) periods,
        ];
        final periods = choices.contains(_periods) ? _periods : choices.first;
        final total = plan.priceFor(periods);
        final balance = overview.balance ?? 0;
        final affordable = balance + 0.0005 >= total;
        final now = (widget.now ?? DateTime.now)();
        final endsOn = plan.endsAfter(periods, now);
        final renewing = plan.active && plan.until != null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  spacing.md,
                  spacing.md,
                  spacing.md,
                  0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.walletPlanPeriodLabel,
                      style: textTheme.titleSmall,
                    ),
                    SizedBox(height: spacing.xs),
                    Wrap(
                      spacing: spacing.xs,
                      runSpacing: spacing.xs,
                      children: [
                        for (final choice in choices)
                          ChoiceChip(
                            key: ValueKey('plan_periods_$choice'),
                            selected: choice == periods,
                            onSelected: busy
                                ? null
                                : (_) => setState(() => _periods = choice),
                            label: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  walletPlanLength(
                                    plan.periodDays,
                                    choice,
                                    l10n,
                                  ),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  formatWalletMoney(plan.priceFor(choice)),
                                  style: PointyTypography.numeric(
                                    (textTheme.bodySmall ?? const TextStyle())
                                        .copyWith(color: colors.mutedInk),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: spacing.md),
                    PointySummaryList(
                      rows: [
                        PointySummaryRow(
                          label: l10n.walletPlanTotalLabel,
                          value: formatWalletMoney(total),
                        ),
                        PointySummaryRow(
                          label: l10n.walletPlanWalletLabel,
                          value: formatWalletMoney(balance),
                        ),
                        if (affordable)
                          PointySummaryRow(
                            label: l10n.walletPlanBalanceAfterLabel,
                            value: formatWalletMoney(balance - total),
                          ),
                        PointySummaryRow(
                          label: l10n.walletPlanEndsLabel,
                          value: formatDate(endsOn),
                        ),
                      ],
                    ),
                    if (renewing) ...[
                      SizedBox(height: spacing.sm),
                      Text(
                        l10n.walletPlanRenewNote,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                    if (!affordable) ...[
                      SizedBox(height: spacing.md),
                      PointyDetailCallout(
                        icon: Icons.account_balance_wallet_outlined,
                        tone: PointyCalloutTone.warning,
                        title: l10n.walletSpendTopUpFirstTitle,
                        message: l10n.walletSpendTopUpFirstMessage,
                        trailing: overview.canTopUp
                            ? TextButton(
                                onPressed: () => Navigator.of(
                                  context,
                                ).pop(const _PlanSheetOutcome.topUpFirst()),
                                child: Text(l10n.walletTopUpButton),
                              )
                            : null,
                      ),
                    ] else if (error != null) ...[
                      SizedBox(height: spacing.md),
                      PointyInlineMessage.error(
                        message: walletExceptionMessage(l10n, error),
                        compact: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: spacing.sm,
                overflowSpacing: spacing.xs,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    child: Text(l10n.walletSpendCancel),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('plan_pay'),
                    onPressed: busy || !affordable || !plan.available
                        ? null
                        : () {
                            _periods = periods;
                            unawaited(_pay());
                          },
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: PointySpinner(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_outlined),
                    label: Text(
                      l10n.walletPlanPayButton(formatWalletMoney(total)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
