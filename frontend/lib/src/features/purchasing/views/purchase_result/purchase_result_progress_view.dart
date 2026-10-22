import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';

/// A purchase order being sent, saved or received: what it is doing, what is
/// done, what is left. The steps already behind the order stay ticked while
/// its goods go in, so the whole sweep reads as one thing.
class PurchaseResultProgressView extends StatelessWidget {
  const PurchaseResultProgressView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.current,
  });

  final String title;
  final String subtitle;
  final List<String> steps;

  /// The step running now; those before it are done.
  final int current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyResultPanel(
      key: const ValueKey('purchase_result_progress'),
      tone: PointyResultTone.working,
      title: title,
      subtitle: subtitle,
      footer: Text(
        l10n.purchaseResultWorkingHint,
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
      ),
      children: [
        PointyStageTimeline(
          // The spinner at the top already says it is working.
          showRunningBar: false,
          stages: [
            for (final (index, label) in steps.indexed)
              PointyStageEntry(
                label: label,
                status: index < current
                    ? PointyStageStatus.done
                    : index == current
                    ? PointyStageStatus.running
                    : PointyStageStatus.pending,
              ),
          ],
        ),
      ],
    );
  }
}
