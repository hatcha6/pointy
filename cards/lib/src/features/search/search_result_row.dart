import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../brand/brand_page.dart';
import '../shelf/shelf_model.dart';
import '../../shared/name_text.dart';

/// One brand found by a search: its art, its name and category, and the
/// price it starts from. Tapping it opens the brand.
class SearchResultRow extends StatelessWidget {
  const SearchResultRow({super.key, required this.brand, required this.shelf});

  final CardBrand brand;
  final ShelfModel shelf;

  @override
  Widget build(BuildContext context) {
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
        child: LayoutBuilder(
          builder: (context, constraints) => _row(
            context,
            from,
            category,
            tag,
            // The narrowest phones: the price goes under the name, or the
            // name and its badges would have a column too thin to hold them.
            priceBelow: constraints.maxWidth < 300,
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    Money? from,
    String category,
    String tag, {
    required bool priceBelow,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final price = from == null
        ? null
        : Text(
            l10n.fromPrice(formatMoney(l10n, from)),
            style: PointyTypography.numeric(theme.textTheme.labelLarge!),
          );
    return Row(
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
              NameText(
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
              if (priceBelow && price != null) ...[
                const SizedBox(height: 2),
                price,
              ],
              if (brand.webOnly || brand.gamePlatform != null) ...[
                const SizedBox(height: CardsSpace.xs),
                Wrap(
                  spacing: CardsSpace.xs,
                  runSpacing: CardsSpace.xs,
                  children: [
                    if (brand.webOnly) const WebOnlyPill(onArt: false),
                    if (brand.gamePlatform case final platform?)
                      PlatformPill(platform, onArt: false),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (!priceBelow && price != null) price,
      ],
    );
  }
}
