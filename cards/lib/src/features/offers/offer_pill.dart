import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/pill.dart';
import '../../shared/money_text.dart';
import 'offer_text.dart';
import 'offers_model.dart';

/// An offer's badge: its words on the offer's red, a gift for one made for
/// this customer, a tag for one made for everyone. It tells analytics it was
/// seen on [surface], once a session.
class OfferPill extends StatefulWidget {
  const OfferPill({super.key, required this.offer, required this.surface});

  final CardOffer offer;
  final String surface;

  @override
  State<OfferPill> createState() => _OfferPillState();
}

class _OfferPillState extends State<OfferPill> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        CardsScope.of(context).offers.seen(widget.offer, widget.surface);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Pill(
    text: offerBadgeText(AppLocalizations.of(context), widget.offer),
    tone: PillTone.offer,
    icon: widget.offer.forEveryone
        ? Icons.local_offer_rounded
        : Icons.card_giftcard_rounded,
  );
}

/// [brand]'s offer badge, following the offers as they are read; [orElse]
/// (its own badge, a promotion) when no offer covers it.
class BrandOfferBadge extends StatelessWidget {
  const BrandOfferBadge({
    super.key,
    required this.brand,
    required this.surface,
    this.orElse,
  });

  final CardBrand brand;
  final String surface;
  final Widget? orElse;

  @override
  Widget build(BuildContext context) {
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return ListenableBuilder(
      listenable: offers,
      builder: (context, _) {
        // A card not sold now, or sold on the website only, keeps saying so.
        final offer = brand.anyAvailable && !brand.webOnly
            ? offers.forBrand(brand)
            : null;
        if (offer == null) {
          return orElse ?? const SizedBox.shrink();
        }
        return OfferPill(offer: offer, surface: surface);
      },
    );
  }
}

/// The badge of an offer covering [category] (eSIMs: "esim"), or [orElse].
class CategoryOfferBadge extends StatelessWidget {
  const CategoryOfferBadge({
    super.key,
    required this.category,
    required this.surface,
    this.orElse,
  });

  final String category;
  final String surface;
  final Widget? orElse;

  @override
  Widget build(BuildContext context) {
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return ListenableBuilder(
      listenable: offers,
      builder: (context, _) => switch (offers.forCategory(category)) {
        final offer? => OfferPill(offer: offer, surface: surface),
        null => orElse ?? const SizedBox.shrink(),
      },
    );
  }
}

/// What [item] of [brand] costs with its offer, under its price: shown when
/// an offer takes something off one card.
class ItemOfferPrice extends StatelessWidget {
  const ItemOfferPrice({super.key, required this.brand, required this.item});

  final CardBrand brand;
  final CardItem item;

  @override
  Widget build(BuildContext context) {
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return ListenableBuilder(
      listenable: offers,
      builder: (context, _) {
        final offer = offers.forItem(brand, item);
        final off = offer?.discountOn(OffersModel.lineFor(brand, item, 1));
        if (offer == null || off == null || !off.isPositive) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        const red = Color(0xFFD92D20);
        // A tag and the price with the offer: short enough for the
        // narrowest tile, and read aloud in full.
        return Semantics(
          label: l10n.offerOnItem(formatMoney(l10n, item.price - off)),
          excludeSemantics: true,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.local_offer_rounded, size: 12, color: red),
                const SizedBox(width: 3),
                Text(
                  formatMoney(l10n, item.price - off),
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: red, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The offer on a brand's page, above its cards: what it gives, its title,
/// when it ends, and, before signing in, that signing in uses it.
class OfferBanner extends StatelessWidget {
  const OfferBanner({super.key, required this.brand});

  final CardBrand brand;

  @override
  Widget build(BuildContext context) {
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return ListenableBuilder(
      listenable: offers,
      builder: (context, _) {
        final offer = offers.forBrand(brand);
        if (offer == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: CardsSpace.lg),
          child: _Banner(offer: offer, signedIn: offers.signedIn),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.offer, required this.signedIn});

  final CardOffer offer;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    const red = Color(0xFFD92D20);
    final ends = offerEndsText(l10n, offer, DateTime.now());
    final lines = [
      if (offer.description.isNotEmpty) offer.description,
      ?ends,
      if (!signedIn) l10n.offerSignInToUse,
    ];
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(CardsRadii.tile),
        border: Border.all(color: red.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: red, shape: BoxShape.circle),
            child: Icon(
              offer.forEveryone
                  ? Icons.local_offer_rounded
                  : Icons.card_giftcard_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      offer.forEveryone ? l10n.offerForAll : l10n.offerForYou,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: red,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: CardsSpace.sm),
                    Flexible(
                      child: OfferPill(offer: offer, surface: 'brand'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(offer.title, style: theme.textTheme.titleSmall),
                for (final line in lines)
                  Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
