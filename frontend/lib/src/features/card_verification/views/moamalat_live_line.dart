import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/moamalat.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/moamalat_live_watch.dart';

/// "On terminal X at 10:01" for a swipe, for every line that names one.
String moamalatSwipeWhere(BuildContext context, MoamalatSwipe swipe) =>
    AppLocalizations.of(context)!.moamalatSwipeWhere(
      ltrIsolated(swipe.terminalId),
      ltrIsolated(TimeOfDay.fromDateTime(swipe.at.toLocal()).format(context)),
    );

/// One quiet line under a card tender: whether the terminal's swipe for this
/// line has reached Moamalat yet. Informational only — it never blocks the
/// confirm button, and it is absent when the shop has no live link.
class MoamalatLiveLine extends StatelessWidget {
  const MoamalatLiveLine({super.key, required this.watch, this.swipe});

  final MoamalatLiveWatch watch;

  /// The swipe the sheet paired with this line, if any.
  final MoamalatSwipe? swipe;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final state = watch.latest?.state;
    final swipe = this.swipe;
    final (
      IconData icon,
      Color color,
      String text,
      bool busy,
    ) = switch (state) {
      null when watch.isPolling => (
        Icons.credit_card,
        colors.mutedInk,
        l10n.moamalatLiveConnecting,
        true,
      ),
      MoamalatLinkState.needsReauth => (
        Icons.cloud_off_outlined,
        colors.mutedInk,
        l10n.moamalatLiveOffline,
        false,
      ),
      MoamalatLinkState.alive when swipe != null => (
        Icons.verified,
        colors.success,
        '${l10n.moamalatLiveSeen(formatMoney(swipe.amount))} '
            '${moamalatSwipeWhere(context, swipe)}',
        false,
      ),
      MoamalatLinkState.alive when watch.isPolling && watch.isLive => (
        Icons.hourglass_top,
        colors.mutedInk,
        l10n.moamalatLiveWaiting,
        true,
      ),
      MoamalatLinkState.alive => (
        Icons.schedule,
        colors.mutedInk,
        l10n.moamalatLiveLater,
        false,
      ),
      _ => (Icons.credit_card, colors.mutedInk, '', false),
    };
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 6, start: 4, end: 4),
      child: Row(
        key: const ValueKey('moamalat_live_line'),
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          if (busy)
            SizedBox.square(
              dimension: 12,
              child: PointySpinner(strokeWidth: 1.5, color: color),
            ),
        ],
      ),
    );
  }
}
