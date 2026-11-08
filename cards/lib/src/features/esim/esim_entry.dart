import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pressable.dart';
import 'esim_banner_art.dart';
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
            child: _Banner(flight: _flight, from: _lowest(shelf)),
          ),
        );
      },
    );
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
  const _Banner({required this.flight, required this.from});

  final Animation<double> flight;
  final Money? from;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final price = from;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.hero,
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [Color(0xFF0F766E), Color(0xFF0A5A55), Color(0xFF06302F)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: flight,
                  builder: (context, _) => CustomPaint(
                    painter: EsimBannerArtPainter(
                      flight:
                          0.04 +
                          Curves.easeInOutCubic.transform(flight.value) * 0.96,
                      rtl: rtl,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              CardsSpace.lg + CardsSpace.xs,
              CardsSpace.lg + CardsSpace.xs,
              128,
              CardsSpace.lg + CardsSpace.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.esimEntryKicker,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xFFF7C777),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  l10n.esimEntryTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  l10n.esimEntryBody,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
                const SizedBox(height: CardsSpace.md),
                Wrap(
                  spacing: CardsSpace.sm,
                  runSpacing: CardsSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: CardsSpace.md + CardsSpace.xs,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(CardsRadii.pill),
                      ),
                      child: Text(
                        l10n.esimEntryAction,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF0A5A55),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (price != null)
                      Text(
                        l10n.esimEntryFrom(formatMoney(l10n, price)),
                        style: theme.textTheme.labelMedium?.copyWith(
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
  }
}
