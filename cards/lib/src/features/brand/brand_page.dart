import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_cache.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/quantity_stepper.dart';
import '../checkout/checkout_sheet.dart';
import '../sign_in/sign_in_sheet.dart';
import '../../shared/haptics.dart';

/// One brand, presented the way a premium storefront presents a product: its
/// art filling the top of the page, what it comes in, and a frosted buy bar
/// that stays under the thumb.
class BrandPage extends StatefulWidget {
  BrandPage({super.key, required this.brand, this.initialItem, String? heroTag})
    : heroTag = heroTag ?? 'brand-${brand.key}';

  final CardBrand brand;
  final CardItem? initialItem;

  /// The tile it opened from: the art flies from there.
  final String heroTag;

  static Future<void> open(
    BuildContext context,
    CardBrand brand, {
    CardItem? item,
    String? heroTag,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          BrandPage(brand: brand, initialItem: item, heroTag: heroTag),
    ),
  );

  @override
  State<BrandPage> createState() => _BrandPageState();
}

class _BrandPageState extends State<BrandPage> {
  late String? _country = widget.initialItem?.country ?? _countries.firstOrNull;
  late CardItem? _item = widget.initialItem ?? _defaultItem();
  int _quantity = 1;

  List<String> get _countries {
    final seen = <String>{};
    return [
      for (final item in widget.brand.items)
        if (item.country.isNotEmpty && seen.add(item.country)) item.country,
    ];
  }

  List<CardItem> get _items {
    return widget.brand.items
        .where((item) => _countries.length < 2 || item.country == _country)
        .toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
  }

  CardItem? _defaultItem() =>
      _items.where((item) => item.available).firstOrNull;

  Future<void> _buy() async {
    final item = _item;
    if (item == null || !item.available) {
      return;
    }
    Haptics.tap();
    if (!await ensureSignedIn(context) || !mounted) {
      return;
    }
    await showCheckout(
      context,
      brand: widget.brand,
      item: item,
      quantity: _quantity,
      heroTag: widget.heroTag,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = widget.brand;
    final countries = _countries;
    final item = _item;
    final top = MediaQuery.paddingOf(context).top;
    // The art fills the header edge to edge, under the status bar too: a
    // 16:10 tile at phone width, kept within reason on a tablet.
    final heroHeight = (MediaQuery.sizeOf(context).width / kCardAspect + top)
        .clamp(300.0, 440.0);
    final cheapest = brand.items
        .where((i) => i.available)
        .map((i) => i.price)
        .fold<Money?>(
          null,
          (min, p) => min == null || p.compareTo(min) < 0 ? p : min,
        );
    return Scaffold(
      extendBody: true,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            stretch: true,
            expandedHeight: heroHeight,
            backgroundColor: theme.scaffoldBackgroundColor,
            leading: const _CircleBack(),
            stretchTriggerOffset: 120,
            flexibleSpace: LayoutBuilder(
              builder: (context, constraints) {
                final collapsedHeight = top + kToolbarHeight;
                final t =
                    ((heroHeight - constraints.maxHeight) /
                            (heroHeight - collapsedHeight))
                        .clamp(0.0, 1.0);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    FlexibleSpaceBar(
                      collapseMode: CollapseMode.parallax,
                      stretchModes: const [StretchMode.zoomBackground],
                      background: _ImmersiveArt(
                        brand: brand,
                        heroTag: widget.heroTag,
                      ),
                    ),
                    Positioned(
                      top: top,
                      left: 64,
                      right: 64,
                      height: kToolbarHeight,
                      child: Opacity(
                        opacity: ((t - 0.6) / 0.4).clamp(0.0, 1.0),
                        child: Center(
                          child: Text(
                            brand.name,
                            style: theme.appBarTheme.titleTextStyle,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              CardsSpace.gutter,
              CardsSpace.sm,
              CardsSpace.gutter,
              140,
            ),
            sliver: SliverList.list(
              children: [
                Text(brand.name, style: theme.textTheme.headlineMedium),
                const SizedBox(height: CardsSpace.xs),
                Wrap(
                  spacing: CardsSpace.sm,
                  runSpacing: CardsSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (cheapest != null)
                      Text(
                        '${l10n.startingFrom} ${formatMoney(l10n, cheapest)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (brand.badge.isNotEmpty)
                      Pill(text: brand.badge, tone: PillTone.promo),
                  ],
                ),
                const SizedBox(height: CardsSpace.xl),
                const Divider(),
                if (countries.length > 1) ...[
                  const SizedBox(height: CardsSpace.xl),
                  Text(l10n.chooseCountry, style: theme.textTheme.titleLarge),
                  const SizedBox(height: CardsSpace.md),
                  Wrap(
                    spacing: CardsSpace.sm,
                    runSpacing: CardsSpace.sm,
                    children: [
                      for (final code in countries)
                        _CountryChip(
                          code: code,
                          selected: _country == code,
                          onTap: () => setState(() {
                            _country = code;
                            _item = _defaultItem();
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: CardsSpace.xl),
                Text(l10n.chooseValue, style: theme.textTheme.titleLarge),
                const SizedBox(height: CardsSpace.md),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth < 360
                        ? 2
                        : (constraints.maxWidth < 600 ? 3 : 4);
                    const gap = CardsSpace.sm;
                    final tileWidth =
                        (constraints.maxWidth - gap * (columns - 1)) / columns;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final option in _items)
                          SizedBox(
                            width: tileWidth,
                            child: _ValueTile(
                              item: option,
                              selected: option.key == item?.key,
                              onTap: option.available
                                  ? () => setState(() => _item = option)
                                  : null,
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (brand.redeemHint.isNotEmpty) ...[
                  const SizedBox(height: CardsSpace.xl),
                  _RedeemCard(hint: brand.redeemHint),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: item == null
          ? null
          : _BuyBar(
              total: item.price * _quantity,
              quantity: _quantity,
              enabled: item.available,
              onQuantity: (value) => setState(() => _quantity = value),
              onBuy: _buy,
            ),
    );
  }
}

/// The brand's art edge to edge, melting into the page at its foot. A light
/// shade at the top keeps the status bar and the back button readable on any
/// art.
///
/// The shade travels with the art: the flight from a shelf tile turns the
/// tile into this header as it goes (corners straighten, the foot melts in),
/// so it lands already looking like the header instead of a hard-edged image
/// over the page that snaps into place.
class _ImmersiveArt extends StatelessWidget {
  const _ImmersiveArt({required this.brand, required this.heroTag});

  final CardBrand brand;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: heroTag,
      flightShuttleBuilder: (_, animation, _, fromContext, toContext) {
        // The tile's own corners, whichever end of the flight it is on.
        final tile = [
          fromContext,
          toContext,
        ].map((c) => (c.widget as Hero).child).whereType<CardArt>().firstOrNull;
        final radius = tile?.radius ?? CardsRadii.art;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) => _HeaderArt(
            brand: brand,
            // Ease so the shade arrives with the art, not after it.
            progress: Curves.easeOut.transform(animation.value),
            tileRadius: radius,
          ),
        );
      },
      child: _HeaderArt(brand: brand, progress: 1, tileRadius: 0),
    );
  }
}

/// The art and its shade, [progress] of the way from a shelf tile (rounded,
/// unshaded) to the page header (square, melting into the page).
class _HeaderArt extends StatelessWidget {
  const _HeaderArt({
    required this.brand,
    required this.progress,
    required this.tileRadius,
  });

  final CardBrand brand;
  final double progress;
  final double tileRadius;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(tileRadius * (1 - progress)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CardArtImage(brand: brand),
          Opacity(
            opacity: progress.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.22, 0.62, 1],
                  colors: [
                    Colors.black.withValues(alpha: 0.28),
                    Colors.transparent,
                    page.withValues(alpha: 0),
                    page,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Airbnb's floating back button: a white circle that reads on any art.
class _CircleBack extends StatelessWidget {
  const _CircleBack();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(CardsSpace.sm),
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 0,
        child: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const BackButtonIcon(),
        ),
      ),
    );
  }
}

class _CountryChip extends StatelessWidget {
  const _CountryChip({
    required this.code,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = CardsScope.of(context).catalog;
    final flag = catalog.countryFlag(code);
    return Pressable(
      onTap: onTap,
      semanticLabel: catalog.countryName(code),
      child: AnimatedContainer(
        duration: CardsMotion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.onSurface
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.pill),
          border: Border.all(
            color: selected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: flag.isEmpty
                  ? Icon(
                      Icons.public_rounded,
                      size: 18,
                      color: selected ? theme.colorScheme.surface : null,
                    )
                  : CachedNetworkImage(
                      imageUrl: catalog.imageUrl(flag).toString(),
                      cacheManager: artCache,
                      width: 22,
                      height: 16,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const Icon(Icons.public_rounded, size: 18),
                    ),
            ),
            const SizedBox(width: CardsSpace.sm),
            Text(
              catalog.countryName(code),
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? theme.colorScheme.surface
                    : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final CardItem item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unavailable = onTap == null;
    final label = item.label.isNotEmpty
        ? item.label
        : '${item.faceValue} ${item.faceCurrency}';
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: CardsMotion.fast,
          curve: CardsMotion.curve,
          padding: const EdgeInsets.symmetric(
            horizontal: CardsSpace.sm,
            vertical: CardsSpace.lg,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.outline,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected ? CardsShadows.raised : null,
          ),
          child: Opacity(
            opacity: unavailable ? 0.4 : 1,
            child: Column(
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  unavailable
                      ? l10n.unavailableNow
                      : formatMoney(l10n, item.price),
                  textAlign: TextAlign.center,
                  style: PointyTypography.numeric(theme.textTheme.bodyMedium!)
                      .copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (item.onPromo && !unavailable)
                  Text(
                    formatMoney(l10n, item.regularPrice),
                    style: theme.textTheme.labelSmall?.copyWith(
                      decoration: TextDecoration.lineThrough,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RedeemCard extends StatelessWidget {
  const _RedeemCard({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.tips_and_updates_rounded,
              color: PointyColors.accentAmber,
              size: 22,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.howToRedeem,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  hint,
                  style: theme.textTheme.bodyMedium?.copyWith(
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

/// The frosted bar: the total on one side, the quantity and the button on the
/// other — the way a booking bar is laid out.
class _BuyBar extends StatelessWidget {
  const _BuyBar({
    required this.total,
    required this.quantity,
    required this.enabled,
    required this.onQuantity,
    required this.onBuy,
  });

  final Money total;
  final int quantity;
  final bool enabled;
  final ValueChanged<int> onQuantity;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.86),
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline, width: 0.8),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.gutter,
                CardsSpace.md,
                CardsSpace.gutter,
                CardsSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            formatMoney(l10n, total),
                            style: PointyTypography.numeric(
                              theme.textTheme.titleLarge!,
                            ),
                          ),
                        ),
                        Text(
                          l10n.cardCount(quantity),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  QuantityStepper(value: quantity, onChanged: onQuantity),
                  const SizedBox(width: CardsSpace.sm),
                  SizedBox(
                    width: 112,
                    child: FilledButton(
                      onPressed: enabled ? onBuy : null,
                      child: Text(l10n.buyNow),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
