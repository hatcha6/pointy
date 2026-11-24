import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/offer.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/pressable.dart';
import '../shelf/shelf_model.dart';
import 'offer_text.dart';
import 'offers_page.dart';

/// The way into the offers page from the shelf: how many there are, and
/// when the soonest ends. Nothing when there are none.
class OffersEntry extends StatelessWidget {
  const OffersEntry({super.key, required this.shelf});

  final ShelfModel shelf;

  @override
  Widget build(BuildContext context) {
    final offers = CardsScope.of(context).offers..ensureLoaded();
    return ListenableBuilder(
      listenable: offers,
      builder: (context, _) {
        final list = offers.offers;
        if (list.isEmpty) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        const red = Color(0xFFD92D20);
        final mine = offers.signedIn && list.any((o) => !o.forEveryone);
        final ends = _soonestEnd(l10n, list);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.md,
            CardsSpace.gutter,
            0,
          ),
          child: Pressable(
            semanticLabel: l10n.offersTitle,
            onTap: () => OffersPage.open(context, shelf),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.md,
                vertical: CardsSpace.sm + 2,
              ),
              decoration: BoxDecoration(
                color: red.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(CardsRadii.tile),
                border: Border.all(color: red.withValues(alpha: 0.22)),
              ),
              child: Row(
                children: [
                  Icon(
                    mine
                        ? Icons.card_giftcard_rounded
                        : Icons.local_offer_rounded,
                    color: red,
                    size: 22,
                  ),
                  const SizedBox(width: CardsSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offers.signedIn
                              ? l10n.offersEntryMine(list.length)
                              : l10n.offersEntryPublic(list.length),
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          ends ?? l10n.offersEntryHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: red),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// When the offer ending first ends, in words, if that is soon.
  static String? _soonestEnd(AppLocalizations l10n, List<CardOffer> offers) {
    final now = DateTime.now();
    final ending = [
      for (final offer in offers)
        if (offer.endsAt != null) offer,
    ]..sort((a, b) => a.endsAt!.compareTo(b.endsAt!));
    return ending.isEmpty ? null : offerEndsText(l10n, ending.first, now);
  }
}
