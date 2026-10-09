import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';

/// Waiting on the gateway: the bank-card payer is on the payment page in the
/// browser, or the gateway took the code without a verdict yet. Either way the
/// sheet turns into the verdict by itself; closing it loses nothing.
class WalletAwaitingPayment extends StatelessWidget {
  const WalletAwaitingPayment({
    super.key,
    required this.viewModel,
    required this.onClose,
  });

  final WalletViewModel viewModel;
  final VoidCallback onClose;

  Future<void> _copyLink(BuildContext context) async {
    final url = viewModel.checkoutUrl;
    if (url == null) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.walletAwaitingLinkCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final topUp = viewModel.activeTopUp;
    final onPage = viewModel.awaitingHostedPage;

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SizedBox.square(
              dimension: 44,
              child: PointySpinner(strokeWidth: 3),
            ),
          ),
          SizedBox(height: spacing.md),
          Text(
            onPage ? l10n.walletAwaitingTitle : l10n.walletAwaitingGatewayTitle,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (topUp != null) ...[
            SizedBox(height: spacing.xs),
            Text(
              formatWalletMoney(topUp.amount),
              textAlign: TextAlign.center,
              style: PointyTypography.numeric(
                (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.primaryStrong,
                ),
              ),
            ),
            Text(
              l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
          SizedBox(height: spacing.md),
          Text(
            onPage
                ? l10n.walletAwaitingMessage
                : l10n.walletAwaitingGatewayMessage,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium,
          ),
          if (onPage) ...[
            if (viewModel.checkoutOpenFailed) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.warning(
                message: l10n.walletCheckoutOpenFailed,
                compact: true,
              ),
            ],
            SizedBox(height: spacing.md),
            FilledButton.icon(
              onPressed: viewModel.openCheckout,
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.walletAwaitingOpenAgain),
            ),
            SizedBox(height: spacing.xs),
            OutlinedButton.icon(
              onPressed: () => _copyLink(context),
              icon: const Icon(Icons.copy_outlined),
              label: Text(l10n.walletAwaitingCopyLink),
            ),
          ],
          SizedBox(height: spacing.md),
          Text(
            l10n.walletAwaitingCloseHint,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          TextButton(onPressed: onClose, child: Text(l10n.walletClose)),
        ],
      ),
    );
  }
}

/// How the top-up ended: paid (with the new balance and the expense), called
/// off, declined (in the gateway's own words when it gave them), held for
/// review, or not confirmed in time.
class WalletTopUpVerdict extends StatelessWidget {
  const WalletTopUpVerdict({
    super.key,
    required this.viewModel,
    required this.onClose,
    required this.onTryAgain,
  });

  final WalletViewModel viewModel;
  final VoidCallback onClose;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final topUp = viewModel.activeTopUp;
    final overview = viewModel.overview;
    final refusal = viewModel.verdictError;
    final errorCode = topUp?.errorCode ?? '';

    late final IconData icon;
    late final Color tone;
    late final String title;
    final lines = <String>[];
    var success = false;
    switch (viewModel.topUpStage) {
      case WalletTopUpStage.paid:
        success = true;
        icon = Icons.check_circle;
        tone = colors.success;
        title = (topUp?.isBankTransfer ?? false)
            ? l10n.walletTransferPaidTitle
            : l10n.walletPaidTitle;
        if (topUp != null) {
          lines.add(l10n.walletPaidMessage(formatWalletMoney(topUp.amount)));
        }
        final balance = overview?.balance;
        if (balance != null) {
          lines.add(l10n.walletNewBalance(formatWalletMoney(balance)));
        }
        if (topUp?.isBookedAsExpense ?? false) {
          lines.add(
            l10n.walletPaidBooked(
              overview?.settings.effectiveCategoryName ?? '',
            ),
          );
        }
      case WalletTopUpStage.rejected:
        icon = Icons.block_outlined;
        tone = colors.danger;
        title = l10n.walletTransferRejectedTitle;
        final reason = topUp?.errorDetail.trim() ?? '';
        if (reason.isNotEmpty) {
          lines.add(l10n.walletTransferRejectedReason(reason));
        }
        lines.add(l10n.walletTransferRejectedHelp);
      case WalletTopUpStage.canceled:
        icon = Icons.cancel_outlined;
        tone = colors.mutedInk;
        title = l10n.walletCanceledTitle;
        lines.add(l10n.walletCanceledMessage);
      case WalletTopUpStage.failed
          when errorCode == 'amount_mismatch' ||
              errorCode == 'environment_mismatch':
        icon = Icons.pending_actions_outlined;
        tone = colors.warning;
        title = l10n.walletReviewTitle;
        lines.add(l10n.walletReviewMessage);
      case WalletTopUpStage.failed
          when errorCode == 'declined' || refusal?.code == 'declined':
        icon = Icons.block_outlined;
        tone = colors.danger;
        title = l10n.walletDeclinedTitle;
        final said = arabicGatewayMessage(refusal?.gatewayMessage ?? '');
        if (said != null) {
          lines.add(said);
        }
        lines.add(l10n.walletDeclinedMessage);
      case WalletTopUpStage.failed
          when errorCode == 'otp_attempts_exceeded' ||
              refusal?.code == 'otp_attempts_exceeded':
        icon = Icons.error_outline;
        tone = colors.danger;
        title = l10n.walletFailedTitle;
        lines.add(l10n.walletAttemptsExceededMessage);
      case WalletTopUpStage.failed:
        icon = Icons.error_outline;
        tone = colors.danger;
        title = l10n.walletFailedTitle;
        lines.add(l10n.walletFailedMessage);
      default:
        icon = Icons.help_outline;
        tone = colors.warning;
        title = l10n.walletUnconfirmedTitle;
        lines.add(l10n.walletUnconfirmedMessage);
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, size: 56, color: tone),
          SizedBox(height: spacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: spacing.sm),
          for (final line in lines)
            Padding(
              padding: EdgeInsets.only(bottom: spacing.xs),
              child: Text(
                line,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
            ),
          if (topUp != null && topUp.method.isNotEmpty)
            Text(
              [
                walletMethodLabel(topUp.method, l10n),
                if (topUp.transfer case final transfer?)
                  ltrIsolated(LibyanIban.masked(transfer.payerIban))
                else if (topUp.payerHint.isNotEmpty)
                  ltrIsolated(topUp.payerHint),
              ].join(' · '),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          // The reference on a line of its own, selectable: it is what support
          // matches against the gateway when a payment needs looking into.
          if (topUp != null && topUp.invoiceNo.isNotEmpty)
            SelectableText(
              l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          if (topUp?.testMode ?? false) ...[
            SizedBox(height: spacing.xs),
            Center(
              child: PointyStatusPill(
                label: l10n.walletTestModePill,
                icon: Icons.science_outlined,
                color: colors.warning,
              ),
            ),
          ],
          SizedBox(height: spacing.md),
          if (success)
            FilledButton(onPressed: onClose, child: Text(l10n.walletDone))
          else ...[
            if (viewModel.topUpStage != WalletTopUpStage.unconfirmed)
              FilledButton.icon(
                onPressed: onTryAgain,
                icon: const Icon(Icons.refresh),
                label: Text(
                  viewModel.topUpStage == WalletTopUpStage.rejected
                      ? l10n.walletTransferSendAgain
                      : l10n.walletTryAgain,
                ),
              ),
            TextButton(onPressed: onClose, child: Text(l10n.walletClose)),
          ],
        ],
      ),
    );
  }
}
