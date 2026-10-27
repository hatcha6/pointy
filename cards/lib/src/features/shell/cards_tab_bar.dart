import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';
import 'cards_sidebar.dart';

/// The app's tab bar. On iOS 26 and later it is Apple's own Liquid Glass tab
/// bar, the real UIKit one hosted in the page, so it looks and moves exactly
/// as the system's apps do. Everywhere else (Android, the web, older iPhones)
/// it is our frosted bar. The page scrolls under either.
///
/// Where the screen keeps a column down one side for the system (the iPhone
/// Duo: closed, and open in landscape, the status bar runs down the right
/// edge), the tabs stand at the foot of that column instead, as the system's
/// own tab bars do there: [CardsTabBar.side] says which side.
class CardsTabBar extends StatelessWidget {
  const CardsTabBar({
    super.key,
    required this.current,
    required this.onSelect,
    this.onSearch,
  });

  final int current;
  final ValueChanged<int> onSelect;

  /// Search, on the native bar (iOS 26) as its own round glass button apart
  /// from the tabs, the way Apple's apps set it: it opens the search page.
  final VoidCallback? onSearch;

  /// The side whose system column the tabs stand in, or null for a bar
  /// along the bottom. The column shows as a wide inset on one side only:
  /// a phone on its side has a narrow one on both.
  static AxisDirection? side(EdgeInsets padding) {
    const column = 56.0;
    const none = 24.0;
    if (padding.right >= column && padding.left <= none) {
      return AxisDirection.right;
    }
    if (padding.left >= column && padding.right <= none) {
      return AxisDirection.left;
    }
    return null;
  }

  /// How far a tab's page keeps its last row from the bottom: clear of the
  /// bar along the bottom, or a plain margin when the tabs are at the side.
  static double clearance(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    // Beside a desktop's sidebar there is no bar at all.
    if (CardsSidebarScope.of(context)) {
      return padding.bottom + CardsSpace.xl;
    }
    return padding.bottom + (side(padding) == null ? 96 : CardsSpace.xl);
  }

  /// Whether this phone draws Liquid Glass: iOS 26 or later. Decided once;
  /// anything it cannot read counts as no, so an older phone never gets a
  /// native bar it cannot draw.
  static final bool nativeGlass = _iosMajorVersion() >= 26;

  static int _iosMajorVersion() {
    if (kIsWeb || !Platform.isIOS) {
      return 0;
    }
    final match = RegExp(r'Version (\d+)\.')
        .firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// The point size of the native bar's SF Symbols, matching UIKit's own.
  static const double tabSymbolSize = 17;

  void _select(int tab) {
    Haptics.select();
    onSelect(tab);
  }

  /// Each tab: its name, and its icon unselected and selected.
  static List<(String, IconData, IconData)> tabsOf(AppLocalizations l10n) => [
    (l10n.tabHome, Icons.storefront_outlined, Icons.storefront_rounded),
    (l10n.tabMyCards, Icons.style_outlined, Icons.style_rounded),
    (l10n.tabAccount, Icons.person_outline_rounded, Icons.person_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tabs = tabsOf(l10n);
    // The tabs keep their places in every language: «الرئيسية» on the far
    // right, as the app was made. English or French pages read left to
    // right, but a tab bar that swapped ends would send a returning
    // customer's thumb to the wrong tab.
    if (nativeGlass) {
      final search = onSearch;
      return SafeArea(
        top: false,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: CNTabBar(
            // Painted through page slides, as the system's own bar is: the
            // page coming in slides over it. The package's hide blinked it
            // out as a page came in and kept it out for the whole slide
            // back.
            autoHideOnPageTransition: false,
            currentIndex: current,
            onTap: (index) {
              if (index < tabs.length) {
                _select(index);
              } else {
                Haptics.tap();
                search?.call();
              }
            },
            tint: CardsTheme.link(Theme.of(context)),
            // SF Symbols, as the system's own tab bars draw them (and as the
            // side column's bar does), at the system bar's own symbol size:
            // a symbol's size is its font size, and the package's default
            // (24) crowds the labels out.
            iconSize: tabSymbolSize,
            split: search != null,
            rightCount: 1,
            items: [
              for (final (index, (label, _, _)) in tabs.indexed)
                CNTabBarItem(
                  label: label,
                  icon: CNSymbol(CardsSideTabBar._symbols[index].$1),
                  activeIcon: CNSymbol(CardsSideTabBar._symbols[index].$2),
                ),
              if (search != null)
                CNTabBarItem(
                  label: MaterialLocalizations.of(context).searchFieldLabel,
                  icon: const CNSymbol('magnifyingglass'),
                ),
            ],
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline, width: 0.8),
            ),
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: NavigationBar(
              selectedIndex: current,
              onDestinationSelected: _select,
              destinations: [
                for (final (label, icon, selected) in tabs)
                  NavigationDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selected),
                    label: label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The tabs standing in the system's side column: a glass capsule of icons,
/// top to bottom in the tab order, the chosen one on a tinted pill. Each
/// keeps its name for screen readers and a long press.
class CardsSideTabBar extends StatelessWidget {
  const CardsSideTabBar({
    super.key,
    required this.current,
    required this.onSelect,
    this.onSearch,
  });

  final int current;
  final ValueChanged<int> onSelect;

  /// Search, as its own round glass button under the tabs, the way the
  /// system sets it apart there. None when null.
  final VoidCallback? onSearch;

  /// The gap between the tabs and the search button.
  static const double searchGap = 10;

  /// The capsule's width, as Apple's side tab bars on the iPhone Duo; the
  /// column is wider than this.
  static const double width = 56;

  /// How far its foot stands from the screen's bottom edge, as Apple's do.
  static const double bottom = 30;

  /// The native glass buttons' size, Apple's own for bar buttons.
  static const double nativeWidth = 48;

  /// The native bar's height for [tabs] tabs, with search beneath or not.
  static double nativeHeight(int tabs, {required bool search}) =>
      tabs * nativeWidth + (search ? searchGap + nativeWidth : 0);

  /// The tabs' SF Symbols, plain and chosen, in the tab order. The names
  /// are the screen readers' too: [CardsTabBar.tabsOf] gives the same
  /// order.
  static const _symbols = [
    ('storefront', 'storefront.fill'),
    ('rectangle.on.rectangle.angled', 'rectangle.on.rectangle.angled.fill'),
    ('person', 'person.fill'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final tint = CardsTheme.link(theme);
    final tabs = CardsTabBar.tabsOf(AppLocalizations.of(context));
    final search = onSearch;
    if (CardsTabBar.nativeGlass) {
      // Drawn wholly by the system: the glass capsule, its sliding
      // selection pill and search beneath (ios/Runner/SideTabBarView.swift).
      return _NativeSideTabBar(
        current: current,
        onSelect: onSelect,
        onSearch: search,
        labels: [for (final (label, _, _) in tabs) label],
        tint: tint,
        dark: dark,
      );
    }
    final capsule = ClipRRect(
      borderRadius: BorderRadius.circular(CardsRadii.pill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: dark ? 0.6 : 0.72),
            borderRadius: BorderRadius.circular(CardsRadii.pill),
            border: Border.all(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: 0.08,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, (label, icon, selected)) in tabs.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
                    child: Semantics(
                      selected: index == current,
                      button: true,
                      label: label,
                      excludeSemantics: true,
                      child: Tooltip(
                        message: label,
                        preferBelow: false,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Haptics.select();
                            onSelect(index);
                          },
                          child: AnimatedContainer(
                            duration: CardsMotion.standard,
                            curve: CardsMotion.curve,
                            width: width - 12,
                            height: width - 12,
                            decoration: BoxDecoration(
                              color: index == current
                                  ? tint.withValues(alpha: 0.14)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                CardsRadii.pill,
                              ),
                            ),
                            child: Icon(
                              index == current ? selected : icon,
                              size: 24,
                              color: index == current
                                  ? tint
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (search == null) {
      return capsule;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        capsule,
        const SizedBox(height: searchGap),
        ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Material(
              color: scheme.surface.withValues(alpha: dark ? 0.6 : 0.72),
              shape: CircleBorder(
                side: BorderSide(
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha: 0.08,
                  ),
                ),
              ),
              child: SizedBox.square(
                dimension: width,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                  icon: const Icon(Icons.search_rounded),
                  color: scheme.onSurface,
                  onPressed: () {
                    Haptics.select();
                    search();
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The side tab bar as a native view: the system draws the Liquid Glass,
/// the selection and its motion; this widget only tells it what to show and
/// hears the taps.
class _NativeSideTabBar extends StatefulWidget {
  const _NativeSideTabBar({
    required this.current,
    required this.onSelect,
    required this.onSearch,
    required this.labels,
    required this.tint,
    required this.dark,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final VoidCallback? onSearch;
  final List<String> labels;
  final Color tint;
  final bool dark;

  @override
  State<_NativeSideTabBar> createState() => _NativeSideTabBarState();
}

class _NativeSideTabBarState extends State<_NativeSideTabBar> {
  MethodChannel? _channel;

  Map<String, Object> _params(BuildContext context) => {
    'tabs': [
      for (final (index, (plain, chosen)) in CardsSideTabBar._symbols.indexed)
        {
          'plain': plain,
          'chosen': chosen,
          'label': index < widget.labels.length ? widget.labels[index] : '',
        },
    ],
    'selected': widget.current,
    'tint': widget.tint.toARGB32(),
    'dark': widget.dark,
    'search': widget.onSearch != null,
    'searchLabel': MaterialLocalizations.of(context).searchFieldLabel,
  };

  @override
  void didUpdateWidget(_NativeSideTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _channel
        ?.invokeMethod<void>('update', _params(context))
        .catchError((Object _) {});
  }

  void _created(int id) {
    final channel = MethodChannel('cards/side_tab_bar_$id');
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'select':
          Haptics.select();
          widget.onSelect(call.arguments as int);
        case 'search':
          Haptics.select();
          widget.onSearch?.call();
      }
    });
    _channel = channel;
  }

  @override
  Widget build(BuildContext context) {
    // While a page covers this one the native glass steps out: iOS keeps a
    // stale picture of hosted glass under a page, so on the way back a fresh
    // view is made, with fresh glass.
    final covered = !(ModalRoute.isCurrentOf(context) ?? true);
    return SizedBox(
      width: CardsSideTabBar.width,
      height: CardsSideTabBar.nativeHeight(
        CardsSideTabBar._symbols.length,
        search: widget.onSearch != null,
      ),
      child: covered
          ? null
          : UiKitView(
              viewType: 'cards/side_tab_bar',
              creationParams: _params(context),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _created,
            ),
    );
  }
}
