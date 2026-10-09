import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import 'service_texts.dart';

/// Tells the cashier what a sale's airtime and bill lines did when the
/// provider did not do them — refused, or never answered — in words about
/// airtime and bills, and what to do about the customer's money:
///
/// * **refused** — nothing was sent or paid, so the money goes back, and the
///   reason is said plainly (the voucher balance, a price that moved, the
///   provider unreachable, a number it did not accept);
/// * **unknown** — the request left and nothing came back, so it may have been
///   done: do not send it again and do not refund until somebody has looked.
///
/// [rows] are the lines that were not performed; [receiptNumber] names the
/// invoice they belong to, which is where the real state of each is to be
/// read.
Future<void> showServiceChargeIssueDialog(
  BuildContext context,
  List<IntegrationChargeResult> rows, {
  String? receiptNumber,
}) {
  final unknown = rows.any((row) => row.needsAttention);
  return showDialog<void>(
    context: context,
    // The unknown case is not dismissed by tapping away: it is the one state
    // where doing nothing about it is a real risk.
    barrierDismissible: !unknown,
    builder: (dialogContext) =>
        ServiceChargeIssueDialog(rows: rows, receiptNumber: receiptNumber),
  );
}

class ServiceChargeIssueDialog extends StatelessWidget {
  const ServiceChargeIssueDialog({
    super.key,
    required this.rows,
    this.receiptNumber,
  });

  final List<IntegrationChargeResult> rows;
  final String? receiptNumber;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final unknown = rows.where((row) => row.needsAttention).toList();
    final refused = rows.where((row) => !row.needsAttention).toList();
    final allBills = rows.every((row) => row.isBill);
    final allAirtime = rows.every((row) => row.isAirtime);
    final hasUnknown = unknown.isNotEmpty;
    // An unknown result outranks a refusal: it is the one that can cost money.
    final title = hasUnknown
        ? (allBills
              ? l10n.posServiceIssueUnknownBillTitle
              : l10n.posServiceIssueUnknownAirtimeTitle)
        : allBills
        ? l10n.posServiceIssueRefusedBillTitle
        : allAirtime
        ? l10n.posServiceIssueRefusedAirtimeTitle
        : l10n.posServiceIssueRefusedMixedTitle;
    final lead = hasUnknown
        ? (allBills
              ? l10n.posServiceIssueUnknownBillBody
              : l10n.posServiceIssueUnknownAirtimeBody)
        : (allBills
              ? l10n.posServiceIssueRefusedBillBody
              : l10n.posServiceIssueRefusedAirtimeBody);

    Widget line(IntegrationChargeResult row, {required bool isUnknown}) {
      final target = ltrIsolated(row.subscriberRef);
      final reference = row.providerReference.trim();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                target,
                row.optionLabel,
              ].where((part) => part.trim().isNotEmpty).join(' · '),
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (isUnknown) ...[
              if (reference.isNotEmpty)
                Text(
                  l10n.posServiceIssueReference(ltrIsolated(reference)),
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
            ] else
              Text(
                serviceChargeReason(l10n, row),
                style: textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                  height: 1.35,
                ),
              ),
          ],
        ),
      );
    }

    return AlertDialog(
      key: const ValueKey('service_issue_dialog'),
      icon: Icon(
        hasUnknown ? Icons.help_outline : Icons.error_outline,
        color: hasUnknown ? colors.warning : colors.danger,
        size: 40,
      ),
      title: Text(title, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                lead,
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              for (final row in unknown) line(row, isUnknown: true),
              if (hasUnknown) ...[
                Text(
                  l10n.posServiceIssueUnknownHint,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                    height: 1.4,
                  ),
                ),
                if ((receiptNumber ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      l10n.posServiceIssueReceipt(ltrIsolated(receiptNumber!)),
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                if (refused.isNotEmpty) const Divider(height: 24),
              ],
              for (final row in refused) line(row, isUnknown: false),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton(
          key: const ValueKey('service_issue_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.closeButton),
        ),
      ],
    );
  }
}
