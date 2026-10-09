import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import 'pos_service_card.dart';
import 'service_card_layout.dart';
import 'service_card_art.dart';
import 'service_test_mode_banner.dart';
import 'wheel_scroll_row.dart';

/// One card of the strip: which service, how far it reaches, what a tap does.
class ServiceStripEntry {
  const ServiceStripEntry({
    required this.kind,
    this.countries = 0,
    this.providers = 0,
    this.onTap,
    this.isNew = true,
  });

  final ServiceCardKind kind;
  final int countries;
  final int providers;
  final VoidCallback? onTap;

  /// Still wears the «جديد» badge: it is a month from when the till first
  /// showed it, not for ever.
  final bool isNew;
}

/// The new services as a row of cards above the brands in the «الكل» tab, so
/// a concept that is new to the shop is seen without opening any tab. The
/// cards are as wide as the brand cards below; more than fit scroll sideways.
class ServicesStrip extends StatelessWidget {
  const ServicesStrip({
    super.key,
    required this.entries,
    this.testMode = false,
    this.showHeading = true,
  });

  final List<ServiceStripEntry> entries;

  /// The relay is buying from its test supplier: said over the cards, which
  /// are the first thing a cashier sees of the services.
  final bool testMode;

  /// Off when the strip answers a search: the cards speak for themselves.
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeading) ...[
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: colors.accentAmber,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.posServicesStripTitle,
                style: textTheme.titleSmall?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.posServicesStripHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
        ],
        if (testMode) ...[
          const ServiceTestModeBanner(compact: true),
          SizedBox(height: spacing.sm),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            var layout = ServiceCardLayout.forWidth(
              constraints.maxWidth,
              spacing,
            );
            if (entries.length > layout.columns) {
              // More cards than fit: the next one peeks in from the edge, so
              // the row is seen to go on.
              final tileWidth =
                  (constraints.maxWidth + layout.gap) / (layout.columns + 0.4) -
                  layout.gap;
              layout = (
                columns: layout.columns,
                tileWidth: tileWidth,
                gap: layout.gap,
              );
            }
            final dense = AppBreakpoints.isShortHeight(context);
            final extent = PosServiceCard.extentFor(
              layout.tileWidth,
              scaler: MediaQuery.textScalerOf(context),
              dense: dense,
            );
            // Room under the row for a lifted card's shadow.
            return SizedBox(
              height: extent + 12,
              child: WheelScrollRow(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (index, entry) in entries.indexed) ...[
                      if (index > 0) SizedBox(width: layout.gap),
                      SizedBox(
                        width: layout.tileWidth,
                        height: extent,
                        child: PosServiceCard(
                          key: ValueKey('service_card_${entry.kind.name}'),
                          kind: entry.kind,
                          countries: entry.countries,
                          providers: entry.providers,
                          onTap: entry.onTap,
                          showsNewBadge: entry.isNew,
                          dense: dense,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
