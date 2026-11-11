import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/esim_card_art.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import 'esim_banner_art.dart';
import 'esim_format.dart';
import 'esim_store_page.dart';

/// The shelf's door to eSIMs: a banner with its own picture. It asks the relay
/// once and appears only when eSIMs are on sale, so a build talking to a relay
/// without them shows nothing.
class EsimEntry extends StatefulWidget {
  const EsimEntry({super.key});

  @override
  State<EsimEntry> createState() => _EsimEntryState();
}

class _EsimEntryState extends State<EsimEntry>
    with SingleTickerProviderStateMixin {
  bool _started = false;

  /// The plane flies its route once, when the banner first shows.
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final esim = CardsScope.of(context).esim;
      if (!esim.shelf.value.available) {
        esim.loadShelf();
      }
    }
  }

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  void _fly() {
    if (_flight.isAnimating || _flight.isCompleted) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _flight.value = 1;
    } else {
      _flight.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EsimShelf>(
      valueListenable: CardsScope.of(context).esim.shelf,
      builder: (context, shelf, _) {
        if (!shelf.available) {
          return const SizedBox.shrink();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _fly();
          }
        });
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.xl,
            CardsSpace.gutter,
            0,
          ),
          child: Pressable(
            onTap: () {
              Haptics.tap();
              EsimStorePage.open(context);
            },
            child: _Banner(
              flight: _flight,
              from: _lowest(shelf),
              countries: esimBannerCountries(shelf),
              promo: _bestPromo(shelf),
            ),
          ),
        );
      },
    );
  }

  EsimPromo? _bestPromo(EsimShelf shelf) {
    EsimPromo? best;
    for (final row in shelf.destinations) {
      final promo = row.promo;
      if (promo != null && (best == null || promo.percent > best.percent)) {
        best = promo;
      }
    }
    return best;
  }

  Money? _lowest(EsimShelf shelf) {
    Money? lowest;
    for (final row in shelf.destinations) {
      if (lowest == null || row.fromPrice.compareTo(lowest) < 0) {
        lowest = row.fromPrice;
      }
    }
    return lowest;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.flight,
    required this.from,
    required this.countries,
    required this.promo,
  });

  final Animation<double> flight;
  final Money? from;
  final List<String> countries;

  /// The deepest promotion running on the shelf, if any.
  final EsimPromo? promo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final price = from;
    return LayoutBuilder(
      builder: (context, box) {
        // A tablet's or a desktop's shelf: the picture grows, the words too.
        final wide = box.maxWidth >= 600;
        final art = wide ? math.min(box.maxWidth * 0.42, 440.0) : 128.0;
        final inset = wide ? CardsSpace.xxl : CardsSpace.lg + CardsSpace.xs;
        return Container(
          clipBehavior: Clip.antiAlias,
          constraints: BoxConstraints(minHeight: wide ? 228 : 176),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.card),
            boxShadow: CardsShadows.hero,
            gradient: const LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: esimDeepColors,
              stops: [0, 0.55, 1],
            ),
          ),
          child: Stack(
            children: [
              PositionedDirectional(
                end: 0,
                top: 0,
                bottom: 0,
                width: art,
                child: ExcludeSemantics(
                  child: EsimBannerArt(countries: countries, flight: flight),
                ),
              ),
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  inset,
                  inset,
                  art + CardsSpace.sm,
                  inset,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Wrap(
                      spacing: CardsSpace.sm,
                      runSpacing: CardsSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          l10n.esimEntryKicker,
                          style:
                              (wide
                                      ? theme.textTheme.labelLarge
                                      : theme.textTheme.labelMedium)
                                  ?.copyWith(
                                    color: const Color(0xFFF7C777),
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        if (promo case final promo?)
                          Pill(
                            text: esimPromoLabel(l10n, promo),
                            tone: PillTone.promo,
                            icon: Icons.local_offer_rounded,
                          ),
                      ],
                    ),
                    const SizedBox(height: CardsSpace.xs),
                    Text(
                      l10n.esimEntryTitle,
                      style:
                          (wide
                                  ? theme.textTheme.headlineMedium
                                  : theme.textTheme.titleMedium)
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                              ),
                    ),
                    const SizedBox(height: CardsSpace.xs),
                    Text(
                      l10n.esimEntryBody,
                      style:
                          (wide
                                  ? theme.textTheme.bodyLarge
                                  : theme.textTheme.bodySmall)
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.82),
                              ),
                    ),
                    if (wide) ...[
                      const SizedBox(height: CardsSpace.md),
                      const EsimPerks(),
                    ],
                    SizedBox(height: wide ? CardsSpace.lg : CardsSpace.md),
                    Wrap(
                      spacing: wide ? CardsSpace.md : CardsSpace.sm,
                      runSpacing: CardsSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: wide
                                ? CardsSpace.xl
                                : CardsSpace.md + 2,
                            vertical: wide ? 11 : 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(
                              CardsRadii.pill,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                l10n.esimEntryAction,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: const Color(0xFF0A5A55),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (wide) ...[
                                const SizedBox(width: CardsSpace.xs),
                                Icon(
                                  Icons.adaptive.arrow_forward_rounded,
                                  size: 16,
                                  color: const Color(0xFF0A5A55),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (price != null)
                          Text(
                            l10n.esimEntryFrom(formatMoney(l10n, price)),
                            style:
                                (wide
                                        ? theme.textTheme.labelLarge
                                        : theme.textTheme.labelMedium)
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What an eSIM spares a traveller, as a line of ticks on the deep banner.
class EsimPerks extends StatelessWidget {
  const EsimPerks({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Colors.white.withValues(alpha: 0.92),
      fontWeight: FontWeight.w600,
    );
    return Wrap(
      spacing: CardsSpace.lg,
      runSpacing: CardsSpace.xs,
      children: [
        for (final perk in [
          l10n.esimPerkInstant,
          l10n.esimPerkNoPlastic,
          l10n.esimPerkTopUp,
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: Color(0xFFF7C777),
              ),
              const SizedBox(width: CardsSpace.xs),
              Text(perk, style: style),
            ],
          ),
      ],
    );
  }
}
