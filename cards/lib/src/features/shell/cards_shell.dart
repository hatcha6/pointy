import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/result.dart';
import '../../shared/cards_scope.dart';
import '../../shared/side_back.dart';
import '../account/account_page.dart';
import '../brand/brand_page.dart';
import '../home/home_page.dart';
import '../home/home_reset.dart';
import '../legal/about_page.dart';
import '../legal/legal_document.dart';
import '../legal/legal_page.dart';
import '../esim/esim_destination_page.dart';
import '../esim/esim_store_page.dart';
import '../esim/esim_page.dart';
import '../links/cards_link.dart';
import '../sign_in/sign_in_sheet.dart';
import '../links/link_inbox.dart';
import '../my_cards/my_cards_page.dart';
import '../search/search_page.dart';
import '../shelf/shelf_model.dart';
import 'cards_sidebar.dart';
import 'cards_tab_bar.dart';
import '../../shared/web_edges.dart';

/// The app's three places: the shelf, the customer's cards, their account.
/// Each tab keeps its state when the customer moves between them. Links
/// (`cards.dftr.ly/…`) open here: the shell knows the tabs and the shelf.
class CardsShell extends StatefulWidget {
  const CardsShell({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<CardsShell> createState() => _CardsShellState();
}

class _CardsShellState extends State<CardsShell> {
  late int _tab = widget.initialTab;
  ShelfModel? _shelf;
  ValueNotifier<Object?>? _session;
  ValueNotifier<int>? _orders;
  LinkInbox? _links;
  final _homeReset = HomeReset();

  /// What the web build's address bar last showed for the shell.
  String? _shownLocation;

  VoidCallback? _preloadArt;

  /// Reads the eSIM shelf again: who is signed in decides whether there is one.
  VoidCallback? _reloadEsim;

  /// Counts the visits to «كروتي», whose page starts over on each one. Only a
  /// visit: the shell also rebuilds when the keyboard opens or a link lands,
  /// and a fresh page each time lost the filter and the scroll, and on the web
  /// never got past its placeholders.
  late int _myCardsVisit = widget.initialTab == CardsTab.myCards.index ? 1 : 0;

  /// Whether the shelf has been on screen: the link the app starts on lands
  /// at once, under the shelf's own first appearance, not as a transition.
  bool _shown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shelf == null) {
      final dependencies = CardsScope.of(context);
      _shelf = ShelfModel(
        catalog: dependencies.catalog,
        orders: dependencies.orders,
        auth: dependencies.auth,
      )..load();
      // Signing in or out changes the credit and what can be bought again.
      _session = dependencies.auth.session
        ..addListener(_shelf!.refreshCustomer);
      // A purchase changes them too.
      _orders = dependencies.orders.changes
        ..addListener(_shelf!.refreshCustomer);
      final art = dependencies.art;
      if (art != null) {
        _preloadArt = () => art.preload(_shelf!.shelf);
        _shelf!.addListener(_preloadArt!);
      }
      // Read now: the home search finds eSIMs as well as cards. And again on
      // signing in or out, which can open or close the shelf.
      unawaited(dependencies.esim.loadShelf());
      _reloadEsim = () => unawaited(dependencies.esim.loadShelf());
      _session!.addListener(_reloadEsim!);
      // A link waits for the catalog when it names a brand or a category.
      _shelf!.addListener(_openLink);
      _links = dependencies.links..addListener(_openLink);
      if (kIsWeb) {
        _shelf!.addListener(_showLocation);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _screen(_tab);
        _openLink();
        _shown = true;
      });
    }
  }

  @override
  void dispose() {
    final shelf = _shelf;
    if (shelf != null) {
      _session?.removeListener(shelf.refreshCustomer);
      if (_reloadEsim case final reload?) {
        _session?.removeListener(reload);
      }
      _orders?.removeListener(shelf.refreshCustomer);
      _links?.removeListener(_openLink);
      if (_preloadArt case final preload?) {
        shelf.removeListener(preload);
      }
      shelf.dispose();
    }
    _homeReset.dispose();
    super.dispose();
  }

  void _go(int tab) {
    if (tab != _tab) {
      _screen(tab);
      if (tab == CardsTab.myCards.index) {
        _myCardsVisit++;
      }
    }
    setState(() => _tab = tab);
    _showLocation();
  }

  /// The tabs are not routes, so the navigator cannot name them.
  void _screen(int tab) =>
      CardsScope.of(context).analytics.screen(switch (CardsTab.values[tab]) {
        CardsTab.shelf => 'shelf',
        CardsTab.myCards => 'my_cards',
        CardsTab.account => 'account',
      });

  /// Opens the waiting link, once the shelf has the catalog it may name.
  void _openLink() {
    final links = _links;
    final shelf = _shelf;
    if (!mounted || links == null || shelf == null) {
      return;
    }
    final link = links.pending;
    if (link == null) {
      return;
    }
    final needsCatalog =
        link is BrandLink || (link is ShelfLink && link.category != null);
    if (needsCatalog && shelf.loading) {
      return;
    }
    links.take();
    if (link is OrderLink && CardsScope.of(context).push.showing(link.order)) {
      // The order is already on screen, and its page brings the news itself.
      return;
    }
    // Whatever is open closes first, so links never pile pages up. A step
    // that must not be left (a card being charged) keeps the link out.
    final navigator = Navigator.of(context);
    var blocked = false;
    navigator.popUntil((route) {
      if (route.isFirst) {
        return true;
      }
      blocked = route.popDisposition == RoutePopDisposition.doNotPop;
      return blocked;
    });
    if (blocked) {
      return;
    }
    switch (link) {
      case ShelfLink():
        final known =
            link.category == null ||
            shelf.shelf.categories.any((c) => c.key == link.category);
        final target = known ? link : const ShelfLink();
        if (_shown && _tab == 0) {
          // On screen: the shelf moves there visibly.
          _homeReset.reset(animate: true, to: target);
        } else {
          // Arriving: the shelf is simply already there.
          shelf
            ..search(target.query ?? '')
            ..filter(target.category);
        }
        _go(0);
      case BrandLink():
        final brand = shelf.shelf.brand(link.brand);
        if (brand == null) {
          // A brand no longer sold: the shelf, as it is.
          _go(0);
          return;
        }
        final item = brand.items.where((i) => i.key == link.item).firstOrNull;
        _go(0);
        BrandPage.open(context, brand, item: item);
      case TabLink(:final tab):
        _go(tab.index);
      case OrderLink(:final order):
        _go(CardsTab.myCards.index);
        unawaited(_openOrder(order));
      case EsimShelfLink(:final destination):
        _go(CardsTab.shelf.index);
        if (destination == null) {
          EsimStorePage.open(context);
        } else {
          EsimDestinationPage.open(context, destination);
        }
      case EsimLink(:final iccid):
        _go(CardsTab.myCards.index);
        unawaited(_openEsim(iccid));
      case PageLink(:final page):
        _go(CardsTab.account.index);
        switch (page) {
          case LinkedPage.privacy:
            LegalPage.open(context, LegalDocument.privacy);
          case LinkedPage.terms:
            LegalPage.open(context, LegalDocument.terms);
          case LinkedPage.about:
            AboutPage.open(context);
        }
    }
  }

  /// Opens one eSIM over «كروتي». It needs a session: a phone signed out since
  /// the alert was sent is asked to sign in first.
  Future<void> _openEsim(String iccid) async {
    if (!await ensureSignedIn(context) || !mounted) {
      return;
    }
    await EsimPage.open(context, iccid);
  }

  /// Opens one order over «كروتي», as reading it now finds it. One that
  /// cannot be read leaves «كروتي» on screen, the order in its list.
  Future<void> _openOrder(String id) async {
    final result = await CardsScope.of(context).orders.order(id);
    if (!mounted) {
      return;
    }
    if (result case Ok(:final value)) {
      await openCardOrder(context, value);
    }
  }

  /// The web build's address bar follows the tab and the shelf's filter, so
  /// the address can be copied and shared. Pages on top name themselves.
  void _showLocation() {
    final shelf = _shelf;
    if (!kIsWeb || !mounted || shelf == null) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final CardsLink link = _tab == 0
        ? ShelfLink(
            category: shelf.category,
            query: shelf.searching ? shelf.query.trim() : null,
          )
        : TabLink(CardsTab.values[_tab]);
    if (link.location == _shownLocation) {
      return;
    }
    _shownLocation = link.location;
    SystemNavigator.routeInformationUpdated(
      uri: Uri.parse(link.location),
      replace: true,
    );
  }

  /// The tab bar. Home always starts the shelf over (search cleared, all
  /// categories, the top), visibly when it was already showing.
  void _select(int tab) {
    if (tab == 0) {
      _homeReset.reset(animate: _tab == 0);
    }
    _go(tab);
  }

  /// The search page, from the tab bar's search button. A category picked
  /// there is shown at once, under the page, which then slides away onto it.
  void _openSearch() => SearchPage.open(
    context,
    shelf: _shelf!,
    onCategory: (key) {
      _homeReset.reset(animate: false, to: ShelfLink(category: key));
      _go(CardsTab.shelf.index);
    },
  );

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final side = CardsTabBar.side(padding);
    final pages = IndexedStack(
      index: _tab,
      children: [
        HomePage(shelf: _shelf!, reset: _homeReset),
        // Rebuilt on each visit so a card bought a minute ago is there.
        _tab == 1
            ? MyCardsPage(key: ValueKey(_myCardsVisit), onBrowse: () => _go(0))
            : const SizedBox.shrink(),
        const AccountPage(),
      ],
    );
    if (sidebarFits(context)) {
      final media = MediaQuery.of(context);
      return Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: CardsSidebar.width,
              child: CardsSidebar(
                current: _tab,
                onSelect: _select,
                shelf: _shelf!,
                onCategory: (key) {
                  _homeReset.reset(
                    animate: _tab == CardsTab.shelf.index,
                    to: ShelfLink(category: key),
                  );
                  _go(CardsTab.shelf.index);
                },
              ),
            ),
            // The pages measure the room the sidebar leaves them, so their
            // rows and columns fit it.
            Expanded(
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(
                    media.size.width - CardsSidebar.width,
                    media.size.height,
                  ),
                ),
                child: CardsSidebarScope(child: pages),
              ),
            ),
          ],
        ),
      );
    }
    if (side != null) {
      // At the foot of the system's side column, on the status items' own
      // centre line, as far from the bottom as Apple's own tab bars there.
      const inset = SideBack.statusCentre - CardsSideTabBar.width / 2;
      return Scaffold(
        body: Stack(
          children: [
            pages,
            Positioned(
              left: side == AxisDirection.left ? inset : null,
              right: side == AxisDirection.right ? inset : null,
              width: CardsSideTabBar.width,
              bottom: CardsSideTabBar.bottom,
              child: CardsSideTabBar(
                current: _tab,
                onSelect: _select,
                onSearch: _openSearch,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      // Content scrolls under the tab bar, glass or frosted.
      extendBody: true,
      body: pages,
      // On the web, Safari's strip under its toolbar takes the bar's colour.
      bottomNavigationBar: WebBottomEdge(
        color: _tabBarColour(Theme.of(context)),
        child: CardsTabBar(
          current: _tab,
          onSelect: _select,
          onSearch: _openSearch,
        ),
      ),
    );
  }

  /// The tab bar as it shows: its translucent surface over the page.
  static Color _tabBarColour(ThemeData theme) => Color.alphaBlend(
    theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface,
    theme.scaffoldBackgroundColor,
  );
}
