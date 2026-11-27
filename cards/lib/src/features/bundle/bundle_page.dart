import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../data/models/bundle.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_cache.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/container_route.dart';
import '../../shared/glass_bar.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/pill.dart';
import '../../shared/side_back.dart';
import '../brand/brand_light.dart';
import '../brand/buy_bar.dart';
import '../checkout/checkout_sheet.dart';
import '../sign_in/sign_in_sheet.dart';
import 'bundle_choices.dart';

/// A bundle's page, built like a brand's: its artwork floating in its own
/// light at the top, then the buyer's two choices (their network, then the
/// size), what the size comes to, and the frosted buy bar.
///
/// The company sets every amount. The buyer picks only what is theirs to
/// pick: the line in their phone, and how big a bundle.
class BundlePage extends StatefulWidget {
  const BundlePage({super.key, required this.bundle, this.initialTier});

  final ShelfBundle bundle;

  /// The size to open on (a link, «اشترِ مجدداً»); null for the default.
  final String? initialTier;

  static Future<void> open(
    BuildContext context,
    ShelfBundle bundle, {
    BuildContext? from,
    String? tier,
  }) {
    const settings = RouteSettings(arguments: ScreenName('bundle'));
    Widget page(BuildContext _) =>
        BundlePage(bundle: bundle, initialTier: tier);
    return from == null
        ? Navigator.of(context)
              .push(MaterialPageRoute<void>(settings: settings, builder: page))
        : openContainer<void>(
            context,
            from: from,
            settings: settings,
            radius: CardsRadii.art,
            builder: page,
          );
  }

  @override
  State<BundlePage> createState() => _BundlePageState();
}

class _BundlePageState extends State<BundlePage> {
  /// The widest the page's details run, on a tablet or a desktop.
  static const double _column = 600;

  late ShelfTier _tier =
      widget.bundle.tier(widget.initialTier ?? '') ?? widget.bundle.defaultTier;

  /// The brands picked, by part: the size's own first cards to begin with.
  late List<String> _pick = _tier.firstPick;
  final _scroll = ScrollController();
  final _cardGone = ValueNotifier(false);
  bool _buying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        CardsScope.of(context).analytics.brandViewed(widget.bundle.asBrand());
      }
    });
  }

  bool _warmed = false;

  /// Every network's artwork, loaded as the page opens: picking another
  /// network shows its art at once, never the drawn card in between.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_warmed) {
      return;
    }
    _warmed = true;
    final catalog = CardsScope.of(context).catalog;
    for (final art in widget.bundle.bundle.art.values.toSet()) {
      final url = catalog.imageUrl(art).toString();
      for (final image in [artImage(url, width: artTileWidth), artImage(url)]) {
        precacheImage(image, context, onError: (_, _) {});
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _cardGone.dispose();
    super.dispose();
  }

  /// A network picked: where the size shown has no card for it, the
  /// nearest size that has one is shown instead.
  void _pickBrand(int part, String brand) {
    Haptics.select();
    setState(() {
      _pick = [..._pick]..[part] = brand;
      _tier = widget.bundle.nearestOffering(_tier, _pick) ?? _tier;
    });
  }

  Future<void> _buy() async {
    if (_buying || !widget.bundle.offers(_tier, _pick)) {
      return;
    }
    Haptics.tap();
    _buying = true;
    try {
      if (!await ensureSignedIn(context) || !mounted) {
        return;
      }
      await showCheckout(
        context,
        brand: widget.bundle.asBrand(_pick),
        item: _tier.asItem(_pick),
        bundleItems: [for (final card in _tier.cards(_pick)) card.item.key],
      );
    } finally {
      _buying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bundle = widget.bundle;
    final brand = bundle.asBrand(_pick);
    final cards = _tier.cards(_pick);
    final cardWidth = BrandCardStage.cardWidthFor(context);
    final lightHeight =
        MediaQuery.paddingOf(context).top +
        kToolbarHeight +
        BrandCardStage.padding.vertical +
        cardWidth / kCardAspect +
        56;
    final side = math.max(
      CardsSpace.gutter,
      (MediaQuery.sizeOf(context).width - _column) / 2,
    );
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SideBack(
      edgeToEdge: true,
      child: Scaffold(
        extendBody: true,
        extendBodyBehindAppBar: true,
        // Clear over the card's light; solid, with the name, once the card
        // has scrolled away under it.
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: ValueListenableBuilder<bool>(
            valueListenable: _cardGone,
            builder: (context, gone, _) => GlassBar(
              title: AnimatedOpacity(
                duration: CardsMotion.fast,
                opacity: gone ? 1 : 0,
                child: NameText(bundle.name, maxLines: 1),
              ),
              clear: !gone,
            ),
          ),
        ),
        body: SettledLight(
          builder: (context, light) => Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                // A new network is new art: its light follows.
                child: KeyedSubtree(
                  key: ValueKey(brand.logo),
                  child: AmbientLight(
                    brand: brand,
                    light: light,
                    scroll: _scroll,
                    height: lightHeight,
                  ),
                ),
              ),
              // Up to the screen's top, as the brand page's: the card's light
              // scrolls away whole rather than cut at the status bar.
              NotificationListener<ScrollNotification>(
                onNotification: (note) {
                  if (note.depth == 0) {
                    _cardGone.value =
                        note.metrics.pixels > cardWidth / kCardAspect * 0.8;
                  }
                  return false;
                },
                child: ListView(
                  controller: _scroll,
                  // The card's light pool spills below its box; a repaint
                  // boundary per item would cut it off in a hard line.
                  addRepaintBoundaries: false,
                  // A readable column on a wide screen, as the page's light
                  // still spans it.
                  padding: EdgeInsets.fromLTRB(
                    side,
                    MediaQuery.paddingOf(context).top + kToolbarHeight,
                    side,
                    140,
                  ),
                  children: [
                    AnimatedSwitcher(
                      duration: CardsMotion.standard,
                      child: BrandCardStage(
                        key: ValueKey(brand.logo),
                        brand: brand,
                        width: cardWidth,
                        light: light,
                      ),
                    ),
                    NameText(bundle.name, style: theme.textTheme.headlineSmall),
                    if (bundle.tagline.isNotEmpty)
                      Text(bundle.tagline, style: muted),
                    const SizedBox(height: CardsSpace.sm),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Pill(
                        text: l10n.bundleSave(
                          formatMoney(l10n, _tier.tier.saving),
                        ),
                        tone: PillTone.offer,
                        icon: Icons.local_offer_rounded,
                      ),
                    ),
                    for (final MapEntry(key: part, value: brands)
                        in bundle.choices.entries) ...[
                      const SizedBox(height: CardsSpace.xl),
                      Text(
                        l10n.bundleNetworkTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: CardsSpace.xs),
                      Text(l10n.bundleNetworkBody, style: muted),
                      const SizedBox(height: CardsSpace.md),
                      BundleNetworkPicker(
                        brands: brands,
                        selected: _pick[part],
                        onSelected: (brand) => _pickBrand(part, brand.key),
                      ),
                    ],
                    const SizedBox(height: CardsSpace.xl),
                    Text(
                      l10n.bundleTierTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: CardsSpace.md),
                    BundleTierPicker(
                      tiers: bundle.tiers,
                      pick: _pick,
                      offered: (tier) => bundle.offers(tier, _pick),
                      selected: _tier.tier.key,
                      onSelected: (tier) {
                        Haptics.select();
                        setState(() => _tier = tier);
                      },
                    ),
                    const SizedBox(height: CardsSpace.xl),
                    Text(
                      l10n.bundleContentsTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: CardsSpace.md),
                    BundleContents(cards: cards),
                    const SizedBox(height: CardsSpace.xl),
                    _Note(icon: Icons.bolt_rounded, text: l10n.bundlePromise),
                    const SizedBox(height: CardsSpace.sm),
                    _Note(
                      icon: Icons.info_outline_rounded,
                      text: l10n.bundleNoOffers,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: BuyBar(
          total: _tier.price(_pick),
          quantity: 1,
          enabled: true,
          onQuantity: (_) {},
          onBuy: _buy,
          note: l10n.bundleCards(cards.length),
          actionLabel: l10n.bundleBuy,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: CardsSpace.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
