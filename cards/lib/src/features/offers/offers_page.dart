import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../esim/esim_store_page.dart';
import '../home/brand_shelf.dart';
import '../links/cards_link.dart';
import '../shelf/shelf_model.dart';
import '../sign_in/sign_in_sheet.dart';
import 'offer_pill.dart';

/// Every offer this customer can use now (or, signed out, the ones for
/// everyone), each with the cards it covers, one tap from buying. What an
/// offer's notification opens (`/offers`).
class OffersPage extends StatelessWidget {
  const OffersPage({super.key, required this.shelf});

  final ShelfModel shelf;

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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.offersTitle)),
      body: ListenableBuilder(
        listenable: Listenable.merge([offers, shelf]),
        builder: (context, _) {
          final list = offers.offers;
          final signIn = !offers.signedIn
              ? _SignInNote(onSignIn: () => ensureSignedIn(context))
              : null;
          if (list.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(CardsSpace.gutter),
              children: [
                ?signIn,
                EmptyState(
                  icon: Icons.local_offer_outlined,
                  title: l10n.offersEmptyTitle,
                  body: l10n.offersEmptyBody,
                ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: offers.refresh,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: CardsSpace.lg),
              children: [
                if (signIn != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: CardsSpace.gutter,
                    ),
                    child: signIn,
                  ),
                for (final offer in list)
                  _OfferSection(
                    offer: offer,
                    signedIn: offers.signedIn,
                    brands: _covered(offer, shelf.shelf.brands),
                  ),
              ],
            ),
          );
        },
      ),
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

class _OfferSection extends StatelessWidget {
  const _OfferSection({
    required this.offer,
    required this.signedIn,
    required this.brands,
  });

  final CardOffer offer;
  final bool signedIn;
  final List<CardBrand> brands;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    CardsScope.of(context).offers.seen(offer, 'offers');
    final esim = offer.scope.covers(category: 'esim');
    final everything = offer.scope.isEverything;
    return Padding(
      padding: const EdgeInsets.only(bottom: CardsSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
            child: OfferCard(offer: offer, signedIn: signedIn, showUses: true),
          ),
          if (everything)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.sm,
                CardsSpace.gutter,
                0,
              ),
              child: Text(
                l10n.offerCoversAll,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (brands.isNotEmpty) ...[
            const SizedBox(height: CardsSpace.md),
            BrandShelf(brands: brands),
          ],
          if (esim)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.sm,
                CardsSpace.gutter,
                0,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => EsimStorePage.open(context),
                  icon: const Icon(Icons.public_rounded),
                  label: Text(l10n.offerShopEsim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SignInNote extends StatelessWidget {
  const _SignInNote({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: CardsSpace.lg),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.offersSignInBody,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          FilledButton(onPressed: onSignIn, child: Text(l10n.signInAction)),
        ],
      ),
    );
  }
}
