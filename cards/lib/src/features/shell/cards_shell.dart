import 'package:flutter/material.dart';

import '../../shared/cards_scope.dart';
import '../account/account_page.dart';
import '../home/home_page.dart';
import '../home/home_reset.dart';
import '../my_cards/my_cards_page.dart';
import '../shelf/shelf_model.dart';
import 'cards_tab_bar.dart';

/// The app's three places: the shelf, the customer's cards, their account.
/// Each tab keeps its state when the customer moves between them.
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
  final _homeReset = HomeReset();

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
    }
  }

  @override
  void dispose() {
    final shelf = _shelf;
    if (shelf != null) {
      _session?.removeListener(shelf.refreshCustomer);
      _orders?.removeListener(shelf.refreshCustomer);
      shelf.dispose();
    }
    _homeReset.dispose();
    super.dispose();
  }

  void _go(int tab) => setState(() => _tab = tab);

  /// The tab bar. Home always starts the shelf over (search cleared, all
  /// categories, the top), visibly when it was already showing.
  void _select(int tab) {
    if (tab == 0) {
      _homeReset.reset(animate: _tab == 0);
    }
    _go(tab);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Content scrolls under the tab bar, glass or frosted.
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: [
          HomePage(shelf: _shelf!, reset: _homeReset),
          // Rebuilt on each visit so a card bought a minute ago is there.
          _tab == 1
              ? MyCardsPage(key: UniqueKey(), onBrowse: () => _go(0))
              : const SizedBox.shrink(),
          const AccountPage(),
        ],
      ),
      bottomNavigationBar: CardsTabBar(current: _tab, onSelect: _select),
    );
  }
}
