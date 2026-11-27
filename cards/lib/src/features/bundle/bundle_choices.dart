import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/bundle.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';

/// The networks a bundle's credit can be for, each as its own card: the
/// buyer taps the card of the line in their phone.
class BundleNetworkPicker extends StatelessWidget {
  const BundleNetworkPicker({
    super.key,
    required this.brands,
    required this.selected,
    required this.onSelected,
  });

  final List<CardBrand> brands;
  final String selected;
  final ValueChanged<CardBrand> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (index, brand) in brands.indexed) ...[
          if (index > 0) const SizedBox(width: CardsSpace.sm),
          Expanded(
            child: _Choice(
              selected: brand.key == selected,
              onTap: () => onSelected(brand),
              semanticLabel: brand.name,
              child: Column(
                children: [
                  CardArt(brand: brand, radius: CardsRadii.art, shadow: false),
                  const SizedBox(height: CardsSpace.xs),
                  NameText(
                    brand.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A bundle's sizes, one row each: what is in it, its price, the price of
/// its cards bought apart struck through, and what it saves.
class BundleTierPicker extends StatelessWidget {
  const BundleTierPicker({
    super.key,
    required this.tiers,
    required this.pick,
    required this.offered,
    required this.selected,
    required this.onSelected,
  });

  final List<ShelfTier> tiers;
  final List<String> pick;

  /// Whether a size has a card for the network picked; one that has not is
  /// shown greyed, with nothing to tap.
  final bool Function(ShelfTier tier) offered;
  final String selected;
  final ValueChanged<ShelfTier> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final numeric = PointyTypography.numeric;
    return Column(
      children: [
        for (final (index, tier) in tiers.indexed) ...[
          if (index > 0) const SizedBox(height: CardsSpace.sm),
          _Choice(
            selected: tier.tier.key == selected,
            onTap: offered(tier) ? () => onSelected(tier) : null,
            semanticLabel: tier.label(pick),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.md,
                vertical: CardsSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tier.label(pick),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: CardsSpace.xs),
                        if (offered(tier))
                          Pill(
                            text: l10n.bundleSave(
                              formatMoney(l10n, tier.tier.saving),
                            ),
                            tone: PillTone.offer,
                          )
                        else
                          Pill(
                            text: l10n.bundleTierNotOnNetwork,
                            tone: PillTone.muted,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: CardsSpace.sm),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatMoney(l10n, tier.price(pick)),
                        style: numeric(theme.textTheme.titleMedium!),
                      ),
                      _Struck(money: tier.apart(pick)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// What the cards cost bought one by one, struck through.
class _Struck extends StatelessWidget {
  const _Struck({required this.money});

  final Money money;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Text(
      formatMoney(l10n, money),
      style: PointyTypography.numeric(theme.textTheme.bodySmall!).copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        decoration: TextDecoration.lineThrough,
      ),
    );
  }
}

/// The cards the chosen size comes to, each with its art and its price on
/// its own.
class BundleContents extends StatelessWidget {
  const BundleContents({super.key, required this.cards});

  final List<BundleCard> cards;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (index, card) in cards.indexed) ...[
          if (index > 0) const SizedBox(height: CardsSpace.md),
          Row(
            children: [
              SizedBox(
                width: 72,
                child: CardArt(brand: card.brand, radius: 8, shadow: false),
              ),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NameText(
                      card.brand.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      card.item.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                l10n.bundleApart(formatMoney(l10n, card.item.price)),
                style: PointyTypography.numeric(theme.textTheme.bodySmall!)
                    .copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A choice on the page: outlined, and in the primary colour once picked.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.selected,
    required this.onTap,
    required this.semanticLabel,
    required this.child,
  });

  final bool selected;

  /// Null greys the choice out: not to be had with what else is picked.
  final VoidCallback? onTap;
  final String semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Pressable(
        semanticLabel: semanticLabel,
        onTap: onTap,
        child: AnimatedContainer(
          duration: CardsMotion.fast,
          padding: const EdgeInsets.all(CardsSpace.xs),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.08)
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Opacity(opacity: onTap == null ? 0.45 : 1, child: child),
        ),
      ),
    );
  }
}
