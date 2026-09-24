import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/operations_job.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import 'job_decline_sheet.dart';

/// A declined job, said in sentences: why it ended, who decided, what the
/// diagnosis fee stands at, and — the part a plain cancel used to lose —
/// whether the item is still on the shelf or has gone home.
class JobDeclinedCallout extends StatelessWidget {
  const JobDeclinedCallout({super.key, required this.job});

  final OperationsJob job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final reason = job.cancelReason;
    final cancelledAt = job.cancelledAt;
    final handedOverAt = job.handedOverAt;
    final lines = <String>[
      if (cancelledAt != null)
        l10n.jobDeclinedByLine(
          job.cancelledByName.trim().isEmpty ? '—' : job.cancelledByName,
          formatDateTime(cancelledAt),
        ),
      if (job.cancelNote.trim().isNotEmpty) '«${job.cancelNote.trim()}»',
      _feeLine(l10n),
      if (job.awaitingHandBack)
        l10n.jobAwaitingHandBackHint
      else if (handedOverAt != null)
        job.handedOverTo.trim().isEmpty
            ? l10n.jobHandedBackNoNameLine(formatDateTime(handedOverAt))
            : l10n.jobHandedBackLine(
                job.handedOverTo.trim(),
                formatDateTime(handedOverAt),
              ),
    ];

    return PointyDetailCallout(
      icon: Icons.assignment_return_outlined,
      tone: job.awaitingHandBack
          ? PointyCalloutTone.warning
          : PointyCalloutTone.neutral,
      title: l10n.jobDeclinedTitle,
      message: lines.join('\n'),
      trailing: reason == null
          ? null
          : PointyStatusPill(label: jobDeclineReasonLabel(l10n, reason)),
    );
  }

  String _feeLine(AppLocalizations l10n) {
    final fee = job.declineFee;
    if (fee == null || fee <= 0) {
      return l10n.jobDeclineNoFeeLine;
    }
    final amount = formatMoney(fee);
    if (job.order == null) {
      return l10n.jobDeclineFeeDueLine(amount);
    }
    if (job.settlementState.isSettled) {
      return l10n.jobDeclineFeeSettledLine(amount);
    }
    return job.orderSaleType == 'credit'
        ? l10n.jobDeclineFeeCreditLine(amount)
        : l10n.jobDeclineFeeDueLine(amount);
  }
}
