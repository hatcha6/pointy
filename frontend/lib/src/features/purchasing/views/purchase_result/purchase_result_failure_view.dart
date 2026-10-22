import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../core/error_messages.dart';
import '../../../../data/models/purchase_cost_warning.dart';
import '../../../../data/services/api_error_detail.dart';
import '../../../../shared/components/components.dart';
import 'purchase_result_buttons.dart';

/// Whether [error] refuses the supplier's invoice number — already on another
/// order of the same supplier. The one refusal the buyer fixes by changing
/// what they typed; sending the same order again cannot help.
bool purchaseRefusesSupplierInvoiceNumber(Object error) =>
    apiStatusCode(error) == 400 &&
    apiErrorHasField(error, 'supplier_invoice_number');

/// Nothing was recorded — or nobody knows yet. Why, in the buyer's words, and
/// the way back to the draft, which is exactly as they left it.
class PurchaseResultFailureView extends StatelessWidget {
  const PurchaseResultFailureView({
    super.key,
    required this.error,
    required this.saving,
    required this.onRetry,
    required this.onEditInvoice,
    required this.onBack,
  });

  final Object error;

  /// A reopened order's edits, rather than a new order.
  final bool saving;
  final VoidCallback onRetry;
  final VoidCallback onEditInvoice;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final back = PurchaseResultButton(
      name: 'back',
      label: l10n.purchaseResultBackToDraft,
      icon: Icons.edit_note_rounded,
      onPressed: onBack,
    );
    final retry = PurchaseResultButton(
      name: 'retry',
      label: l10n.retryButton,
      icon: Icons.refresh_rounded,
      onPressed: onRetry,
    );

    if (purchaseRefusesSupplierInvoiceNumber(error)) {
      return PointyResultPanel(
        key: const ValueKey('purchase_result_failure'),
        tone: PointyResultTone.failure,
        title: l10n.purchaseResultInvoiceTakenTitle,
        subtitle: l10n.purchaseResultFailedSubtitle,
        footer: PurchaseResultButtons(
          primary: PurchaseResultButton(
            name: 'edit_invoice',
            label: l10n.purchaseResultEditInvoiceAction,
            icon: Icons.receipt_long_outlined,
            onPressed: onEditInvoice,
          ),
          secondary: back,
        ),
        children: [
          PointyDetailCallout(
            key: const ValueKey('purchase_result_failure_reason'),
            icon: Icons.receipt_long_outlined,
            tone: PointyCalloutTone.danger,
            title: l10n.purchaseResultInvoiceTakenTitle,
            message: l10n.purchaseSupplierInvoiceNumberTaken,
          ),
        ],
      );
    }

    final unanswered = (apiStatusCode(error) ?? 0) == 0;
    final fallback = saving
        ? l10n.purchaseDraftSaveError
        : l10n.purchaseDraftSubmitError;
    // The server's own sentence when it wrote one in Arabic — "the line's
    // product was archived" — and the draft's own words otherwise.
    final reason = arabicBackendDetailFor(error) ?? fallback;
    return PointyResultPanel(
      key: const ValueKey('purchase_result_failure'),
      tone: PointyResultTone.failure,
      title: unanswered
          ? l10n.checkoutResultUnansweredTitle
          : saving
          ? l10n.purchaseResultSaveFailedTitle
          : l10n.purchaseResultFailedTitle,
      subtitle: unanswered
          ? l10n.purchaseResultUnansweredSubtitle
          : l10n.purchaseResultFailedSubtitle,
      footer: PurchaseResultButtons(primary: retry, secondary: back),
      children: [
        PointyDetailCallout(
          key: const ValueKey('purchase_result_failure_reason'),
          icon: unanswered ? Icons.wifi_off_rounded : Icons.error_outline,
          tone: PointyCalloutTone.danger,
          title: unanswered ? l10n.checkoutResultCheckConnection : reason,
        ),
        PointyResultSection(
          title: l10n.checkoutResultWhatToDo,
          icon: Icons.lightbulb_outline_rounded,
          child: PointyResultTips(tips: [l10n.purchaseResultRetrySafe]),
        ),
      ],
    );
  }
}

/// The server doubts a cost: the bread bought for 130 and entered as 130 *per
/// loaf*. Shows what it found and lets the buyer decide — clearance stock and
/// thin margins are real, so this asks rather than blocks, unless the cost
/// cannot be right at all.
class PurchaseCostWarningsView extends StatelessWidget {
  const PurchaseCostWarningsView({
    super.key,
    required this.warnings,
    required this.onConfirm,
    required this.onReview,
  });

  final List<PurchaseCostWarning> warnings;
  final VoidCallback onConfirm;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final blocking = purchaseCostWarningsAreBlocking(warnings);
    final review = PurchaseResultButton(
      name: 'cost_review',
      label: blocking
          ? l10n.purchaseCostWarningFixButton
          : l10n.purchaseCostWarningReviewButton,
      icon: Icons.edit_outlined,
      onPressed: onReview,
    );
    return PointyResultPanel(
      key: const ValueKey('purchase_result_cost_warnings'),
      tone: blocking ? PointyResultTone.failure : PointyResultTone.attention,
      title: l10n.purchaseCostWarningTitle,
      subtitle: blocking
          ? l10n.purchaseCostWarningBlockedBody
          : l10n.purchaseCostWarningBody,
      footer: blocking
          ? PurchaseResultButtons(primary: review)
          : PurchaseResultButtons(
              primary: PurchaseResultButton(
                name: 'cost_confirm',
                label: l10n.purchaseCostWarningConfirmButton,
                icon: Icons.check_rounded,
                onPressed: onConfirm,
              ),
              secondary: review,
              focusPrimary: false,
            ),
      children: [
        for (final warning in warnings)
          PointyDetailCallout(
            icon: Icons.trending_up,
            tone: PointyCalloutTone.warning,
            title: warning.productName.isEmpty
                ? l10n.purchaseCostWarningTitle
                : warning.productName,
            message: warning.message,
          ),
        PointyResultSection(
          title: l10n.checkoutResultWhatToDo,
          icon: Icons.lightbulb_outline_rounded,
          child: PointyResultTips(tips: [l10n.purchaseResultCostTip]),
        ),
      ],
    );
  }
}
