import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/job_bill.dart';

/// «الحساب»: what this job's invoice will come to, before anyone opens it.
///
/// Parts and services are the lines; the agreed price is what the customer was
/// told. The card adds them up the way the invoice will — any part of the agreed
/// price no line accounts for shows as its own row — so the number at the
/// bottom is the number on the invoice. It says so when the lines already run
/// past the agreed price, which is the moment to call the customer.
class JobBillSection extends StatelessWidget {
  const JobBillSection({super.key, required this.bill});

  final JobBill bill;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final agreed = bill.agreedPrice;
    final priceName = bill.agreedIsApproved
        ? l10n.jobBillAgreedPrice
        : l10n.jobBillQuotedPrice;

    return PointyDetailSection(
      key: const ValueKey('job_bill_section'),
      title: l10n.jobBillSectionTitle,
      icon: Icons.receipt_long_outlined,
      child: bill.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: spacing.sm),
              child: Text(
                l10n.jobBillEmpty,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                JobBillRow(l10n.jobBillPartsLabel, bill.parts),
                JobBillRow(l10n.jobBillServicesLabel, bill.services),
                if (bill.remainder > 0)
                  JobBillRow(
                    l10n.jobBillRemainderLabel(priceName),
                    bill.remainder,
                    key: const ValueKey('job_bill_remainder'),
                  ),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: spacing.xs),
                  child: Divider(height: 1, color: colors.line),
                ),
                JobBillRow(
                  l10n.jobBillTotalLabel,
                  bill.total,
                  key: const ValueKey('job_bill_total'),
                  strong: true,
                ),
                if (agreed != null) ...[
                  SizedBox(height: spacing.xs),
                  Text(
                    l10n.jobBillPriceLine(priceName, formatMoney(agreed)),
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
                if (bill.remainder > 0) ...[
                  SizedBox(height: spacing.xs),
                  Text(
                    l10n.jobBillRemainderHint(priceName),
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
                if (bill.overAgreedBy > 0) ...[
                  SizedBox(height: spacing.sm),
                  PointyInlineMessage.warning(
                    key: const ValueKey('job_bill_over_agreed'),
                    message: l10n.jobBillOverAgreed(
                      priceName,
                      formatMoney(bill.overAgreedBy),
                    ),
                    icon: Icons.warning_amber_outlined,
                  ),
                ],
              ],
            ),
    );
  }
}

/// One line of a job's bill: a label and its amount, or — [strong] — the total.
/// Shared by the job's «الحساب» card and the invoice dialog, so the two read
/// the same.
class JobBillRow extends StatelessWidget {
  const JobBillRow(this.label, this.amount, {super.key, this.strong = false});

  final String label;
  final double amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong
                  ? textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)
                  : textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
          ),
          Text(
            formatMoney(amount),
            style: PointyTypography.numeric(
              (strong ? textTheme.titleLarge : textTheme.bodyMedium) ??
                  const TextStyle(),
            ).copyWith(fontWeight: strong ? FontWeight.w800 : FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
