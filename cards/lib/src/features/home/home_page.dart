import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_logo.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/category_icon.dart';
import '../../shared/empty_state.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/section_header.dart';
import '../../shared/skeleton.dart';
import '../brand/brand_page.dart';
import '../shelf/shelf_model.dart';
import '../../shared/haptics.dart';
import 'home_reset.dart';
import 'shelf_reveal.dart';

/// The shelf, the way the best storefronts lay one out: a large title, search
/// and the categories pinned under the thumb, the most-wanted cards as a wide
/// carousel, what the customer bought before, then one horizontal shelf per
/// category with «عرض الكل». The card art is the hero throughout.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.shelf, this.reset});

  final ShelfModel shelf;

  /// The tab bar's home button: search cleared, all categories, the top.
  final HomeReset? reset;

  static int columnsFor(double width) =>
      width < 600 ? 2 : (width < 900 ? 3 : 4);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final _search = TextEditingController(text: widget.shelf.query);
  final _scroll = ScrollController();
  late final _reveal = ShelfReveal(this);

  /// Where the search and the category bar have just pinned under the title.
  static const double _pinnedAt = 160;

  ShelfModel get shelf => widget.shelf;

  @override
  void initState() {
    super.initState();
    widget.reset?.addListener(_startOver);
    shelf.addListener(_followQuery);
  }

  /// A link can set the search: the field shows it.
  void _followQuery() {
    if (_search.text != shelf.query) {
      _search.text = shelf.query;
    }
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reset != widget.reset) {
      oldWidget.reset?.removeListener(_startOver);
      widget.reset?.addListener(_startOver);
    }
    if (oldWidget.shelf != widget.shelf) {
      oldWidget.shelf.removeListener(_followQuery);
      widget.shelf.addListener(_followQuery);
    }
  }

  @override
  void dispose() {
    widget.reset?.removeListener(_startOver);
    shelf.removeListener(_followQuery);
    _reveal.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The old category's content dips out, the page settles under the pinned
  /// bar while nothing shows, and the new category's cards rise in.
  void _pickCategory(String? key) {
    if (key == shelf.category) {
      return;
    }
    _reveal.run(context, () {
      shelf.filter(key);
      if (_scroll.hasClients && _scroll.offset > _pinnedAt) {
        _scroll.jumpTo(_pinnedAt);
      }
    });
  }

  void _startOver() {
    FocusManager.instance.primaryFocus?.unfocus();
    final target = widget.reset!.target;
    final query = target?.query ?? '';
    final category = target?.category;
    final changed = shelf.query != query || shelf.category != category;
    void clear() {
      _search.text = query;
      shelf.search(query);
      shelf.filter(category);
    }

    if (!widget.reset!.animate) {
      clear();
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
      return;
    }
    // The page glides to the top while the shelf swaps underneath.
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(
        0,
        duration: CardsMotion.emphasized,
        curve: CardsMotion.curve,
      );
    }
    if (changed) {
      _reveal.run(context, clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shelf,
      builder: (context, _) {
        final width = MediaQuery.sizeOf(context).width;
        final bottomInset = MediaQuery.paddingOf(context).bottom + 96;
        return SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: shelf.refresh,
            child: CustomScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(child: _TitleBlock(shelf: shelf)),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SearchAndCategories(
                    shelf: shelf,
                    controller: _search,
                    onCategory: _pickCategory,
                  ),
                ),
                ..._content(context, width),
                SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _content(BuildContext context, double width) {
    final l10n = AppLocalizations.of(context);
    if (shelf.loading && shelf.shelf.brands.isEmpty) {
      return [const SliverToBoxAdapter(child: _SkeletonShelves())];
    }
    final brands = shelf.brands;
    if (brands.isEmpty) {
      return [
        SliverFillRemaining(hasScrollBody: false, child: _emptyState(context)),
      ];
    }
    if (shelf.searching) {
      return [
        SliverToBoxAdapter(child: SectionHeader(title: l10n.searchResults)),
        SliverList.separated(
          itemCount: brands.length,
          separatorBuilder: (_, _) => const SizedBox(height: CardsSpace.xs),
          itemBuilder: (context, index) => ShelfRise(
            reveal: _reveal,
            order: index,
            child: _ResultRow(brand: brands[index], shelf: shelf),
          ),
        ),
      ];
    }
    if (shelf.category != null) {
      final columns = HomePage.columnsFor(width);
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.lg,
            CardsSpace.gutter,
            0,
          ),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: CardsSpace.xl,
              crossAxisSpacing: CardsSpace.md,
              childAspectRatio: 1.1,
            ),
            itemCount: brands.length,
            itemBuilder: (context, index) => ShelfRise(
              reveal: _reveal,
              order: index,
              child: _BrandTile(brand: brands[index], heroScope: 'grid'),
            ),
          ),
        ),
      ];
    }
    final featured = brands.where((b) => b.featured).toList();
    final names = {for (final c in shelf.shelf.categories) c.key: c.name};
    final categories = [...shelf.shelf.categories]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    // Each piece rises in its turn, top to bottom.
    var order = 0;
    Widget piece(Widget child) => SliverToBoxAdapter(
      child: ShelfRise(reveal: _reveal, order: order++, child: child),
    );
    return [
      if (featured.isNotEmpty) ...[
        piece(SectionHeader(title: l10n.featuredTitle)),
        piece(_FeaturedCarousel(brands: featured)),
      ],
      if (shelf.buyAgain.isNotEmpty) ...[
        piece(SectionHeader(title: l10n.buyAgainTitle)),
        piece(_BuyAgainShelf(entries: shelf.buyAgain)),
      ],
      for (final category in categories)
        if (brands.any((b) => b.category == category.key)) ...[
          piece(
            SectionHeader(
              title: names[category.key] ?? category.key,
              onSeeAll: () => _pickCategory(category.key),
            ),
          ),
          piece(
            _BrandShelf(
              brands: brands.where((b) => b.category == category.key).toList(),
              scope: category.key,
            ),
          ),
        ],
    ];
  }

  Widget _emptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (shelf.searching) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: l10n.searchNoResultsTitle(shelf.query.trim()),
        body: l10n.searchNoResultsBody,
      );
    }
    if (shelf.offline) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.catalogLoadFailedTitle,
        body: l10n.errorNetwork,
        actionLabel: l10n.retryAction,
        onAction: shelf.refresh,
      );
    }
    return EmptyState(
      icon: Icons.inventory_2_outlined,
      title: l10n.catalogEmptyTitle,
      body: l10n.catalogEmptyBody,
    );
  }
}

/// The mark and the credit on one line, then the large title.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.shelf});

  final ShelfModel shelf;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CardsSpace.gutter,
        CardsSpace.md,
        CardsSpace.gutter,
        CardsSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: CardsLogo(size: 30, withName: true),
                ),
              ),
              const SizedBox(width: CardsSpace.sm),
              if (shelf.credit.isPositive)
                Pill(
                  text: l10n.creditChip(formatMoney(l10n, shelf.credit)),
                  icon: Icons.account_balance_wallet_rounded,
                ),
            ],
          ),
          const SizedBox(height: CardsSpace.xl),
          Text(l10n.homeTitle, style: theme.textTheme.headlineLarge),
          const SizedBox(height: CardsSpace.xs),
          Text(
            l10n.homeTagline,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (shelf.offline && shelf.shelf.brands.isNotEmpty) ...[
            const SizedBox(height: CardsSpace.sm),
            Pill(
              text: l10n.savedShelfNote,
              tone: PillTone.warning,
              icon: Icons.cloud_off_rounded,
            ),
          ],
        ],
      ),
    );
  }
}

/// Search and the category bar, pinned. A hairline appears under it once
/// content scrolls beneath.
class _SearchAndCategories extends SliverPersistentHeaderDelegate {
  _SearchAndCategories({
    required this.shelf,
    required this.controller,
    required this.onCategory,
  });

  final ShelfModel shelf;
  final TextEditingController controller;
  final ValueChanged<String?> onCategory;

  static const double _searchHeight = 72;
  static const double _barHeight = 72;

  bool get _showBar => !shelf.searching && shelf.shelf.categories.length > 1;

  @override
  double get minExtent => _searchHeight + (_showBar ? _barHeight : 0);

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scrolled = overlapsContent || shrinkOffset > 0;
    return AnimatedContainer(
      duration: CardsMotion.fast,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: scrolled ? theme.colorScheme.outline : Colors.transparent,
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CardsSpace.gutter,
              CardsSpace.sm,
              CardsSpace.gutter,
              CardsSpace.sm,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(CardsRadii.pill),
                boxShadow: CardsShadows.raised,
              ),
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                onChanged: shelf.search,
                decoration: InputDecoration(
                  hintText: l10n.homeSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(CardsRadii.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(CardsRadii.pill),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(CardsRadii.pill),
                    borderSide: BorderSide(
                      color: theme.colorScheme.onSurface,
                      width: 1.4,
                    ),
                  ),
                  suffixIcon: shelf.searching
                      ? IconButton(
                          tooltip: l10n.cancelAction,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            controller.clear();
                            shelf.search('');
                          },
                        )
                      : null,
                ),
              ),
            ),
          ),
          if (_showBar)
            SizedBox(
              height: _barHeight,
              child: _CategoryBar(shelf: shelf, onCategory: onCategory),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SearchAndCategories oldDelegate) => true;
}

/// Airbnb's category bar: an icon over a label, the unchosen ones dimmed, the
/// chosen one underlined.
class _CategoryBar extends StatefulWidget {
  const _CategoryBar({required this.shelf, required this.onCategory});

  final ShelfModel shelf;
  final ValueChanged<String?> onCategory;

  @override
  State<_CategoryBar> createState() => _CategoryBarState();
}

/// Keeps the selected category in view: a pick from a shelf's «عرض الكل»
/// changes the selection without touching the bar, so the bar follows it.
class _CategoryBarState extends State<_CategoryBar> {
  final _keys = <String?, GlobalKey>{};
  late String? _shown = widget.shelf.category;

  @override
  void didUpdateWidget(_CategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = widget.shelf.category;
    if (selected == _shown) {
      return;
    }
    _shown = selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[selected]?.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: CardsMotion.standard,
          curve: CardsMotion.curve,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shelf = widget.shelf;
    final categories = [...shelf.shelf.categories]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    final entries = <(String?, String)>[
      (null, l10n.allCategories),
      for (final c in categories) (c.key, c.name),
    ];
    // A Row, not a lazy list: every category is built, so any of them can be
    // scrolled into view. A shelf has a handful.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
      child: Row(
        children: [
          for (final (index, (key, name)) in entries.indexed) ...[
            if (index > 0) const SizedBox(width: CardsSpace.xl),
            _item(theme, key, name, selected: shelf.category == key),
          ],
        ],
      ),
    );
  }

  Widget _item(
    ThemeData theme,
    String? key,
    String name, {
    required bool selected,
  }) {
    return Semantics(
      key: _keys.putIfAbsent(key, GlobalKey.new),
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.select();
          widget.onCategory(key);
        },
        child: AnimatedOpacity(
          duration: CardsMotion.fast,
          opacity: selected ? 1 : 0.6,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                categoryIcon(key),
                size: 24,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(height: CardsSpace.xs),
              Text(
                name,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: CardsMotion.standard,
                curve: CardsMotion.curve,
                height: 2,
                width: selected ? 28 : 0,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cheapest price among the brand's sellable cards (all, when none is).
Money? _fromPrice(CardBrand brand) {
  final available = brand.items.where((item) => item.available).toList();
  return (available.isEmpty ? brand.items : available)
      .map((item) => item.price)
      .fold<Money?>(
        null,
        (min, price) => min == null || price.compareTo(min) < 0 ? price : min,
      );
}

/// The badge a brand wears: unavailable, its own, or a running promotion's.
Widget? _badge(BuildContext context, CardBrand brand) {
  if (!brand.anyAvailable) {
    return Pill(
      text: AppLocalizations.of(context).unavailableNow,
      tone: PillTone.muted,
    );
  }
  final text = brand.badge.isNotEmpty
      ? brand.badge
      : brand.items.where((i) => i.onPromo).firstOrNull?.promoBadge ?? '';
  return text.isEmpty ? null : Pill(text: text, tone: PillTone.promo);
}

class _FeaturedCarousel extends StatefulWidget {
  const _FeaturedCarousel({required this.brands});

  final List<CardBrand> brands;

  @override
  State<_FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<_FeaturedCarousel> {
  PageController? _pages;
  double _fraction = 0;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // About one and a sixth cards on a phone, more on a tablet: the next one
    // peeks in to say "swipe".
    final fraction = width < 600 ? 0.84 : (width < 900 ? 0.56 : 0.42);
    if (_pages == null || fraction != _fraction) {
      _pages?.dispose();
      _pages = PageController(viewportFraction: fraction);
      _fraction = fraction;
    }
    final cardWidth = width * fraction - CardsSpace.md;
    return SizedBox(
      height: cardWidth / kCardAspect + 64,
      child: PageView.builder(
        controller: _pages,
        padEnds: false,
        itemCount: widget.brands.length,
        itemBuilder: (context, index) {
          final brand = widget.brands[index];
          return Padding(
            padding: EdgeInsetsDirectional.only(
              start: index == 0 ? CardsSpace.gutter : CardsSpace.md,
            ),
            child: _BrandTile(brand: brand, heroScope: 'featured', large: true),
          );
        },
      ),
    );
  }
}

class _BrandShelf extends StatelessWidget {
  const _BrandShelf({required this.brands, required this.scope});

  final List<CardBrand> brands;
  final String scope;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final tileWidth = width < 600 ? 164.0 : 200.0;
    return SizedBox(
      height: tileWidth / kCardAspect + 58,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
        itemCount: brands.length,
        separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
        itemBuilder: (context, index) => SizedBox(
          width: tileWidth,
          child: _BrandTile(brand: brands[index], heroScope: scope),
        ),
      ),
    );
  }
}

class _BrandTile extends StatelessWidget {
  const _BrandTile({
    required this.brand,
    required this.heroScope,
    this.large = false,
  });

  final CardBrand brand;

  /// Where the tile sits: a brand on two shelves needs two Hero tags.
  final String heroScope;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final from = _fromPrice(brand);
    final badge = _badge(context, brand);
    final tag = 'brand-${brand.key}-$heroScope';
    return Pressable(
      semanticLabel: brand.name,
      onTap: () => BrandPage.open(context, brand, heroTag: tag),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Hero(
                createRectTween: cardRectTween,
                transitionOnUserGestures: true,
                tag: tag,
                child: CardArt(
                  brand: brand,
                  muted: !brand.anyAvailable,
                  radius: large ? CardsRadii.tile : CardsRadii.art,
                ),
              ),
              if (badge != null)
                PositionedDirectional(
                  top: CardsSpace.sm,
                  start: CardsSpace.sm,
                  child: badge,
                ),
            ],
          ),
          SizedBox(height: large ? CardsSpace.md : CardsSpace.sm),
          Text(
            brand.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: large
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.titleSmall,
          ),
          if (from != null)
            Text(
              l10n.fromPrice(formatMoney(l10n, from)),
              style: PointyTypography.numeric(theme.textTheme.bodySmall!)
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.brand, required this.shelf});

  final CardBrand brand;
  final ShelfModel shelf;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final from = _fromPrice(brand);
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

class _BuyAgainShelf extends StatelessWidget {
  const _BuyAgainShelf({required this.entries});

  final List<BuyAgain> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return Pressable(
            semanticLabel: entry.brand.name,
            onTap: () => BrandPage.open(
              context,
              entry.brand,
              item: entry.item,
              heroTag: 'brand-${entry.brand.key}-again',
            ),
            child: Container(
              padding: const EdgeInsets.all(CardsSpace.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(CardsRadii.tile),
                boxShadow: CardsShadows.raised,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Hero(
                      createRectTween: cardRectTween,
                      transitionOnUserGestures: true,
                      tag: 'brand-${entry.brand.key}-again',
                      child: CardArt(
                        brand: entry.brand,
                        radius: 10,
                        shadow: false,
                      ),
                    ),
                  ),
                  const SizedBox(width: CardsSpace.md),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.item.label.isNotEmpty
                            ? entry.item.label
                            : entry.brand.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        formatMoney(l10n, entry.item.price),
                        style: PointyTypography.numeric(
                          theme.textTheme.bodySmall!,
                        ).copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(width: CardsSpace.sm),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SkeletonShelves extends StatelessWidget {
  const _SkeletonShelves();

  @override
  Widget build(BuildContext context) {
    Widget shelf(double width) => SizedBox(
      height: width / kCardAspect + 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: CardsSpace.gutter),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: CardsSpace.md),
        itemBuilder: (_, _) => SizedBox(
          width: width,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(aspectRatio: kCardAspect, radius: CardsRadii.art),
              SizedBox(height: CardsSpace.sm),
              Skeleton(width: 90, height: 14),
              SizedBox(height: CardsSpace.xs),
              Skeleton(width: 60, height: 12),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.xl,
            CardsSpace.gutter,
            CardsSpace.md,
          ),
          child: Skeleton(width: 140, height: 20),
        ),
        shelf(MediaQuery.sizeOf(context).width * 0.8),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.xl,
            CardsSpace.gutter,
            CardsSpace.md,
          ),
          child: Skeleton(width: 110, height: 20),
        ),
        shelf(164),
      ],
    );
  }
}
