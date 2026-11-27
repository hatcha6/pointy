import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/glass_bar.dart';
import '../../shared/grouped.dart';
import '../../shared/side_back.dart';
import '../../shared/skeleton.dart';
import '../links/cards_link.dart';
import '../shelf/shelf_model.dart';
import '../sign_in/sign_in_sheet.dart';
import 'offer_coupon.dart';
import 'offer_text.dart';

/// Every offer this customer can use now (or, signed out, the ones for
/// everyone) as coupons, each with the cards it takes, one tap from buying.
/// What an offer's notification opens (`/offers`).
///
/// Built as the app's other pages are: the glass bar (the system's own on
/// iOS 26), its back in the iPhone Duo's side column, a readable column on a
/// wide screen, and two columns of coupons where there is room for them.
class OffersPage extends StatelessWidget {
  const OffersPage({super.key, required this.shelf});

  final ShelfModel shelf;

  /// Wider than this, coupons stand two abreast.
  static const double _twoColumns = 760;

  static Future<void> open(BuildContext context, ShelfModel shelf) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: const OffersLink().location,
            arguments: const ScreenName('offers'),
          ),
          builder: (_) => OffersPage(shelf: shelf),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return SideBack(
      child: Scaffold(
        extendBodyBehindAppBar: GlassBar.extendsBody,
        appBar: GlassBar(title: Text(l10n.offersTitle)),
        body: Builder(
          // Its own context: under SideBack, where the side column is
          // already off the width.
          builder: (context) => ListenableBuilder(
            listenable: Listenable.merge([offers, shelf]),
            builder: (context, _) => LayoutBuilder(
              builder: (context, constraints) {
                final two = constraints.maxWidth >= _twoColumns;
                final padding = CardsLayout.page(
                  context,
                  top: CardsSpace.sm,
                  bottom: MediaQuery.paddingOf(context).bottom + CardsSpace.xl,
                  maxWidth: two ? CardsLayout.shelf : CardsLayout.readable,
                );
                final list = offers.offers;
                final coupons = [
                  for (final offer in list)
                    _coupon(context, offer, offers.signedIn),
                ];
                return RefreshIndicator(
                  edgeOffset: MediaQuery.paddingOf(context).top,
                  onRefresh: () =>
                      Future.wait([offers.refresh(), shelf.refresh()]),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: padding,
                    children: [
                      if (offers.loaded && !offers.signedIn) ...[
                        const _SignInNote(),
                        const SizedBox(height: CardsSpace.lg),
                      ],
                      if (!offers.loaded)
                        for (var i = 0; i < 3; i++)
                          const Padding(
                            padding: EdgeInsets.only(bottom: CardsSpace.lg),
                            child: Skeleton(
                              height: 230,
                              radius: CardsRadii.card,
                            ),
                          )
                      else if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: CardsSpace.huge),
                          child: EmptyState(
                            icon: Icons.local_offer_outlined,
                            title: l10n.offersEmptyTitle,
                            body: l10n.offersEmptyBody,
                          ),
                        )
                      else ...[
                        _Summary(offers: list, signedIn: offers.signedIn),
                        const SizedBox(height: CardsSpace.lg),
                        if (two)
                          _Columns(children: coupons)
                        else
                          for (final coupon in coupons)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: CardsSpace.lg,
                              ),
                              child: coupon,
                            ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _coupon(BuildContext context, CardOffer offer, bool signedIn) {
    CardsScope.of(context).offers.seen(offer, 'offers');
    return OfferCoupon(
      offer: offer,
      signedIn: signedIn,
      brands: _covered(offer, shelf.shelf.brands),
      onShopAll: () => Navigator.of(context).maybePop(),
    );
  }

  /// The brands [offer] takes a card of, as the shelf orders them.
  static List<CardBrand> _covered(CardOffer offer, List<CardBrand> brands) => [
    for (final brand in brands)
      if (brand.items.any(
        (item) =>
            item.available &&
            offer.scope.covers(
              category: brand.category,
              brand: brand.key,
              item: item.key,
            ),
      ))
        brand,
  ];
}

/// How many offers there are, and when the soonest ends.
class _Summary extends StatelessWidget {
  const _Summary({required this.offers, required this.signedIn});

  final List<CardOffer> offers;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ends = offersSoonestEnd(l10n, offers, DateTime.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          signedIn
              ? l10n.offersEntryMine(offers.length)
              : l10n.offersEntryPublic(offers.length),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (ends != null)
          Text(
            ends,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Coupons two abreast, each row as tall as its taller coupon's top.
class _Columns extends StatelessWidget {
  const _Columns({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var start = 0; start < children.length; start += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: CardsSpace.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children[start]),
                const SizedBox(width: CardsSpace.lg),
                Expanded(
                  child: start + 1 < children.length
                      ? children[start + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Signed out: the offers shown are for everyone, and using one takes an
/// account.
class _SignInNote extends StatelessWidget {
  const _SignInNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Grouped(
      children: [
        Padding(
          padding: const EdgeInsets.all(CardsSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.card_giftcard_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: CardsSpace.md),
                  Expanded(
                    child: Text(
                      l10n.offersSignInBody,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CardsSpace.md),
              FilledButton(
                onPressed: () => ensureSignedIn(context),
                child: Text(l10n.signInAction),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
