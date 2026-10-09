import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_plan_sheet.dart';
import 'wallet_presentation.dart';
import 'wallet_sms_sheet.dart';
import 'wallet_vouchers_sheet.dart';

/// The SMS balance, as a sub-wallet inside the wallet: what it holds, how many
/// messages that is, what one costs, and the transfer that fills it from the
/// main wallet.
class WalletSmsBalanceCard extends StatelessWidget {
  const WalletSmsBalanceCard({
    super.key,
    required this.wallet,
    required this.sms,
    this.onMoved,
  });

  final WalletViewModel wallet;
  final SmsWallet sms;

  /// Told once money moved in, for the page around it to re-read.
  final VoidCallback? onMoved;

  Future<void> _allocate(BuildContext context) async {
    final moved = await showSmsAllocationSheet(
      context: context,
      wallet: wallet,
    );
    if (moved) {
      onMoved?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final empty = !sms.canSend;
    final accent = empty ? colors.warning : colors.primary;

    return _SpendTile(
      key: const ValueKey('wallet_sms_balance'),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: accent.withValues(alpha: 0.12),
        child: Icon(Icons.sms_outlined, color: accent, size: 20),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.walletSmsBalanceTitle,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          Text(
            formatWalletMoney(sms.balance),
            style: PointyTypography.numeric(
              (textTheme.titleLarge ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w800,
                color: colors.ink,
              ),
            ),
          ),
          Text(
            smsWalletSummary(sms, l10n),
            style: textTheme.bodySmall?.copyWith(
              color: empty ? colors.warning : colors.mutedInk,
            ),
          ),
        ],
      ),
      action: OutlinedButton.icon(
        key: const ValueKey('wallet_sms_allocate'),
        onPressed: wallet.overview?.available ?? false
            ? () => _allocate(context)
            : null,
        icon: const Icon(Icons.swap_horiz, size: 18),
        label: Text(l10n.walletSmsAllocateButton),
      ),
    );
  }
}

/// The voucher balance, as a sub-wallet inside the wallet: what it holds,
/// what it is for — the «كروت دفتر» the till sells are paid from it — and the
/// transfer that fills it from the main wallet.
class WalletVoucherBalanceCard extends StatelessWidget {
  const WalletVoucherBalanceCard({
    super.key,
    required this.wallet,
    required this.vouchers,
    this.onMoved,
  });

  final WalletViewModel wallet;
  final VoucherWallet vouchers;

  /// Told once money moved in, for the page around it to re-read.
  final VoidCallback? onMoved;

  Future<void> _allocate(BuildContext context) async {
    final moved = await showVoucherAllocationSheet(
      context: context,
      wallet: wallet,
    );
    if (moved) {
      onMoved?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final empty = vouchers.balance <= 0;
    final accent = empty || !vouchers.configured
        ? colors.warning
        : colors.primary;
    final summary = !vouchers.configured
        ? l10n.walletVouchersNotReady
        : (vouchers.testMode
              ? l10n.walletVouchersTestMode
              : l10n.walletVouchersSummary);

    return _SpendTile(
      key: const ValueKey('wallet_voucher_balance'),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: accent.withValues(alpha: 0.12),
        child: Icon(Icons.card_giftcard_outlined, color: accent, size: 20),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.walletVouchersBalanceTitle,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          Text(
            formatWalletMoney(vouchers.balance),
            style: PointyTypography.numeric(
              (textTheme.titleLarge ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w800,
                color: colors.ink,
              ),
            ),
          ),
          Text(
            summary,
            style: textTheme.bodySmall?.copyWith(
              color: vouchers.configured && !vouchers.testMode
                  ? colors.mutedInk
                  : colors.warning,
            ),
          ),
        ],
      ),
      action: OutlinedButton.icon(
        key: const ValueKey('wallet_voucher_allocate'),
        onPressed:
            (wallet.overview?.available ?? false) && vouchers.acceptsTransfers
            ? () => _allocate(context)
            : null,
        icon: const Icon(Icons.swap_horiz, size: 18),
        label: Text(l10n.walletVouchersAllocateButton),
      ),
    );
  }
}

/// A plan paid from the wallet, inside its service's section: where it
/// stands, what a period costs, and the button that pays for it.
class WalletPlanRow extends StatelessWidget {
  const WalletPlanRow({
    super.key,
    required this.wallet,
    required this.plan,
    this.onPurchased,
  });

  final WalletViewModel wallet;
  final WalletPlan plan;

  /// Told once the plan is paid for, for the page to re-read its status.
  final VoidCallback? onPurchased;

  Future<void> _buy(BuildContext context) async {
    final bought = await showWalletPlanSheet(
      context: context,
      wallet: wallet,
      planKey: plan.key,
    );
    if (bought != null) {
      onPurchased?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final price = plan.price;
    final until = plan.until;
    final status = switch ((plan.included, plan.active, until)) {
      (true, _, _) => l10n.walletPlanIncludedMessage,
      (_, true, final DateTime end) => l10n.walletPlanActiveUntil(
        formatDate(end),
      ),
      _ => null,
    };
    final priceLine = price == null
        ? l10n.walletPlanNotSold
        : l10n.walletPlanPricePer(
            formatWalletMoney(price),
            walletPlanLength(plan.periodDays, 1, l10n),
          );

    return _SpendTile(
      key: ValueKey('wallet_plan_${plan.key}'),
      leading: Icon(
        Icons.account_balance_wallet_outlined,
        color: colors.mutedInk,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.walletPlanPaidFromWallet,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            [?status, priceLine].join(' · '),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
      action: plan.available
          ? FilledButton.tonalIcon(
              key: ValueKey('wallet_plan_buy_${plan.key}'),
              onPressed: wallet.spending.isPurchasing
                  ? null
                  : () => _buy(context),
              icon: Icon(plan.active ? Icons.update : Icons.lock_open_outlined),
              label: Text(
                plan.active
                    ? l10n.walletPlanRenewButton
                    : l10n.walletPlanBuyButton,
              ),
            )
          : null,
    );
  }
}

/// A sunken tile with a mark, what it is about, and its one action: beside
/// the text where there is room, under it on a phone, so neither squeezes.
class _SpendTile extends StatelessWidget {
  const _SpendTile({
    super.key,
    required this.leading,
    required this.body,
    this.action,
  });

  final Widget leading;
  final Widget body;
  final Widget? action;

  /// Below this width the action goes under the text.
  static const _sideBySideWidth = 520.0;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final action = this.action;
    return Container(
      padding: EdgeInsets.all(spacing.sm),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heading = Row(
            children: [
              leading,
              SizedBox(width: spacing.sm),
              Expanded(child: body),
            ],
          );
          if (action == null) {
            return heading;
          }
          if (constraints.maxWidth >= _sideBySideWidth) {
            return Row(
              children: [
                Expanded(child: heading),
                SizedBox(width: spacing.sm),
                action,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              SizedBox(height: spacing.sm),
              Align(alignment: AlignmentDirectional.centerEnd, child: action),
            ],
          );
        },
      ),
    );
  }
}
