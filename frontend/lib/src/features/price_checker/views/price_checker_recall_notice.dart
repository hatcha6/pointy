import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_lookup_result.dart';
import '../../../shared/design/design.dart';
import 'price_checker_kiosk_metrics.dart';

/// The kiosk's answer for a pack that must not be sold (§6.8.1): a calm,
/// full-screen safety notice instead of a price.
///
/// Written for a customer standing a metre away with the box in their hand:
/// one large sentence, one instruction, and the name and lot so they can tell
/// it is *their* pack. Nothing internal — no reason, no supplier, no cost —
/// because the server never sends any; the staff view has its own panel.
class PriceCheckerRecallNotice extends StatelessWidget {
  const PriceCheckerRecallNotice({
    super.key,
    required this.result,
    required this.metrics,
    this.header,
  });

  final PriceLookupResult result;
  final KioskMetrics metrics;

  /// The slim brand strip, so the notice still reads as this shop's screen.
  final Widget? header;

  /// Below this height a stacked notice drops its badge to keep the pack card
  /// on screen.
  static const double _badgeMinHeight = 480;

  bool get _expired => result.availability == PriceLookupAvailability.expired;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _expired
        ? l10n.priceCheckerExpiredTitle
        : l10n.priceCheckerRecalledTitle;
    // On a landscape shelf screen the badge sits beside the words, so the
    // sentence and the pack both stay on screen at full size; anywhere
    // narrower they stack, with the badge sized against the height so the
    // pack card is never pushed off the bottom.
    final wide = metrics.isWide;
    final badge = wide
        ? (metrics.size.height * 0.34).clamp(120.0, 320.0)
        : (metrics.size.height * 0.16).clamp(64.0, 220.0);
    final badgeWidget = _NoticeBadge(
      icon: _expired
          ? Icons.event_busy_rounded
          : Icons.do_not_disturb_on_outlined,
      diameter: badge,
    );
    final words = _Words(
      title: title,
      result: result,
      metrics: metrics,
      expired: _expired,
      centered: !wide,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) ...[header!, SizedBox(height: metrics.gap)],
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (metrics.size.width * (wide ? 0.9 : 0.94)).clamp(
                    260.0,
                    1400.0,
                  ),
                ),
                child: Semantics(
                  liveRegion: true,
                  label: '$title. ${l10n.priceCheckerStoppedBody}',
                  child: wide
                      ? Row(
                          children: [
                            badgeWidget,
                            SizedBox(width: metrics.gap * 2),
                            Expanded(child: words),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // A 3" shelf verifier has room for the sentence
                            // and the pack, not for a badge as well — and the
                            // tinted screen already says "stop".
                            if (metrics.size.height >= _badgeMinHeight) ...[
                              badgeWidget,
                              SizedBox(height: metrics.gap),
                            ],
                            words,
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sentence, the instruction, the pack, and the way back.
class _Words extends StatelessWidget {
  const _Words({
    required this.title,
    required this.result,
    required this.metrics,
    required this.expired,
    required this.centered,
  });

  final String title;
  final PriceLookupResult result;
  final KioskMetrics metrics;
  final bool expired;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final align = centered ? TextAlign.center : TextAlign.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textAlign: align,
          style: TextStyle(
            fontSize: metrics.font(36, min: 24, max: 80),
            fontWeight: FontWeight.w800,
            color: colors.danger,
            height: 1.2,
          ),
        ),
        SizedBox(height: metrics.gap * 0.5),
        Text(
          l10n.priceCheckerStoppedBody,
          textAlign: align,
          style: TextStyle(
            fontSize: metrics.font(24, min: 17, max: 48),
            fontWeight: FontWeight.w600,
            color: colors.ink,
            height: 1.3,
          ),
        ),
        SizedBox(height: metrics.gap * 1.2),
        _PackCard(
          result: result,
          metrics: metrics,
          expired: expired,
          centered: centered,
        ),
        SizedBox(height: metrics.gap),
        Text(
          l10n.priceCheckerScanAnother,
          textAlign: align,
          style: TextStyle(
            fontSize: metrics.font(15, min: 12, max: 24),
            color: colors.mutedInk,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// The notice's background: the kiosk's own page gradient, washed with the
/// danger tone just enough to read as "stop" from across an aisle without
/// shouting. Exposed so the kiosk view paints the whole screen, not a box.
List<Color> priceCheckerRecallBackground(BuildContext context) {
  final colors = context.pointyColors;
  return [
    Color.alphaBlend(colors.danger.withValues(alpha: 0.07), colors.page),
    Color.alphaBlend(
      colors.danger.withValues(alpha: 0.15),
      colors.surfaceSunken,
    ),
  ];
}

class _NoticeBadge extends StatelessWidget {
  const _NoticeBadge({required this.icon, required this.diameter});

  final IconData icon;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.danger.withValues(alpha: 0.14),
          colors.surface,
        ),
        shape: BoxShape.circle,
        border: Border.all(
          color: colors.danger.withValues(alpha: 0.35),
          width: diameter * 0.025,
        ),
      ),
      child: Icon(icon, size: diameter * 0.52, color: colors.danger),
    );
  }
}

/// Which pack this is: the name a customer recognises, and the lot code and
/// date printed on the box, so they can match the screen to their hand.
class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.result,
    required this.metrics,
    required this.expired,
    required this.centered,
  });

  final PriceLookupResult result;
  final KioskMetrics metrics;
  final bool expired;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final expiry = result.lotExpiry;
    final facts = <(IconData, String)>[
      if (result.lotCode.isNotEmpty)
        (
          Icons.inventory_2_outlined,
          l10n.priceCheckerLotCode(_ltr(result.lotCode)),
        ),
      if (expiry != null)
        (
          Icons.event_outlined,
          expired
              ? l10n.priceCheckerLotExpired(_ltr(_date(expiry)))
              : l10n.priceCheckerLotExpiry(_ltr(_date(expiry))),
        ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gap * 1.2,
        vertical: metrics.gap,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(metrics.gap * 1.1),
        border: Border.all(color: colors.danger.withValues(alpha: 0.28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            result.productName,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metrics.font(24, min: 17, max: 50),
              fontWeight: FontWeight.w700,
              color: colors.ink,
              height: 1.2,
            ),
          ),
          if (result.showsVariant) ...[
            SizedBox(height: metrics.gap * 0.3),
            Text(
              result.variantName,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: metrics.font(17, min: 13, max: 32),
                fontWeight: FontWeight.w500,
                color: colors.mutedInk,
              ),
            ),
          ],
          if (facts.isNotEmpty) ...[
            SizedBox(height: metrics.gap * 0.8),
            Wrap(
              alignment: centered ? WrapAlignment.center : WrapAlignment.start,
              spacing: metrics.gap * 0.6,
              runSpacing: metrics.gap * 0.5,
              children: [
                for (final (icon, label) in facts)
                  _Fact(icon: icon, label: label, metrics: metrics),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime value) =>
      DateFormat('yyyy/MM/dd', 'en').format(value);

  /// Lot codes and dates are Latin runs inside an Arabic sentence; an LTR
  /// isolate keeps «AB-12» and «2026/10/02» from being reordered by the RTL
  /// paragraph.
  static String _ltr(String value) => '\u2066$value\u2069';
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.metrics});

  final IconData icon;
  final String label;
  final KioskMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.gap * 0.7,
        vertical: metrics.gap * 0.4,
      ),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(metrics.gap * 1.5),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: metrics.font(17, min: 13, max: 28),
            color: colors.mutedInk,
          ),
          SizedBox(width: metrics.gap * 0.35),
          Text(
            label,
            style: TextStyle(
              fontSize: metrics.font(16, min: 12, max: 28),
              fontWeight: FontWeight.w700,
              color: colors.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
