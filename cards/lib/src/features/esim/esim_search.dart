import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/arabic_search.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/esim_card_art.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pressable.dart';
import '../../shared/section_header.dart';
import 'esim_destination_page.dart';
import 'esim_store_page.dart';

const _shown = 6;

/// What people type when they want an eSIM rather than a place.
const _words = [
  'esim',
  'شريحة',
  'شرائح',
  'شريحه',
  'انترنت السفر',
  'سفر',
  'تجوال',
  'roaming',
  'travel',
];

/// Destinations matching what was typed: places by name, or the popular ones
/// when the words ask for eSIMs in general. Empty while eSIMs are not on sale.
List<EsimDestinationRow> esimSearch(EsimShelf shelf, String query) {
  final text = query.trim();
  if (!shelf.available || text.isEmpty) {
    return const [];
  }
  final places = shelf.destinations
      .where((d) => matchesSearch(text, [d.name, d.key, d.country]))
      .toList();
  if (places.isNotEmpty) {
    return places;
  }
  return matchesSearch(text, _words)
      ? esimPopularDestinations(shelf)
      : const [];
}

/// A search's eSIMs, under the cards it found: same rows, same rhythm.
class EsimSearchSection extends StatelessWidget {
  const EsimSearchSection({super.key, required this.rows});

  final List<EsimDestinationRow> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeader(
          title: l10n.esimSearchSection,
          onSeeAll: rows.length > _shown
              ? () => EsimStorePage.open(context)
              : null,
        ),
        for (final row in rows.take(_shown)) ...[
          _EsimSearchRow(row: row),
          const SizedBox(height: CardsSpace.xs),
        ],
      ],
    );
  }
}

class _EsimSearchRow extends StatelessWidget {
  const _EsimSearchRow({required this.row});

  final EsimDestinationRow row;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Pressable(
      semanticLabel: l10n.esimSearchRowLabel(row.name),
      onTap: () {
        Haptics.tap();
        EsimDestinationPage.open(context, row.key, name: row.name);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.gutter,
          vertical: CardsSpace.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: kCardAspect,
                  child: EsimCardArt(name: '', country: row.country),
                ),
              ),
            ),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    row.kind == EsimKind.local
                        ? l10n.esimSearchTag
                        : '${l10n.esimSearchTag} · ${l10n.esimCountriesCount(row.countries)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CardsSpace.sm),
            Text(
              l10n.fromPrice(formatMoney(l10n, row.fromPrice)),
              style: PointyTypography.numeric(theme.textTheme.labelLarge!),
            ),
          ],
        ),
      ),
    );
  }
}
