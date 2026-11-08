import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../data/models/account_target.dart';

enum _Step { done, active, waiting, ended }

/// A top-up from order to account, step by step, each with its time: ordered,
/// paid, being sent, and how it ended (on the account, or the money back in
/// the customer's credit).
class TopUpTimeline extends StatelessWidget {
  const TopUpTimeline({super.key, required this.order, required this.kind});

  final CardOrder order;

  /// The account's kind, for the last step's words («تمّ الشحن»).
  final String kind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = order.status;
    final delivered = status == OrderStatus.delivered;
    final refunded = status == OrderStatus.refunded;
    final sending =
        status == OrderStatus.paid || status == OrderStatus.fulfilling;
    final paid = order.paidAt != null || sending || delivered || refunded;
    final rows = [
      (l10n.orderStepPlaced, _Step.done, order.createdAt),
      (l10n.orderStepPaid, paid ? _Step.done : _Step.waiting, order.paidAt),
      (
        l10n.orderStepSending(kind),
        sending
            ? _Step.active
            : delivered
            ? _Step.done
            : refunded
            ? _Step.ended
            : _Step.waiting,
        null,
      ),
      (
        refunded ? l10n.orderStepRefunded : l10n.toppedUpTitle(kind),
        delivered || refunded ? _Step.done : _Step.waiting,
        delivered || refunded ? order.completedAt : null,
      ),
    ];
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++)
          _StepRow(
            label: rows[i].$1,
            step: rows[i].$2,
            at: rows[i].$3,
            last: i == rows.length - 1,
            refunded: refunded && i == rows.length - 1,
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.step,
    required this.at,
    required this.last,
    required this.refunded,
  });

  final String label;
  final _Step step;
  final DateTime? at;
  final bool last;

  /// The last step of a refunded top-up: done, but not a success.
  final bool refunded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = MaterialLocalizations.of(context);
    final when = at?.toLocal();
    final color = switch (step) {
      _Step.done when refunded => scheme.tertiary,
      _Step.done || _Step.active => scheme.primary,
      _Step.waiting || _Step.ended => scheme.outlineVariant,
    };
    final dot = switch (step) {
      _Step.done => Icon(
        refunded ? Icons.undo_rounded : Icons.check_rounded,
        size: 14,
        color: scheme.onPrimary,
      ),
      _Step.active => SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: scheme.onPrimary,
        ),
      ),
      _Step.ended => Icon(
        Icons.remove_rounded,
        size: 14,
        color: scheme.onSurfaceVariant,
      ),
      _Step.waiting => null,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: CardsMotion.standard,
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: step == _Step.waiting || step == _Step.ended
                        ? scheme.surface
                        : color,
                    border: Border.all(color: color, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: dot,
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: step == _Step.done
                          ? scheme.primary.withValues(alpha: 0.5)
                          : scheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : CardsSpace.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: step == _Step.active
                            ? FontWeight.w700
                            : null,
                        color: step == _Step.waiting || step == _Step.ended
                            ? scheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                  ),
                  if (when != null && step == _Step.done)
                    Text(
                      // The app's digits are 0–9 throughout.
                      asciiDigits(
                        local.formatTimeOfDay(TimeOfDay.fromDateTime(when)),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
