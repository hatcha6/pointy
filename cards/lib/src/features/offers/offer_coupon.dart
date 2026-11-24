import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/container_route.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../brand/brand_page.dart';
import '../esim/esim_store_page.dart';
import 'offer_text.dart';

/// The red every offer wears in the app (its pill, its banner).
const Color offerRed = Color(0xFFD92D20);

/// One offer as a coupon: its value large beside what it is, a tear line,
/// then the cards it takes, each one tap from its page, and when it ends.
class OfferCoupon extends StatelessWidget {
  const OfferCoupon({
    super.key,
    required this.offer,
    required this.signedIn,
    required this.brands,
    required this.onShopAll,
  });

  final CardOffer offer;
  final bool signedIn;

  /// The brands it takes a card of, as the shelf orders them.
  final List<CardBrand> brands;

  /// For an offer on everything: back to the shelf.
  final VoidCallback onShopAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headline = offerHeadline(l10n, offer);
    final ends = offerEndsText(l10n, offer, DateTime.now());
    final soon =
        offer.endsAt != null &&
        offer.endsAt!.difference(DateTime.now()).inHours < 48;
    final esim = offer.scope.categories.contains('esim');
    final everything = offer.scope.isEverything;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CardsRadii.card),
          side: BorderSide(
            color: scheme.outline.withValues(alpha: 0.6),
            width: 0.8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(CardsSpace.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Value(value: headline.value, caption: headline.caption),
                  const SizedBox(width: CardsSpace.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              offer.forEveryone
                                  ? Icons.local_offer_rounded
                                  : Icons.card_giftcard_rounded,
                              size: 14,
                              color: offerRed,
                            ),
                            const SizedBox(width: CardsSpace.xs),
                            Text(
                              offer.forEveryone
                                  ? l10n.offerForEveryone
                                  : l10n.offerForYou,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: offerRed,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: CardsSpace.xs),
                        Text(offer.title, style: theme.textTheme.titleMedium),
                        if (offer.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(offer.description, style: muted),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _TearLine(color: theme.scaffoldBackgroundColor),
            if (!everything && brands.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  CardsSpace.lg,
                  CardsSpace.md,
                  CardsSpace.lg,
                  CardsSpace.sm,
                ),
                child: Text(l10n.offerCovers, style: muted),
              ),
              if (brands.length <= 2)
                for (final brand in brands) _BrandRow(brand: brand)
              else
                _CoveredBrands(brands: brands),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.lg,
                CardsSpace.md,
                CardsSpace.lg,
                CardsSpace.lg,
              ),
              child: Wrap(
                spacing: CardsSpace.sm,
                runSpacing: CardsSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (ends != null)
                    Pill(
                      text: ends,
                      icon: Icons.schedule_rounded,
                      tone: soon ? PillTone.warning : PillTone.muted,
                    ),
                  if (signedIn && offer.usesLeft > 1)
                    Pill(
                      text: l10n.offerUsesLeft(offer.usesLeft),
                      icon: Icons.repeat_rounded,
                      tone: PillTone.muted,
                    ),
                  if (everything)
                    _Action(
                      label: l10n.offerShopAll,
                      icon: Icons.storefront_rounded,
                      onTap: onShopAll,
                    ),
                  if (esim)
                    _Action(
                      label: l10n.offerShopEsim,
                      icon: Icons.public_rounded,
                      onTap: () => EsimStorePage.open(context),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The offer's value, white on red, as a coupon's stub.
class _Value extends StatelessWidget {
  const _Value({required this.value, required this.caption});

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 84, minHeight: 84),
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.md,
        vertical: CardsSpace.sm,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CardsRadii.tile),
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [Color(0xFFF04438), Color(0xFFB42318)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Text(
            caption,
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A coupon's perforation: a dashed line between two notches the page shows
/// through.
class _TearLine extends StatelessWidget {
  const _TearLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.outline;
    return SizedBox(
      height: 20,
      child: CustomPaint(
        painter: _TearPainter(notch: color, dash: line),
      ),
    );
  }
}

class _TearPainter extends CustomPainter {
  const _TearPainter({required this.notch, required this.dash});

  final Color notch;
  final Color dash;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final paint = Paint()
      ..color = dash
      ..strokeWidth = 1.2;
    const radius = 10.0;
    for (var x = radius + 6; x < size.width - radius - 6; x += 9) {
      canvas.drawLine(Offset(x, mid), Offset(x + 4, mid), paint);
    }
    final hole = Paint()..color = notch;
    canvas
      ..drawCircle(Offset(0, mid), radius, hole)
      ..drawCircle(Offset(size.width, mid), radius, hole);
  }

  @override
  bool shouldRepaint(_TearPainter old) =>
      old.notch != notch || old.dash != dash;
}

/// The cards an offer takes, small, in a row that swipes.
class _CoveredBrands extends StatelessWidget {
  const _CoveredBrands({required this.brands});

  final List<CardBrand> brands;

  static const double _width = 104;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    final textHeight = MediaQuery.textScalerOf(context).scale(18);
    return SizedBox(
      height: _width / kCardAspect + CardsSpace.sm + textHeight + 4,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
        itemCount: brands.length,
        separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
        itemBuilder: (context, index) {
          final brand = brands[index];
          return SizedBox(
            width: _width,
            child: Pressable(
              semanticLabel: brand.name,
              onTap: () {
                Haptics.tap();
                BrandPage.open(context, brand, from: context);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ContainerSource(
                    child: CardArt(
                      brand: brand,
                      radius: CardsRadii.art,
                      shadow: false,
                    ),
                  ),
                  const SizedBox(height: CardsSpace.sm),
                  NameText(
                    brand.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One card an offer takes, as a row: its art small, its name and price,
/// and the way to its page.
class _BrandRow extends StatelessWidget {
  const _BrandRow({required this.brand});

  final CardBrand brand;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final from = brand.fromPrice;
    return Pressable(
      semanticLabel: brand.name,
      onTap: () {
        Haptics.tap();
        BrandPage.open(context, brand, from: context);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: CardsSpace.xs,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: ContainerSource(
                child: CardArt(brand: brand, radius: 10, shadow: false),
              ),
            ),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NameText(
                    brand.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (from != null)
                    Text(
                      l10n.fromPrice(formatMoney(l10n, from)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// A coupon's own way onward: to the shelf, or to the eSIM store.
class _Action extends StatelessWidget {
  const _Action({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    style: FilledButton.styleFrom(
      foregroundColor: offerRed,
      backgroundColor: offerRed.withValues(alpha: 0.1),
      visualDensity: VisualDensity.compact,
    ),
    onPressed: () {
      Haptics.tap();
      onTap();
    },
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}
