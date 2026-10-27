import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_cache.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/quantity_stepper.dart';
import '../../shared/side_back.dart';
import '../checkout/checkout_sheet.dart';
import '../links/cards_link.dart';
import '../sign_in/sign_in_sheet.dart';
import 'brand_light.dart';
import 'brand_share.dart';
import '../../shared/haptics.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';

/// One brand, presented the way a premium storefront presents a product: its
/// card floating at the top of the page, what it comes in, and a frosted buy bar
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
      // Its address (cards.dftr.ly/brand/…), shown in the web build's bar.
      settings: RouteSettings(
        name: BrandLink(brand.key).location,
        arguments: const ScreenName('brand'),
      ),
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

  /// Whether the card has scrolled under the bar, so the bar names it and
  /// turns solid.
  final _cardGone = ValueNotifier(false);
  final _scroll = ScrollController();

  /// The light's scroll beside the details: never attached, so the light
  /// stays put while the details scroll.
  final _still = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        CardsScope.of(context).analytics.brandViewed(widget.brand);
      }
    });
  }

  @override
  void dispose() {
    _cardGone.dispose();
    _scroll.dispose();
    _still.dispose();
    super.dispose();
  }

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
    if (item == null || !item.available || widget.brand.webOnly) {
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
    final media = MediaQuery.of(context);
    final cardWidth = BrandCardStage.cardWidthFor(media);
    final cardHeight = cardWidth / kCardAspect;
    // The light reaches a little past the card before it has faded out.
    final lightHeight =
        media.padding.top +
        kToolbarHeight +
        BrandCardStage.padding.vertical +
        cardHeight +
        56;
    final cheapest = brand.items
        .where((i) => i.available)
        .map((i) => i.price)
        .fold<Money?>(
          null,
          (min, p) => min == null || p.compareTo(min) < 0 ? p : min,
        );
    final details = <Widget>[
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
          if (brand.webOnly) const WebOnlyPill(onArt: false),
          if (brand.badge.isNotEmpty)
            Pill(text: brand.badge, tone: PillTone.promo),
        ],
      ),
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
    ];
    final buyBar = item == null
        ? null
        : _BuyBar(
            total: item.price * _quantity,
            quantity: _quantity,
            enabled: item.available,
            webOnly: brand.webOnly,
            onQuantity: (value) => setState(() => _quantity = value),
            onBuy: _buy,
          );
    if (CardsLayout.sideBySide(media.size)) {
      return _sideBySide(context, details: details);
    }
    return SideBack(
      edgeToEdge: true,
      actions: [BrandShareButton.side(context, brand, item)],
      child: Scaffold(
        extendBody: true,
        body: SettledLight(
          builder: (context, light) => Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AmbientLight(
                  brand: brand,
                  light: light,
                  scroll: _scroll,
                  height: lightHeight,
                ),
              ),
              // Clear of a system column down one side (the iPhone Duo); the
              // light behind still runs edge to edge.
              SafeArea(
                top: false,
                bottom: false,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (note) {
                    if (note.depth == 0) {
                      _cardGone.value = note.metrics.pixels > cardHeight * 0.8;
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      // A plain bar: the back button, and the brand's name once the
                      // card has scrolled away.
                      SliverAppBar(
                        pinned: true,
                        // Clear over the light; solid once the card has gone under.
                        backgroundColor: Colors.transparent,
                        flexibleSpace: ValueListenableBuilder<bool>(
                          valueListenable: _cardGone,
                          builder: (context, gone, _) => AnimatedOpacity(
                            duration: CardsMotion.fast,
                            opacity: gone ? 1 : 0,
                            child: ColoredBox(
                              color: theme.scaffoldBackgroundColor,
                            ),
                          ),
                        ),
                        automaticallyImplyLeading: false,
                        leading: SideBack.active(context)
                            ? null
                            : const _CircleBack(),
                        title: ValueListenableBuilder<bool>(
                          valueListenable: _cardGone,
                          builder: (context, gone, child) => AnimatedOpacity(
                            duration: CardsMotion.fast,
                            opacity: gone ? 1 : 0,
                            child: child,
                          ),
                          child: Text(brand.name, maxLines: 1),
                        ),
                        actions: [
                          // In the side column instead, where there is one.
                          if (!SideBack.active(context))
                            BrandShareButton(brand: brand, item: item),
                        ],
                      ),
                      SliverToBoxAdapter(
                        child: BrandCardStage(
                          brand: brand,
                          heroTag: widget.heroTag,
                          width: cardWidth,
                          light: light,
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          CardsSpace.gutter,
                          CardsSpace.sm,
                          CardsSpace.gutter,
                          140,
                        ),
                        sliver: SliverList.list(children: details),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: buyBar,
      ),
    );
  }

  /// A wide screen (a tablet, the iPhone Duo open): the card on the leading
  /// side in the brand's light, the details and the buy bar beside it, both
  /// clear of the system's side column.
  Widget _sideBySide(BuildContext context, {required List<Widget> details}) {
    final media = MediaQuery.of(context);
    final padding = media.padding;
    final pane = (media.size.width - padding.horizontal) / 2;
    final cardWidth = math.min(
      BrandCardStage.cardWidthFor(media),
      pane - CardsSpace.gutter * 2,
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return SideBack(
      edgeToEdge: true,
      actions: [BrandShareButton.side(context, widget.brand, _item)],
      child: Scaffold(
        body: SettledLight(
          builder: (context, light) => Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AmbientLight(
                  brand: widget.brand,
                  light: light,
                  scroll: _still,
                  height: media.size.height,
                ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  left: padding.left,
                  right: padding.right,
                ),
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeRight: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: BrandCardStage(
                            brand: widget.brand,
                            heroTag: widget.heroTag,
                            width: cardWidth,
                            light: light,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: ListView(
                                controller: _scroll,
                                padding: EdgeInsets.fromLTRB(
                                  CardsSpace.gutter,
                                  padding.top + CardsSpace.xl,
                                  CardsSpace.gutter,
                                  CardsSpace.xl,
                                ),
                                children: details,
                              ),
                            ),
                            if (_item case final item?)
                              _BuyBar(
                                total: item.price * _quantity,
                                quantity: _quantity,
                                enabled: item.available,
                                webOnly: widget.brand.webOnly,
                                onQuantity: (value) =>
                                    setState(() => _quantity = value),
                                onBuy: _buy,
                                floating: true,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!SideBack.active(context))
                PositionedDirectional(
                  top: padding.top,
                  start: rtl ? padding.right : padding.left,
                  child: const _CircleBack(),
                ),
              if (!SideBack.active(context))
                PositionedDirectional(
                  top: padding.top,
                  end: rtl ? padding.left : padding.right,
                  child: BrandShareButton(brand: widget.brand, item: _item),
                ),
            ],
          ),
        ),
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
            border: Border.all(color: theme.colorScheme.outline),
            boxShadow: selected ? CardsShadows.raised : null,
          ),
          // The selection ring is painted over the tile, not into its
          // border: a border takes room from the label, so a long value
          // would rewrap the moment it is chosen.
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.tile),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.onSurface
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Opacity(
            opacity: unavailable ? 0.4 : 1,
            child: Column(
              children: [
                // One line in every tile, so a row of values lines up; a
                // long one shrinks a little instead of wrapping.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
    this.webOnly = false,
    this.floating = false,
  });

  final Money total;
  final int quantity;
  final bool enabled;

  /// Bought on the website only: the bar says so, with no way to pay.
  final bool webOnly;
  final ValueChanged<int> onQuantity;
  final VoidCallback onBuy;

  /// A glass panel floating over the page (beside the card on a wide
  /// screen), rather than a bar across the bottom edge.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final row = webOnly
        ? const _WebOnlyNote()
        : Row(
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
          );
    final glass = theme.colorScheme.surface.withValues(alpha: 0.86);
    if (floating) {
      final radius = BorderRadius.circular(CardsRadii.sheet);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          MediaQuery.paddingOf(context).bottom + CardsSpace.lg,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: CardsShadows.hero,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: glass,
                  borderRadius: radius,
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    CardsSpace.xl,
                    CardsSpace.md,
                    CardsSpace.md,
                    CardsSpace.md,
                  ),
                  child: row,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: glass,
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
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// In place of the buy button on a card bought on the website only: where
/// to find it, and nothing to tap.
class _WebOnlyNote extends StatelessWidget {
  const _WebOnlyNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.language_rounded,
              size: 20,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.webOnlyTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.webOnlyBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
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
