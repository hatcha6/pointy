import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/container_route.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../brand/brand_page.dart';
import '../offers/offer_pill.dart';

/// A brand on the shelf: its card, name and lowest price, and up to two
/// badges over the art.
///
/// The start corner says the one thing that matters most, in this order:
/// not sold now, sold on the website only, an offer for this customer, the
/// brand's own badge or a running promotion. The end corner says where a
/// game is played. When both are there, the platform is its logo alone, and
/// the start badge has the rest of the width, its words ellipsized: two
/// names never run into each other on a phone's tile.
class BrandTile extends StatelessWidget {
  const BrandTile({super.key, required this.brand, this.large = false});

  final CardBrand brand;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final from = brand.fromPrice;
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return Pressable(
      semanticLabel: brand.name,
      // The page opens out of the card's art, and closes back into it.
      onTap: () => BrandPage.open(context, brand, from: context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => ListenableBuilder(
              listenable: offers,
              builder: (context, _) => Stack(
                children: [
                  ContainerSource(
                    child: CardArt(
                      brand: brand,
                      muted: !brand.anyAvailable,
                      radius: large ? CardsRadii.tile : CardsRadii.art,
                    ),
                  ),
                  ..._badges(
                    context,
                    width: constraints.maxWidth,
                    offer: brand.anyAvailable && !brand.webOnly
                        ? offers.forBrand(brand)
                        : null,
                    section: large ? l10n.featuredTitle : null,
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: large ? CardsSpace.md : CardsSpace.sm),
          NameText(
            brand.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: large
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.titleSmall,
          ),
          if (from != null)
            Text(
              l10n.fromPrice(formatMoney(l10n, from)),
              style: PointyTypography.numeric(theme.textTheme.bodySmall!)
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  List<Widget> _badges(
    BuildContext context, {
    required double width,
    required CardOffer? offer,
    String? section,
  }) {
    final start = _startBadge(context, offer, section: section);
    final platform = brand.gamePlatform;
    // The logo chip is 23 wide; a gap between the two.
    final room =
        width -
        CardsSpace.sm * 2 -
        (platform != null && start != null ? 23 + CardsSpace.xs : 0);
    return [
      if (start != null)
        PositionedDirectional(
          top: CardsSpace.sm,
          start: CardsSpace.sm,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room.clamp(40, width)),
            child: start,
          ),
        ),
      // Across from the badge: a game's name alone does not say where it is
      // played. Beside another badge, only its logo.
      if (platform != null)
        PositionedDirectional(
          top: CardsSpace.sm,
          end: CardsSpace.sm,
          child: PlatformPill(platform, compact: start != null),
        ),
    ];
  }

  /// What the start corner says. None when it would only repeat [section],
  /// the title the tile already sits under («الأكثر طلباً»).
  Widget? _startBadge(
    BuildContext context,
    CardOffer? offer, {
    String? section,
  }) {
    if (!brand.anyAvailable) {
      return Pill(
        text: AppLocalizations.of(context).unavailableNow,
        tone: PillTone.muted,
      );
    }
    if (brand.webOnly) {
      return const WebOnlyPill();
    }
    if (offer != null) {
      return OfferPill(offer: offer, surface: 'home');
    }
    final text = brand.badge.isNotEmpty
        ? brand.badge
        : brand.items.where((i) => i.onPromo).firstOrNull?.promoBadge ?? '';
    return text.isEmpty || text.trim() == section?.trim()
        ? null
        : Pill(text: text, tone: PillTone.promo);
  }
}
