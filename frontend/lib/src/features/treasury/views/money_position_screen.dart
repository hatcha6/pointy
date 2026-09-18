import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../core/authorization.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/money_position_view_model.dart';
import 'money_account_details_sheet.dart';
import 'money_count_sheet.dart';
import 'money_transfer_sheet.dart';
import 'treasury_ui.dart';

/// الخزينة — where the shop's money is, and whether reality agrees.
///
/// This screen replaced a paginated list of individual payments, which
/// duplicated the expenses ledger and answered a question nobody asks ("what
/// was payment #418?"). It answers the one they do: how much should be in the
/// box and in the bank right now, why, and does it match what was counted. The
/// old ledger is still one tap away for the row-level detail.
class MoneyPositionScreen extends StatefulWidget {
  const MoneyPositionScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
    required this.navigation,
    this.onOpenPaymentsLedger,
  });

  final MoneyPositionViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  /// Opens the detailed customer/supplier payment ledger. Null hides the link.
  final VoidCallback? onOpenPaymentsLedger;

  @override
  State<MoneyPositionScreen> createState() => _MoneyPositionScreenState();
}

class _MoneyPositionScreenState extends State<MoneyPositionScreen> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.payments,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.treasuryTitle),
            actions: [
              if (widget.onOpenPaymentsLedger != null)
                IconButton(
                  tooltip: l10n.treasuryLedgerLink,
                  onPressed: widget.onOpenPaymentsLedger,
                  icon: const Icon(Icons.receipt_long_outlined),
                ),
              IconButton(
                tooltip: l10n.treasuryRefreshTooltip,
                onPressed: widget.viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: widget.capabilities,
            capability: AppCapability.viewPayments,
            child: _MoneyPositionBody(
              viewModel: widget.viewModel,
              onOpenPaymentsLedger: widget.onOpenPaymentsLedger,
            ),
          ),
        );
      },
    );
  }
}

class _MoneyPositionBody extends StatelessWidget {
  const _MoneyPositionBody({
    required this.viewModel,
    this.onOpenPaymentsLedger,
  });

  final MoneyPositionViewModel viewModel;
  final VoidCallback? onOpenPaymentsLedger;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && !viewModel.hasLoaded) {
      return const _MoneyPositionSkeleton();
    }
    if (viewModel.hasError && !viewModel.hasLoaded) {
      return PointyErrorState(
        title: l10n.treasuryErrorTitle,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.treasuryRetry),
        ),
      );
    }
    if (viewModel.accounts.isEmpty) {
      return PointyEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.treasuryEmptyTitle,
        message: l10n.treasuryEmptyMessage,
      );
    }

    final totals = viewModel.totals;
    final cash = viewModel.position!.cashAccounts;
    final bank = viewModel.position!.bankAccounts;

    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        children: [
          _TotalsHero(totals: totals),
          SizedBox(height: spacing.md),
          // Beneath the total, never inside it: the cash really is in the
          // drawer, and what is untrue is that all of it is the shop's.
          // Subtracting it here would double-count the money the moment the
          // payout is actually made.
          if (!viewModel.position!.obligations.isEmpty) ...[
            _ObligationsCallout(obligations: viewModel.position!.obligations),
            SizedBox(height: spacing.md),
          ],
          ..._callouts(context, l10n, totals),
          _QuickActions(viewModel: viewModel),
          SizedBox(height: spacing.lg),
          if (cash.isNotEmpty) ...[
            PointySectionHeader(title: l10n.treasurySectionCash),
            SizedBox(height: spacing.sm),
            ..._accountCards(context, cash),
            SizedBox(height: spacing.lg),
          ],
          if (bank.isNotEmpty) ...[
            PointySectionHeader(title: l10n.treasurySectionBank),
            SizedBox(height: spacing.sm),
            ..._accountCards(context, bank),
          ],
          if (onOpenPaymentsLedger != null) ...[
            SizedBox(height: spacing.lg),
            Center(
              child: TextButton.icon(
                onPressed: onOpenPaymentsLedger,
                icon: const Icon(Icons.receipt_long_outlined),
                label: Text(l10n.treasuryLedgerLink),
              ),
            ),
          ],
          SizedBox(height: spacing.lg),
        ],
      ),
    );
  }

  List<Widget> _callouts(
    BuildContext context,
    AppLocalizations l10n,
    MoneyPositionTotals totals,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    // A disagreement outranks a missing count: one is a problem, the other is
    // only an absence of proof.
    if (totals.hasVariance) {
      return [
        PointyDetailCallout(
          icon: Icons.report_problem_outlined,
          tone: PointyCalloutTone.danger,
          title: l10n.treasuryVarianceCalloutTitle(totals.accountsWithVariance),
          message: l10n.treasuryVarianceCalloutMessage,
        ),
        SizedBox(height: spacing.md),
      ];
    }
    if (totals.hasUncountedAccounts) {
      return [
        PointyDetailCallout(
          icon: Icons.help_outline,
          tone: PointyCalloutTone.neutral,
          title: l10n.treasuryUncountedCalloutTitle,
          message: l10n.treasuryUncountedCalloutMessage,
        ),
        SizedBox(height: spacing.md),
      ];
    }
    return const [];
  }

  List<Widget> _accountCards(
    BuildContext context,
    List<MoneyAccountPosition> entries,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    return [
      for (final entry in entries) ...[
        _AccountCard(
          entry: entry,
          onTap: () => showMoneyAccountDetailsSheet(
            context,
            viewModel: viewModel,
            accountId: entry.account.id,
          ),
        ),
        SizedBox(height: spacing.sm),
      ],
    ];
  }
}

/// The one number the owner came for, with its two halves beside it.
/// *منها مستحقات أمانات* — how much of the money on this page is spoken for.
class _ObligationsCallout extends StatelessWidget {
  const _ObligationsCallout({required this.obligations});

  final MoneyObligations obligations;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailCallout(
      icon: Icons.handshake_outlined,
      tone: PointyCalloutTone.warning,
      title: l10n.treasuryConsignorPayableTitle(
        formatMoney(obligations.consignorPayable),
      ),
      message: obligations.custodyUnitCount > 0
          ? l10n.treasuryCustodyHeld(
              obligations.custodyUnitCount,
              formatMoney(obligations.custodyDeclaredValue),
            )
          : null,
    );
  }
}

class _TotalsHero extends StatelessWidget {
  const _TotalsHero({required this.totals});

  final MoneyPositionTotals totals;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyDetailHero(
      icon: Icons.account_balance_wallet,
      title: l10n.treasuryHeroTitle,
      value: formatMoney(totals.total),
      valueSubtitle: l10n.treasuryHeroSubtitle,
      pills: [
        PointyHeroPill(
          label: '${l10n.treasuryCashLabel} ${formatMoney(totals.cash)}',
          icon: Icons.savings_outlined,
        ),
        PointyHeroPill(
          label: '${l10n.treasuryBankLabel} ${formatMoney(totals.bank)}',
          icon: Icons.account_balance_outlined,
        ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.viewModel});

  final MoneyPositionViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.isSubmitting;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: busy
                ? null
                : () => showMoneyTransferSheet(context, viewModel: viewModel),
            icon: const Icon(Icons.move_down),
            label: Text(l10n.treasuryActionDeposit),
          ),
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy
                ? null
                : () =>
                      showMoneyCountPickerSheet(context, viewModel: viewModel),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(l10n.treasuryActionCount),
          ),
        ),
      ],
    );
  }
}

/// One account: what it should hold, when it was last proved, and a tap into
/// the arithmetic behind it.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.entry, required this.onTap});

  final MoneyAccountPosition entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final account = entry.account;
    final countedOn = treasuryCountedOnLabel(l10n, entry.lastCount);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Padding(
          padding: EdgeInsets.all(spacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.primaryStrong,
                child: Icon(treasuryAccountIcon(account)),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // A shop that named the account after its bank would
                    // otherwise read the same words twice.
                    if (account.bankName.isNotEmpty &&
                        account.bankName != account.name)
                      Text(
                        account.bankName,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    SizedBox(height: spacing.xs),
                    Text(
                      formatMoney(entry.expectedBalance),
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Wrap(
                      spacing: spacing.xs,
                      runSpacing: spacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        treasuryCountPill(context, l10n, entry.lastCount),
                        if (countedOn != null)
                          Text(
                            countedOn,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const PointyDisclosureChevron(),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoneyPositionSkeleton extends StatelessWidget {
  const _MoneyPositionSkeleton();

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return PointySkeleton(
      child: ListView(
        padding: spacing.pagePadding,
        children: [
          const PointySkeletonBox(height: 148),
          SizedBox(height: spacing.md),
          const PointySkeletonBox(height: 48),
          SizedBox(height: spacing.lg),
          for (var i = 0; i < 3; i++) ...[
            const PointySkeletonBox(height: 108),
            SizedBox(height: spacing.sm),
          ],
        ],
      ),
    );
  }
}
