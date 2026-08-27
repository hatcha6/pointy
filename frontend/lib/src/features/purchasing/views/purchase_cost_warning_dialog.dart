import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_cost_warning.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Shows what the backend found wrong with a purchase cost and asks whether to
/// record it anyway.
///
/// Deliberately shows the two numbers rather than a generic "check the cost":
/// "130.00 for something that sells for 1.00" is recognisable as a mistake at a
/// glance, and that is the whole job here. The case this was built from went
/// unnoticed for weeks and erased eleven points of the shop's gross margin.
///
/// Returns true when the buyer confirms. A blocking warning offers no
/// confirmation at all — the POS cash-purchase path refuses outright, and an
/// offer that led nowhere would be worse than none.
Future<bool> showPurchaseCostWarningDialog(
  BuildContext context, {
  required List<PurchaseCostWarning> warnings,
}) async {
  if (warnings.isEmpty) {
    return false;
  }
  final l10n = AppLocalizations.of(context)!;
  final blocking = purchaseCostWarningsAreBlocking(warnings);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final spacing = AdaptiveSpacing.of(dialogContext);
      final colors = dialogContext.pointyColors;
      return AlertDialog(
        icon: Icon(Icons.report_problem_outlined, color: colors.warning),
        title: Text(l10n.purchaseCostWarningTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                blocking
                    ? l10n.purchaseCostWarningBlockedBody
                    : l10n.purchaseCostWarningBody,
              ),
              SizedBox(height: spacing.md),
              for (final warning in warnings) ...[
                PointyDetailCallout(
                  icon: Icons.trending_up,
                  tone: PointyCalloutTone.warning,
                  title: warning.productName.isEmpty
                      ? l10n.purchaseCostWarningTitle
                      : warning.productName,
                  message: warning.message,
                ),
                SizedBox(height: spacing.sm),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              blocking
                  ? l10n.purchaseCostWarningFixButton
                  : l10n.purchaseCostWarningReviewButton,
            ),
          ),
          if (!blocking)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.purchaseCostWarningConfirmButton),
            ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
