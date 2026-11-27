import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../offers/offer_pill.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/account_target.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_image.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/money_text.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/quantity_stepper.dart';
import '../../shared/side_back.dart';
import '../../shared/status_tap.dart';
import '../checkout/checkout_sheet.dart';
import '../links/cards_link.dart';
import '../sign_in/sign_in_sheet.dart';
import 'brand_light.dart';
import 'brand_share.dart';
import '../../shared/haptics.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../shared/name_text.dart';
import '../../shared/shake.dart';
import '../topup/account_card.dart';
import '../topup/account_form_model.dart';
import '../topup/topup_text.dart';
import '../../shared/glass_bar.dart';
import '../../shared/glass_button.dart';
import '../shell/cards_tab_bar.dart';
import '../../shared/container_route.dart';

/// One brand, presented the way a premium storefront presents a product: its
/// card floating at the top of the page, what it comes in, and a frosted buy bar
/// that stays under the thumb.
class BrandPage extends StatefulWidget {
  const BrandPage({super.key, required this.brand, this.initialItem});

  final CardBrand brand;
  final CardItem? initialItem;

  /// Opens the brand's page: out of the card at [from] (a shelf's tile, a
  /// search result) where there is one, which the page then closes back into.
  static Future<void> open(
    BuildContext context,
    CardBrand brand, {
    CardItem? item,
    BuildContext? from,
  }) {
    // Its address (cards.dftr.ly/brand/…), shown in the web build's bar.
    final settings = RouteSettings(
      name: BrandLink(brand.key).location,
      arguments: const ScreenName('brand'),
    );
    Widget page(BuildContext _) => BrandPage(brand: brand, initialItem: item);
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
  State<BrandPage> createState() => _BrandPageState();
}

class _BrandPageState extends State<BrandPage> {
  late String? _country = widget.initialItem?.country ?? _countries.firstOrNull;
  late String? _currency =
      widget.brand.currencies.contains(widget.initialItem?.faceCurrency)
      ? widget.initialItem?.faceCurrency
      : widget.brand.currencies.firstOrNull;
  late CardItem? _item = widget.initialItem ?? _defaultItem();
  int _quantity = 1;

  /// Whether the card has scrolled under the bar, so the bar names it and
  /// turns solid.
  final _cardGone = ValueNotifier(false);
  final _scroll = ScrollController();

  /// The light's scroll beside the details: never attached, so the light
  /// stays put while the details scroll.
  final _still = ScrollController();

  /// The account a top-up is sent to, for a card that is one (and is sold
  /// in this build).
  AccountFormModel? _account;
  final _accountKey = GlobalKey();
  final _accountShake = ShakeController();

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brand = widget.brand;
    if (_account == null && brand.toAccount && !brand.webOnly) {
      final dependencies = CardsScope.of(context);
      _account = AccountFormModel(
        brand: brand,
        orders: dependencies.orders,
        accounts: dependencies.accounts,
        signedIn: () => dependencies.auth.isSignedIn,
      )..itemKey = _item?.key ?? '';
      _account!.load();
    }
  }

  @override
  void dispose() {
    _cardGone.dispose();
    _scroll.dispose();
    _still.dispose();
    _account?.dispose();
    _accountShake.dispose();
    super.dispose();
  }

  void _choose(CardItem item) {
    setState(() => _item = item);
    _account?.itemKey = item.key;
  }

  /// The account is not ready to be sent to: the page goes to it, shakes
  /// it, and puts the cursor where it needs typing.
  bool _accountReady() {
    final account = _account;
    if (account == null) {
      return true;
    }
    if (account.validate() && !account.refused) {
      return true;
    }
    Haptics.warning();
    _accountShake.shake();
    final card = _accountKey.currentContext;
    if (card != null) {
      Scrollable.ensureVisible(
        card,
        alignment: 0.2,
        duration: CardsMotion.standard,
        curve: CardsMotion.curve,
      );
    }
    (account.firstField() ?? account.focusOf(account.target.fields.first.key))
        .requestFocus();
    return false;
  }

  /// Back from checkout to change the account: the cursor goes to its ID.
  void _editAccount() {
    final account = _account;
    if (account == null || !mounted) {
      return;
    }
    final card = _accountKey.currentContext;
    if (card != null) {
      Scrollable.ensureVisible(card, alignment: 0.2);
    }
    account.firstField()?.requestFocus();
  }

  List<String> get _countries {
    final seen = <String>{};
    return [
      for (final item in widget.brand.items)
        if (item.country.isNotEmpty && seen.add(item.country)) item.country,
    ];
  }

  List<CardItem> get _items {
    final everyCountry = _countries.length < 2;
    return widget.brand.items
        .where((item) => everyCountry || item.country == _country)
        .where((item) => _currency == null || item.faceCurrency == _currency)
        .toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
  }

  CardItem? _defaultItem() =>
      _items.where((item) => item.available).firstOrNull;

  /// A purchase on its way to checkout: a second tap opens no second sheet.
  bool _buying = false;

  Future<void> _buy() async {
    final item = _item;
    if (_buying || item == null || !item.available || widget.brand.webOnly) {
      return;
    }
    if (!_accountReady()) {
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
        brand: widget.brand,
        item: item,
        quantity: _account == null ? _quantity : 1,
        account: _account,
        onEditAccount: _editAccount,
      );
    } finally {
      _buying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = widget.brand;
    final countries = _countries;
    final item = _item;
    final cardWidth = BrandCardStage.cardWidthFor(context);
    final cardHeight = cardWidth / kCardAspect;
    // The light reaches a little past the card before it has faded out.
    final lightHeight =
        MediaQuery.paddingOf(context).top +
        kToolbarHeight +
        BrandCardStage.padding.vertical +
        cardHeight +
        56;
    final cheapest = _items
        .where((i) => i.available)
        .map((i) => i.price)
        .fold<Money?>(
          null,
          (min, p) => min == null || p.compareTo(min) < 0 ? p : min,
        );
    // A Steam gift of one edition, sent to an account: nothing to choose
    // but the account, and the price is on the bar.
    final oneEdition =
        brand.toAccount && brand.items.length == 1 && _account != null;
    final valuesTitle = switch (brand.target?.kind) {
      TargetKind.steamInvite => l10n.chooseEdition,
      null => l10n.chooseValue,
      _ => l10n.chooseAmount,
    };
    final details = <Widget>[
      NameText(brand.name, style: theme.textTheme.headlineMedium),
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
          if (brand.gamePlatform case final platform?)
            PlatformPill(platform, onArt: false),
          if (brand.target case final target?)
            Pill(
              text: l10n.topUpPill(kindKey(target.kind)),
              icon: target.kind == TargetKind.steamInvite
                  ? Icons.card_giftcard_rounded
                  : Icons.bolt_rounded,
            ),
          if (brand.badge.isNotEmpty)
            Pill(text: brand.badge, tone: PillTone.promo),
        ],
      ),
      if (!brand.webOnly) OfferBanner(brand: brand),
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
                  // The account is looked up for the card now chosen, not
                  // for the one of the country just left.
                  _account?.itemKey = _item?.key ?? '';
                }),
              ),
          ],
        ),
      ],
      if (brand.currencies case final currencies
          when currencies.isNotEmpty) ...[
        const SizedBox(height: CardsSpace.xl),
        Text(l10n.chooseCurrency, style: theme.textTheme.titleLarge),
        const SizedBox(height: CardsSpace.md),
        Wrap(
          spacing: CardsSpace.sm,
          runSpacing: CardsSpace.sm,
          children: [
            for (final code in currencies)
              _ChoiceChip(
                label: l10n.currencyName(code),
                selected: _currency == code,
                onTap: () => setState(() {
                  _currency = code;
                  _item = _defaultItem();
                  _account?.itemKey = _item?.key ?? '';
                }),
                leading: (color) => Text(
                  _currencySigns[code] ?? code,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ],
      if (_account case final account?) ...[
        const SizedBox(height: CardsSpace.xl),
        _StepTitle(
          // A game with one edition has one step: the account.
          step: oneEdition ? null : 1,
          title: l10n.topUpAccountTitle(kindKey(account.target.kind)),
        ),
        const SizedBox(height: CardsSpace.xs),
        Text(
          l10n.topUpAccountBody(kindKey(account.target.kind)),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: CardsSpace.md),
        Shake(
          controller: _accountShake,
          child: AccountCard(key: _accountKey, model: account),
        ),
      ],
      if (!oneEdition) ...[
        const SizedBox(height: CardsSpace.xl),
        if (_account != null)
          _StepTitle(step: 2, title: valuesTitle)
        else
          Text(valuesTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: CardsSpace.md),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 360
                ? 2
                : (constraints.maxWidth < 600 ? 3 : 4);
            const gap = CardsSpace.sm;
            final tileWidth =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            // A game's editions have names, not values: every tile gives them
            // two lines, so the row still lines up.
            final named = _items.any((option) => option.label.length > 14);
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final option in _items)
                  SizedBox(
                    width: tileWidth,
                    child: _ValueTile(
                      brand: brand,
                      item: option,
                      named: named,
                      selected: option.key == item?.key,
                      onTap: option.available ? () => _choose(option) : null,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
      if (brand.redeemHint.isNotEmpty) ...[
        const SizedBox(height: CardsSpace.xl),
        _RedeemCard(hint: brand.redeemHint),
      ],
    ];
    final buyBar = _buyBar();
    if (CardsLayout.sideBySide(MediaQuery.sizeOf(context))) {
      return _sideBySide(context, details: details);
    }
    // A tap on the status bar scrolls the details to their top.
    return StatusTapScrolls(
      controller: _scroll,
      child: SideBack(
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
                        _cardGone.value =
                            note.metrics.pixels > cardHeight * 0.8;
                      }
                      return false;
                    },
                    child: CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        // A plain bar: the back button, and the brand's name once the
                        // card has scrolled away.
                        if (CardsTabBar.nativeGlass)
                          GlassBar.sliver(
                            context,
                            title: ValueListenableBuilder<bool>(
                              valueListenable: _cardGone,
                              builder: (context, gone, child) =>
                                  AnimatedOpacity(
                                    duration: CardsMotion.fast,
                                    opacity: gone ? 1 : 0,
                                    child: child,
                                  ),
                              child: NameText(brand.name, maxLines: 1),
                            ),
                            actions: [
                              BrandShareButton.side(context, brand, item),
                            ],
                          )
                        else
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
                              builder: (context, gone, child) =>
                                  AnimatedOpacity(
                                    duration: CardsMotion.fast,
                                    opacity: gone ? 1 : 0,
                                    child: child,
                                  ),
                              child: NameText(brand.name, maxLines: 1),
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
      ),
    );
  }

  /// The buy bar for the chosen card. A top-up's says where it goes (the
  /// player's name once the game gave it) and has no quantity: one goes to
  /// an account at a time.
  Widget? _buyBar({bool floating = false}) {
    final item = _item;
    if (item == null) {
      return null;
    }
    final account = _account;
    if (account == null) {
      return _BuyBar(
        total: item.price * _quantity,
        quantity: _quantity,
        enabled: item.available,
        webOnly: widget.brand.webOnly,
        onQuantity: (value) => setState(() => _quantity = value),
        onBuy: _buy,
        floating: floating,
      );
    }
    final l10n = AppLocalizations.of(context);
    final kind = kindKey(account.target.kind);
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => _BuyBar(
        total: item.price,
        quantity: 1,
        enabled: item.available,
        onQuantity: (_) {},
        onBuy: _buy,
        floating: floating,
        actionLabel: l10n.topUpAction(kind),
        note: account.complete
            ? l10n.buyBarTo(
                account.playerName.isNotEmpty
                    ? isolatedName(account.playerName)
                    : isolated(
                        accountShown(account.target.line(account.values)),
                      ),
              )
            : l10n.buyBarNeedsAccount(kind),
      ),
    );
  }

  /// A wide screen (a tablet, the iPhone Duo open): the card on the leading
  /// side in the brand's light, the details and the buy bar beside it, both
  /// clear of the system's side column.
  Widget _sideBySide(BuildContext context, {required List<Widget> details}) {
    final media = (size: MediaQuery.sizeOf(context));
    final padding = MediaQuery.paddingOf(context);
    final pane = (media.size.width - padding.horizontal) / 2;
    final cardWidth = math.min(
      BrandCardStage.cardWidthFor(context),
      pane - CardsSpace.gutter * 2,
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // A tap on the status bar scrolls the details to their top.
    return StatusTapScrolls(
      controller: _scroll,
      child: SideBack(
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
                              ?_buyBar(floating: true),
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
      ),
    );
  }
}

/// A numbered step of a top-up's page: first the account, then the amount.
class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.step, required this.title});

  /// Null for a page of one step, which needs no number.
  final int? step;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (step == null) {
      return Text(title, style: theme.textTheme.titleLarge);
    }
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$step',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.surface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: CardsSpace.sm),
        Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
      ],
    );
  }
}

/// Airbnb's floating back button: a white circle that reads on any art.
class _CircleBack extends StatelessWidget {
  const _CircleBack();

  @override
  Widget build(BuildContext context) {
    if (CardsTabBar.nativeGlass) {
      return Padding(
        padding: const EdgeInsets.all(CardsSpace.sm),
        child: GlassButton(
          symbol: Directionality.of(context) == TextDirection.rtl
              ? 'chevron.right'
              : 'chevron.left',
          icon: const BackButtonIcon(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: (_) => Navigator.of(context).maybePop(),
        ),
      );
    }
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
    final catalog = CardsScope.of(context).catalog;
    final flag = catalog.countryFlag(code);
    return _ChoiceChip(
      label: catalog.countryName(code),
      selected: selected,
      onTap: onTap,
      leading: (color) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: flag.isEmpty
            ? Icon(Icons.public_rounded, size: 18, color: color)
            : SizedBox(
                width: 22,
                height: 16,
                child: ArtImage(
                  url: catalog.imageUrl(flag).toString(),
                  fallback: const Icon(Icons.public_rounded, size: 18),
                ),
              ),
      ),
    );
  }
}

/// The signs the currency chips show; a currency with none shows its code.
const _currencySigns = {'USD': r'$', 'EUR': '€', 'GBP': '£'};

/// One of a few to choose among (a country, a currency): the one chosen is
/// filled.
class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// What stands before the label, in the colour the chip writes in.
  final Widget Function(Color color) leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = selected
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
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
            leading(ink),
            const SizedBox(width: CardsSpace.sm),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({
    this.named = false,
    required this.brand,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final CardBrand brand;
  final CardItem item;
  final bool selected;
  final VoidCallback? onTap;

  /// An edition's name rather than a value: two lines at full size.
  final bool named;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unavailable = onTap == null;
    final labelStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
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
                if (named)
                  SizedBox(
                    height: _twoLines(context, labelStyle),
                    child: Center(
                      child: NameText(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                  )
                else
                  // One line in every tile, so a row of values lines up; a
                  // long one shrinks a little instead of wrapping.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: labelStyle,
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
                if (!unavailable) ItemOfferPrice(brand: brand, item: item),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The height of two lines of [style], as the reader's text size sets it.
double _twoLines(BuildContext context, TextStyle? style) {
  final size = style?.fontSize ?? 14;
  return MediaQuery.textScalerOf(context).scale(size) *
      (style?.height ?? 1.4) *
      2;
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
    this.note,
    this.actionLabel,
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

  /// In place of the card count and the quantity: where a top-up goes.
  final String? note;

  /// In place of «اشترِ».
  final String? actionLabel;

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
                    AnimatedSwitcher(
                      duration: CardsMotion.fast,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [...previous, ?current],
                      ),
                      child: Text(
                        note ?? l10n.cardCount(quantity),
                        key: ValueKey(note),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (note == null) ...[
                QuantityStepper(value: quantity, onChanged: onQuantity),
                const SizedBox(width: CardsSpace.sm),
              ],
              SizedBox(
                width: 112,
                child: FilledButton(
                  onPressed: enabled ? onBuy : null,
                  child: Text(actionLabel ?? l10n.buyNow),
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
