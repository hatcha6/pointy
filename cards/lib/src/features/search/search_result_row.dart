import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../brand/brand_page.dart';
import '../shelf/shelf_model.dart';

/// One brand found by a search: its art, its name and category, and the
/// price it starts from. Tapping it opens the brand.
class SearchResultRow extends StatelessWidget {
  const SearchResultRow({super.key, required this.brand, required this.shelf});

  final CardBrand brand;
  final ShelfModel shelf;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final from = brand.fromPrice;
    final category =
        shelf.shelf.categories
            .where((c) => c.key == brand.category)
            .firstOrNull
            ?.name ??
        '';
    final tag = 'brand-${brand.key}-search';
    return Pressable(
      semanticLabel: brand.name,
      onTap: () => BrandPage.open(context, brand, heroTag: tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.gutter,
          vertical: CardsSpace.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Hero(
                createRectTween: cardRectTween,
                transitionOnUserGestures: true,
                tag: tag,
                child: CardArt(
                  brand: brand,
                  radius: 10,
                  shadow: false,
                  muted: !brand.anyAvailable,
                ),
              ),
            ),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    brand.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (category.isNotEmpty)
                    Text(
                      category,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (brand.webOnly) ...[
                    const SizedBox(height: CardsSpace.xs),
                    const WebOnlyPill(onArt: false),
                  ],
                ],
              ),
            ),
            if (from != null)
              Text(
                l10n.fromPrice(formatMoney(l10n, from)),
                style: PointyTypography.numeric(theme.textTheme.labelLarge!),
              ),
          ],
        ),
      ),
    );
  }
}
