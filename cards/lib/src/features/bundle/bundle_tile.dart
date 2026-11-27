import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/bundle.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/container_route.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import 'bundle_page.dart';

/// A bundle on the shelf, as large as a featured brand: its artwork with
/// what it saves at the start corner, its name, what it is, and what it
/// starts at.
class BundleTile extends StatelessWidget {
  const BundleTile({super.key, required this.bundle});

  final ShelfBundle bundle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Pressable(
      semanticLabel: bundle.name,
      onTap: () => BundlePage.open(context, bundle, from: context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ContainerSource(
                child: CardArt(
                  brand: bundle.asBrand(),
                  radius: CardsRadii.tile,
                ),
              ),
              PositionedDirectional(
                top: CardsSpace.sm,
                start: CardsSpace.sm,
                child: Pill(
                  text: l10n.bundleSave(formatMoney(l10n, bundle.bestSaving)),
                  tone: PillTone.offer,
                ),
              ),
            ],
          ),
          const SizedBox(height: CardsSpace.md),
          NameText(
            bundle.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            [
              if (bundle.tagline.isNotEmpty) bundle.tagline,
              l10n.fromPrice(formatMoney(l10n, bundle.fromPrice)),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PointyTypography.numeric(theme.textTheme.bodySmall!)
                .copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
