import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../data/models/sale_order.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';
import '../../view_models/pos_view_model.dart';
import '../direct_services/service_charge_issue_details.dart';
import '../direct_services/service_delivered_details.dart';
import '../recharge_outcome_details.dart';
import 'checkout_receipt_actions.dart';
import 'invoice_link_card.dart';
import 'voucher_codes_card.dart';

/// What a recorded sale came to: the change to count out, what a provider
/// delivered or did not, the customer's link, and the ways to hand them the
/// invoice.
class CheckoutSuccessView extends StatelessWidget {
  const CheckoutSuccessView({
    super.key,
    required this.order,
    required this.saleType,
    required this.printStatus,
    required this.handlers,
    required this.onDone,
    this.recharges = const [],
    this.changeDue = 0,
    this.soldInTestMode = false,
    this.onlineInvoicesEnabled = false,
    this.onOpenSettings,
    this.scanToContinue = false,
  });

  final SaleOrder order;
  final SaleType saleType;
  final InvoicePrintStatus printStatus;
  final List<IntegrationChargeResult> recharges;
  final double changeDue;
  final bool soldInTestMode;
  final bool onlineInvoicesEnabled;
  final VoidCallback? onOpenSettings;
  final CheckoutReceiptHandlers handlers;
  final VoidCallback onDone;

  /// Whether the next scan starts the next sale, said under the button.
  final bool scanToContinue;

  /// Something a provider did not do, or did not say whether it did.
  static bool needsAttention(List<IntegrationChargeResult> recharges) =>
      recharges.any((row) => !row.isCharged);

  /// Whether the result must stay up until the cashier closes it on purpose:
  /// a PIN or token not yet handed over, or a charge nobody knows the fate
  /// of. A stray tap or the next scan must not take those off the screen.
  static bool holdsOpen(List<IntegrationChargeResult> recharges) =>
      recharges.any(
        (row) =>
            row.needsAttention ||
            (row.isCharged &&
                (row.voucherCode.isNotEmpty ||
                    (row.receipt['pin'] ?? '').trim().isNotEmpty)),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final cardRows = recharges
        .where((row) => !row.isDirectService)
        .toList(growable: false);
    final unperformedCards = cardRows
        .where((row) => !row.isCharged)
        .toList(growable: false);
    final unperformedServices = recharges
        .where((row) => row.isDirectService && !row.isCharged)
        .toList(growable: false);
    final deliveredServices = recharges
        .where((row) => row.isDirectService && row.isCharged)
        .toList(growable: false);
    final cards = recharges
        .where(
          (row) => row.isVoucher && row.isCharged && row.voucherCode.isNotEmpty,
        )
        .toList(growable: false);
    final attention = needsAttention(recharges);

    final receiptNumber = order.receiptNumber ?? '';
    final title = attention
        ? l10n.checkoutResultAttentionTitle
        : switch (saleType) {
            SaleType.standard => l10n.checkoutResultSaleTitle,
            SaleType.credit => l10n.checkoutResultCreditTitle,
            SaleType.quotation => l10n.checkoutResultQuotationTitle,
          };

    Widget? headline;
    if (changeDue > 0.004) {
      headline = PointyResultFigure(
        key: const ValueKey('checkout_result_figure'),
        label: l10n.changeDueLabel,
        value: formatMoney(changeDue),
        color: colors.paymentCash,
      );
    } else if (saleType == SaleType.credit && order.balanceDue > 0.004) {
      headline = PointyResultFigure(
        key: const ValueKey('checkout_result_figure'),
        label: l10n.checkoutResultBalanceDue,
        value: formatMoney(order.balanceDue),
        color: colors.warning,
      );
    }

    final showLink = InvoiceLinkCard.showsFor(
      publicUrl: order.publicInvoiceUrl,
      onlineInvoicesEnabled: onlineInvoicesEnabled,
      canOpenSettings: onOpenSettings != null,
    );

    return PointyResultPanel(
      key: const ValueKey('checkout_success'),
      tone: attention ? PointyResultTone.attention : PointyResultTone.success,
      title: title,
      subtitle: receiptNumber.isEmpty
          ? formatMoney(order.total)
          : l10n.checkoutResultReceiptLine(
              ltrIsolated(receiptNumber),
              formatMoney(order.total),
            ),
      headline: headline,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TutorTarget(
            anchor: TutorAnchor.checkoutNewSaleButton,
            child: FilledButton.icon(
              key: const ValueKey('checkout_new_sale'),
              autofocus: true,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
              onPressed: onDone,
              icon: Icon(
                holdsOpen(recharges)
                    ? Icons.done_all_rounded
                    : Icons.add_shopping_cart_rounded,
              ),
              label: Text(
                holdsOpen(recharges)
                    ? l10n.checkoutResultDone
                    : l10n.checkoutResultNewSale,
              ),
            ),
          ),
          if (scanToContinue) ...[
            const SizedBox(height: 6),
            Text(
              l10n.checkoutResultNextScanHint,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ],
      ),
      children: [
        if (unperformedCards.isNotEmpty)
          RechargeOutcomeDetails(rows: unperformedCards),
        if (unperformedServices.isNotEmpty)
          ServiceChargeIssueDetails(
            rows: unperformedServices,
            receiptNumber: order.receiptNumber,
          ),
        if (cards.isNotEmpty)
          VoucherCodesCard(cards: cards, testMode: soldInTestMode),
        if (deliveredServices.isNotEmpty)
          ServiceDeliveredDetails(
            results: deliveredServices,
            testMode: soldInTestMode,
          ),
        if (showLink)
          InvoiceLinkCard(
            publicUrl: order.publicInvoiceUrl,
            onlineInvoicesEnabled: onlineInvoicesEnabled,
            onOpenSettings: onOpenSettings,
          ),
        CheckoutReceiptActions(
          initialPrintStatus: printStatus,
          handlers: handlers,
          customerPhone: order.customerPhone ?? '',
        ),
      ],
    );
  }
}
