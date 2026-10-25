import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_theme.dart';
import '../../shared/haptics.dart';

/// The app's tab bar. On iOS 26 and later it is Apple's own Liquid Glass tab
/// bar, the real UIKit one hosted in the page, so it looks and moves exactly
/// as the system's apps do. Everywhere else (Android, the web, older iPhones)
/// it is our frosted bar. The page scrolls under either.
class CardsTabBar extends StatelessWidget {
  const CardsTabBar({super.key, required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

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

  void _select(int tab) {
    Haptics.select();
    onSelect(tab);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Each tab: its name, and its icon unselected and selected.
    final tabs = [
      (l10n.tabHome, Icons.storefront_outlined, Icons.storefront_rounded),
      (l10n.tabMyCards, Icons.style_outlined, Icons.style_rounded),
      (l10n.tabAccount, Icons.person_outline_rounded, Icons.person_rounded),
    ];
    // The tabs keep their places in every language: «الرئيسية» on the far
    // right, as the app was made. English or French pages read left to
    // right, but a tab bar that swapped ends would send a returning
    // customer's thumb to the wrong tab.
    if (nativeGlass) {
      return SafeArea(
        top: false,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: CNTabBar(
            currentIndex: current,
            onTap: _select,
            tint: CardsTheme.link(Theme.of(context)),
            // The same Material icons as everywhere else, drawn into the native
            // bar, at the size the system's own tab bars use.
            iconSize: 22,
            items: [
              for (final (label, icon, selected) in tabs)
                CNTabBarItem(
                  label: label,
                  customIcon: icon,
                  activeCustomIcon: selected,
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
