import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/register_session_summary.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/card_receipt_status.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/components/components.dart';

/// How much of a shift's card money the shop can actually prove.
///
/// A manager closing a drawer has one question here and it is not "how much
/// went through the terminal" — the payment-methods section already answers
/// that. It is "how much of it is backed by something I could show someone".
/// So the headline is the comparison itself, "2,000 verified of 4,000", and the
/// bar under it is the same sentence drawn to scale: the eye gets the ratio
/// before it reads a single digit.
///
/// Buckets that are zero are not drawn. A shift where everything verified
/// should look calm and finished, not like a form with empty rows.
class CardReceiptVerificationSection extends StatelessWidget {
  const CardReceiptVerificationSection({super.key, required this.totals});

  final CardReceiptTotals totals;

  @override
  Widget build(BuildContext context) {
    if (!totals.hasCardPayments) {
      // No card takings this shift, so there is nothing to verify and nothing
      // worth a section heading.
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final segments = _segments(l10n, colors);

    return PointyDetailSection(
      title: l10n.sessionCardReceiptsTitle,
      icon: Icons.verified_user_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.sessionCardReceiptsHeadline(
                    formatMoney(totals.verified),
                    formatMoney(totals.gross),
                  ),
                  // Deliberately NOT reddened when something is flagged: this
                  // line states how much IS verified, which is the good half
                  // of the news. Painting it as an error would say the 2,000
                  // is the problem. The callout below carries the alarm.
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.ink,
                  ),
                ),
              ),
              if (totals.isFullyVerified)
                Icon(Icons.verified_outlined, color: colors.success, size: 22),
            ],
          ),
          SizedBox(height: spacing.sm),
          _VerificationBar(segments: segments),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.md,
            runSpacing: spacing.xs,
            children: [
              for (final segment in segments)
                _SegmentLegend(segment: segment),
            ],
          ),
          if (totals.needsAttention) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.error(
              key: const ValueKey('session_card_receipts_attention'),
              compact: true,
              message: l10n.sessionCardReceiptsNeedsAttention(
                totals.flaggedCount,
              ),
            ),
          ] else if (totals.pending > 0) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage(
              key: const ValueKey('session_card_receipts_pending'),
              compact: true,
              icon: Icons.schedule_outlined,
              message: l10n.sessionCardReceiptsPendingNote(totals.pendingCount),
            ),
          ] else if (totals.isFullyVerified) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.success(
              key: const ValueKey('session_card_receipts_all_verified'),
              compact: true,
              message: l10n.sessionCardReceiptsAllVerified,
            ),
          ],
        ],
      ),
    );
  }

  /// The buckets worth drawing, worst last so the eye lands on trouble at the
  /// end of the bar rather than hunting for it in the middle.
  List<_Segment> _segments(AppLocalizations l10n, PointySemanticColors colors) {
    final candidates = <(CardReceiptStatus, double)>[
      (CardReceiptStatus.verified, totals.verified),
      (CardReceiptStatus.pending, totals.pending),
      (CardReceiptStatus.noReceipt, totals.noReceipt),
      (CardReceiptStatus.unavailable, totals.unavailable),
      (CardReceiptStatus.flagged, totals.flagged),
    ];
    return [
      for (final (status, amount) in candidates)
        if (amount > 0)
          _Segment(
            label: status.label(l10n),
            amount: amount,
            // "Pending" and "no receipt" both sit on muted ink, which made them
            // one indistinguishable grey band — the legend told them apart and
            // the bar did not. Absence is drawn faint instead of given a colour
            // of its own: money with no receipt behind it should look like a
            // gap in the bar, which is what it is.
            color: status == CardReceiptStatus.noReceipt
                ? status.color(colors).withValues(alpha: 0.30)
                : status.color(colors),
            share: totals.gross > 0 ? amount / totals.gross : 0,
          ),
    ];
  }
}

class _Segment {
  const _Segment({
    required this.label,
    required this.amount,
    required this.color,
    required this.share,
  });

  final String label;
  final double amount;
  final Color color;
  final double share;
}

/// One pill split into its buckets by width.
///
/// Each segment keeps a minimum width so a single flagged dinar in a large
/// shift is still visible — the whole point of the bar is that a problem
/// cannot hide inside a rounding error.
class _VerificationBar extends StatelessWidget {
  const _VerificationBar({required this.segments});

  final List<_Segment> segments;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(PointyRadii.pill),
      child: SizedBox(
        height: 12,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: colors.subtleFill),
                ),
                Row(
                  // Stretch, not the default centre: a ColoredBox with no
                  // child takes the smallest size its constraints allow, and
                  // a Row hands its children LOOSE cross-axis constraints —
                  // so every segment rendered at zero height and the bar came
                  // out blank.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final segment in segments)
                      SizedBox(
                        width: (segment.share * width).clamp(6.0, width),
                        child: ColoredBox(color: segment.color),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SegmentLegend extends StatelessWidget {
  const _SegmentLegend({required this.segment});

  final _Segment segment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: segment.color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${segment.label} ${formatMoney(segment.amount)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
