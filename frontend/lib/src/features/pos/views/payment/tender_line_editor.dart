import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/card_payment_receipt.dart';
import '../../../../data/models/sale_order.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/decimal_text_input_formatter.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/payment_labels.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../../../shared/tutor/anchors.dart';
import '../../../../shared/tutor/tutor_target.dart';

class TenderLineEditor extends StatelessWidget {
  const TenderLineEditor({
    super.key,
    required this.index,
    required this.title,
    required this.amountLabel,
    required this.methodLabel,
    required this.removeTooltip,
    required this.amountController,
    required this.method,
    required this.enabledMethods,
    required this.canRemove,
    required this.isSelected,
    required this.onSelected,
    required this.onAmountChanged,
    required this.onMethodChanged,
    required this.onRemove,
    required this.requireCardReceipt,
    required this.cardReceipt,
    required this.canValidateCardReceipt,
    required this.onValidateCardReceipt,
  });

  final int index;
  final String title;
  final String amountLabel;
  final String methodLabel;
  final String removeTooltip;
  final TextEditingController amountController;
  final PaymentMethod method;
  final List<PaymentMethod> enabledMethods;
  final bool canRemove;
  final bool isSelected;
  final VoidCallback onSelected;
  final VoidCallback onAmountChanged;
  final ValueChanged<PaymentMethod> onMethodChanged;
  final VoidCallback onRemove;
  final bool requireCardReceipt;
  final CardPaymentReceipt? cardReceipt;
  final bool canValidateCardReceipt;
  final VoidCallback onValidateCardReceipt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Material(
      color: isSelected
          ? Color.alphaBlend(
              colors.primaryStrong.withValues(alpha: 0.06),
              colors.surface,
            )
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(
          color: isSelected ? colors.primaryStrong : colors.line,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelected,
        child: Padding(
          padding: EdgeInsetsDirectional.all(spacing.md),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final amountField = TutorTarget(
                anchor: TutorAnchor.paymentTenderAmountField,
                // By position, because that is how a split is built: "the
                // second line takes the rest" is the whole idea of the step.
                id: '$index',
                child: TextField(
                  key: ValueKey('payment_tender_amount_$index'),
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  onTap: onSelected,
                  onChanged: (_) => onAmountChanged(),
                  decoration: InputDecoration(labelText: amountLabel),
                ),
              );
              final methodField = DropdownButtonFormField<PaymentMethod>(
                key: ValueKey('payment_tender_method_$index'),
                initialValue: method,
                decoration: InputDecoration(labelText: methodLabel),
                items: [
                  for (final paymentMethod in enabledMethods)
                    DropdownMenuItem(
                      value: paymentMethod,
                      child: Text(paymentMethodLabel(l10n, paymentMethod)),
                    ),
                ],
                onChanged: (nextMethod) {
                  if (nextMethod != null) {
                    onMethodChanged(nextMethod);
                  }
                },
              );

              final header = Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('payment_tender_remove_$index'),
                    tooltip: removeTooltip,
                    onPressed: canRemove ? onRemove : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              );
              final receiptControls = method == PaymentMethod.card
                  ? <Widget>[
                      SizedBox(height: spacing.sm),
                      _CardReceiptControls(
                        cardReceipt: cardReceipt,
                        requireCardReceipt: requireCardReceipt,
                        canValidateCardReceipt: canValidateCardReceipt,
                        onValidateCardReceipt: onValidateCardReceipt,
                      ),
                    ]
                  : const <Widget>[];

              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: spacing.sm),
                    methodField,
                    SizedBox(height: spacing.sm),
                    amountField,
                    ...receiptControls,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  SizedBox(height: spacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: methodField),
                      SizedBox(width: spacing.sm),
                      SizedBox(width: 160, child: amountField),
                    ],
                  ),
                  ...receiptControls,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CardReceiptControls extends StatelessWidget {
  const _CardReceiptControls({
    required this.cardReceipt,
    required this.requireCardReceipt,
    required this.canValidateCardReceipt,
    required this.onValidateCardReceipt,
  });

  final CardPaymentReceipt? cardReceipt;
  final bool requireCardReceipt;
  final bool canValidateCardReceipt;
  final VoidCallback onValidateCardReceipt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final receipt = cardReceipt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TutorTarget(
            anchor: TutorAnchor.paymentCardReceiptButton,
            child: OutlinedButton.icon(
              key: const ValueKey('payment_card_receipt_button'),
              onPressed: canValidateCardReceipt ? onValidateCardReceipt : null,
              icon: const Icon(Icons.qr_code_scanner_outlined),
              label: Text(
                receipt == null
                    ? l10n.cardReceiptValidateButton
                    : l10n.cardReceiptRescanButton,
              ),
            ),
          ),
        ),
        if (receipt != null && receipt.isPending) ...[
          const SizedBox(height: 8),
          // Attached, not proved. Saying "matched" here would claim a check
          // that has not happened: this provider's amount only arrives once the
          // backend has asked the issuer, after the sale.
          PointyInlineMessage(
            key: const ValueKey('payment_card_receipt_pending'),
            compact: true,
            icon: Icons.schedule_outlined,
            message: l10n.cardReceiptPendingVerificationSummary,
          ),
        ] else if (receipt != null) ...[
          const SizedBox(height: 8),
          PointyInlineMessage.success(
            compact: true,
            message: l10n.cardReceiptValidatedSummary(
              formatMoney(receipt.amount),
              receipt.maskedPan,
            ),
          ),
        ] else if (requireCardReceipt) ...[
          const SizedBox(height: 8),
          PointyInlineMessage.warning(
            compact: true,
            message: l10n.cardReceiptRequiredInline,
          ),
        ],
      ],
    );
  }
}
