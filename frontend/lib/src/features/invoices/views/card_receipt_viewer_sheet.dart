import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/sale_order.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_mark.dart';
import '../../../shared/payments/card_receipt_status.dart';
import '../../../shared/payments/libyan_banks.dart';
import '../../../shared/responsive/responsive.dart';

/// Shows the terminal slip behind a sale's card payments.
///
/// Ours first, the issuer's second, and that order is the whole design. The
/// shop's own copy is built from the fields we stored, so it opens instantly,
/// reads right-to-left in Arabic, and — the part that matters in Libya — works
/// with the internet down. The issuer's original is one tap away for the times
/// only the real document will do: a dispute, an audit, a customer who wants
/// to see the bank's own page.
///
/// Doing it the other way round — defaulting to the remote copy — would mean a
/// spinner and then a failure on exactly the day the shop most needs to look
/// something up.
Future<void> showCardReceiptViewerSheet({
  required BuildContext context,
  required List<SalePayment> payments,
}) {
  final withReceipts = payments
      .where((payment) => payment.cardReceipt != null)
      .toList(growable: false);
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) => _CardReceiptViewer(payments: withReceipts),
  );
}

class _CardReceiptViewer extends StatelessWidget {
  const _CardReceiptViewer({required this.payments});

  final List<SalePayment> payments;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (payments.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(spacing.lg),
        child: PointyEmptyState(
          icon: Icons.receipt_long_outlined,
          title: l10n.orderCardReceiptNoneForOrder,
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, payment) in payments.indexed) ...[
            if (index > 0) SizedBox(height: spacing.md),
            _ReceiptCard(payment: payment),
          ],
        ],
      ),
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({required this.payment});

  final SalePayment payment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final receipt = payment.cardReceipt!;
    final status = receipt.status;

    return PointyDetailSection(
      title: l10n.orderCardReceiptSheetTitle,
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // What the slip printed, currency and all, in preference to
                  // our re-formatted number: this is the line the customer is
                  // holding in their hand.
                  receipt.amountLabel.isNotEmpty
                      ? receipt.amountLabel
                      : formatMoney(receipt.amount),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              CardReceiptStatusBadge(status: status),
            ],
          ),
          SizedBox(height: spacing.xs),
          Text(
            status.description(l10n),
            style: theme.textTheme.bodySmall?.copyWith(
              color: status.needsAttention ? colors.danger : colors.mutedInk,
            ),
          ),
          if (receipt.verificationError.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              compact: true,
              message: receipt.verificationError,
            ),
          ],
          // The issuing bank, when the slip actually named it. Draws nothing
          // at all otherwise — most receipts cannot say, and a row admitting
          // that on every one of them would be noise.
          if (bankForMaskedPan(receipt.maskedPan) != null) ...[
            SizedBox(height: spacing.sm),
            BankMark(bank: bankForMaskedPan(receipt.maskedPan)),
          ],
          SizedBox(height: spacing.md),
          PointySummaryList(rows: _rows(l10n, receipt)),
          if (receipt.rawFields.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            _RawFieldsPanel(fields: receipt.rawFields),
          ],
          SizedBox(height: spacing.md),
          if (receipt.hasOriginal) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const ValueKey('card_receipt_open_original'),
                onPressed: () => _openOriginal(context, receipt.sourceUrl),
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.orderCardReceiptOpenOriginal),
              ),
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.orderCardReceiptOriginalHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ] else
            Text(
              l10n.orderCardReceiptNoOriginal,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
        ],
      ),
    );
  }

  /// Only the fields this slip actually carries. A receipt from a provider that
  /// masks the PAN should not show an empty "card" row; a blank is worse than
  /// an absence, because it reads as data we lost.
  List<PointySummaryRow> _rows(
    AppLocalizations l10n,
    SalePaymentCardReceipt receipt,
  ) {
    return [
      for (final (label, value) in <(String, String)>[
        (l10n.orderCardReceiptFieldCardholder, receipt.cardholderName),
        (l10n.orderCardReceiptFieldCard, receipt.maskedPan),
        (l10n.orderCardReceiptFieldTerminal, receipt.terminalId),
        (l10n.orderCardReceiptFieldMerchant, receipt.merchantName),
        (l10n.orderCardReceiptFieldRrn, receipt.rrn),
        (l10n.orderCardReceiptFieldAuth, receipt.authorizationCode),
        (l10n.orderCardReceiptFieldDateTime, receipt.transactionDateTime),
        // The processor under its own name. "madfoatech" is our internal key,
        // not something a shopkeeper has ever seen printed on anything.
        (l10n.orderCardReceiptFieldProvider, _providerName(l10n, receipt.provider)),
      ])
        if (value.trim().isNotEmpty)
          PointySummaryRow(label: label, value: value),
    ];
  }

  /// The acquirer as it brands itself, falling back to whatever we stored.
  ///
  /// An unknown key is shown as-is rather than blanked: a receipt from an
  /// acquirer added later should still say where it came from.
  String _providerName(AppLocalizations l10n, String provider) {
    return switch (provider) {
      'moamalat' => l10n.cardProviderMoamalat,
      'madfoatech' => l10n.cardProviderMadfoatech,
      _ => provider,
    };
  }

  Future<void> _openOriginal(BuildContext context, String url) async {
    final l10n = AppLocalizations.of(context)!;
    var opened = false;
    try {
      // The issuer's page wants a real browser: Madfoatech serves an empty body
      // to anything that does not look like one, so this must leave the app
      // rather than be fetched and rendered in it.
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on Exception {
      opened = false;
    }
    if (opened || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.orderCardReceiptOpenOriginalFailed)),
    );
  }
}

/// Every field the provider sent, folded away until asked for.
///
/// Collapsed by default because a cashier answering "did this card go through"
/// needs the six rows above, not forty. Expanded, it is the reconciliation
/// view: the acquirer's own key names, so a figure on their statement can be
/// found here by the name they call it.
class _RawFieldsPanel extends StatelessWidget {
  const _RawFieldsPanel({required this.fields});

  final Map<String, String> fields;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final keys = fields.keys.toList()..sort();

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('card_receipt_raw_fields'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          l10n.orderCardReceiptRawFieldsTitle,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          l10n.orderCardReceiptRawFieldsSubtitle,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        children: [
          for (final key in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The provider's own key names are Latin identifiers, so they
                  // are isolated from the surrounding RTL run: without this an
                  // Arabic value beside "TerminalId" drags the label around it.
                  Expanded(
                    flex: 2,
                    child: Text(
                      ltrIsolated(key),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: SelectableText(
                      fields[key]!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
