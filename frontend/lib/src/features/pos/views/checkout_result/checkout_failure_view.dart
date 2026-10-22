import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/order/order.dart';
import '../../view_models/pos_view_model.dart';
import '../loss_warning_dialog.dart';
import 'credit_limit_breakdown.dart';

/// A sale that was not recorded: what happened to the money first (nothing),
/// then why, in the till's words, then what to do about it — with the button
/// for the likeliest fix in front.
///
/// One view for every refusal the checkout can come back with, replacing the
/// stock, loss and credit-limit dialogs and the snackbar the rest fell to.
class CheckoutFailureView extends StatelessWidget {
  const CheckoutFailureView({
    super.key,
    required this.outcome,
    required this.showLossAmounts,
    required this.onRetry,
    required this.onEditPayment,
    required this.onReviewCart,
  });

  final SaleCheckoutOutcome outcome;
  final bool showLossAmounts;
  final VoidCallback onRetry;
  final VoidCallback onEditPayment;
  final VoidCallback onReviewCart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final reason = _reasonFor(l10n);

    Widget lines(List<String> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              row,
              style: textTheme.bodyMedium?.copyWith(color: colors.ink),
            ),
          ),
      ],
    );

    final reference = outcome.reference;
    return PointyResultPanel(
      key: const ValueKey('checkout_failure'),
      tone: PointyResultTone.failure,
      title: outcome.isUnanswered
          ? l10n.checkoutResultUnansweredTitle
          : l10n.checkoutResultFailedTitle,
      subtitle: outcome.isUnanswered
          ? l10n.checkoutResultUnansweredSubtitle
          : l10n.checkoutResultFailedSubtitle,
      footer: _Actions(
        primary: reason.primary,
        secondary: reason.secondary,
        onRetry: onRetry,
        onEditPayment: onEditPayment,
        onReviewCart: onReviewCart,
      ),
      children: [
        // A refused آجل sale says it in its own breakdown, headed by the one
        // figure that fixes it; a banner over that would say it twice.
        if (outcome.creditLimit case final credit?)
          CreditLimitBreakdown(credit: credit)
        else
          PointyDetailCallout(
            key: const ValueKey('checkout_failure_reason'),
            icon: reason.icon,
            tone: PointyCalloutTone.danger,
            title: reason.title,
            message: reason.message,
          ),
        if (reason.lines.isNotEmpty) lines(reason.lines),
        PointyResultSection(
          title: l10n.checkoutResultWhatToDo,
          icon: Icons.lightbulb_outline_rounded,
          child: PointyResultTips(tips: reason.tips),
        ),
        if (reference != null && reference.isNotEmpty)
          Text(
            l10n.checkoutResultReference(ltrIsolated(reference)),
            key: const ValueKey('checkout_failure_reference'),
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }

  _Reason _reasonFor(AppLocalizations l10n) {
    if (outcome.isStockRejected) {
      return _Reason(
        icon: Icons.inventory_2_outlined,
        title: l10n.checkoutResultStockTitle,
        message: l10n.oversellBlockedMessage,
        lines: [
          for (final shortage in outcome.shortages)
            l10n.oversellLine(
              shortage.productName,
              formatSaleQuantity(shortage.requested),
              formatSaleQuantity(shortage.available),
            ),
        ],
        tips: [l10n.checkoutResultStockTip],
        primary: _Action.reviewCart,
      );
    }
    if (outcome.isLossRejected) {
      return _Reason(
        icon: Icons.trending_down_rounded,
        title: l10n.lossSaleWarningTitle,
        message: lossSaleBlockedMessage(l10n, showAmounts: showLossAmounts),
        lines: [
          for (final line in outcome.lossLines)
            lossSaleLineText(l10n, line, showAmounts: showLossAmounts),
        ],
        tips: [l10n.checkoutResultLossTip],
        primary: _Action.reviewCart,
      );
    }
    if (outcome.creditLimit != null) {
      // Drawn by [CreditLimitBreakdown]; the reason here only feeds the tips
      // and the buttons.
      return _Reason(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.creditLimitBlockedTitle,
        tips: [
          l10n.checkoutCreditTipDownPayment,
          l10n.checkoutResultCreditTipPayNow,
          l10n.checkoutCreditTipRaise,
        ],
        primary: _Action.editPayment,
        secondary: _Action.reviewCart,
      );
    }
    if (outcome.isSessionExpired) {
      return _Reason(
        icon: Icons.point_of_sale_outlined,
        title: l10n.checkoutResultSessionTitle,
        message: l10n.saleCheckoutSessionExpired,
        tips: [l10n.checkoutResultSessionTip],
        primary: _Action.reviewCart,
      );
    }
    return _Reason(
      icon: outcome.isUnanswered
          ? Icons.wifi_off_rounded
          : Icons.error_outline_rounded,
      title: outcome.isUnanswered
          ? l10n.checkoutResultCheckConnection
          : outcome.failureReason ?? l10n.checkoutResultFailedGeneric,
      tips: [l10n.checkoutResultRetrySafe],
      primary: _Action.retry,
      secondary: _Action.editPayment,
    );
  }
}

enum _Action { retry, editPayment, reviewCart }

class _Reason {
  const _Reason({
    required this.icon,
    required this.title,
    required this.tips,
    required this.primary,
    this.message,
    this.lines = const [],
    this.secondary,
  });

  final IconData icon;
  final String title;
  final String? message;
  final List<String> lines;
  final List<String> tips;
  final _Action primary;
  final _Action? secondary;
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.primary,
    required this.secondary,
    required this.onRetry,
    required this.onEditPayment,
    required this.onReviewCart,
  });

  final _Action primary;
  final _Action? secondary;
  final VoidCallback onRetry;
  final VoidCallback onEditPayment;
  final VoidCallback onReviewCart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    (String, IconData, VoidCallback) describe(_Action action) =>
        switch (action) {
          _Action.retry => (l10n.retryButton, Icons.refresh_rounded, onRetry),
          _Action.editPayment => (
            l10n.checkoutResultEditPayment,
            Icons.payments_outlined,
            onEditPayment,
          ),
          _Action.reviewCart => (
            l10n.reviewCartButton,
            Icons.shopping_cart_outlined,
            onReviewCart,
          ),
        };
    final (primaryLabel, primaryIcon, primaryTap) = describe(primary);
    final secondary = this.secondary;
    return Row(
      children: [
        if (secondary != null) ...[
          Expanded(
            child: Builder(
              builder: (context) {
                final (label, icon, onTap) = describe(secondary);
                return OutlinedButton.icon(
                  key: ValueKey('checkout_failure_${secondary.name}'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                  ),
                  onPressed: onTap,
                  icon: Icon(icon),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: FilledButton.icon(
            key: ValueKey('checkout_failure_${primary.name}'),
            autofocus: true,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: primaryTap,
            icon: Icon(primaryIcon),
            label: FittedBox(fit: BoxFit.scaleDown, child: Text(primaryLabel)),
          ),
        ),
      ],
    );
  }
}
