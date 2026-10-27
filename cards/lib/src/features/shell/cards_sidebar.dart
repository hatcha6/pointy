import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_logo.dart';
import '../../design/cards_theme.dart';
import '../../design/cards_tokens.dart';
import '../../shared/category_icon.dart';
import '../../shared/haptics.dart';
import '../../shared/search_field.dart';
import '../shelf/shelf_model.dart';
import 'cards_tab_bar.dart';

/// The app on a desktop's wide window, as the App Store on a Mac: a sidebar
/// down the start edge holding the mark, search, the three places, and the
/// shelf's categories, in place of a phone's tab bar along the bottom.
class CardsSidebar extends StatefulWidget {
  const CardsSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.shelf,
    required this.onCategory,
  });

  final int current;
  final ValueChanged<int> onSelect;
  final ShelfModel shelf;

  /// Shows the shelf on [key]'s category, or on everything for null.
  final ValueChanged<String?> onCategory;

  static const double width = 264;

  @override
  State<CardsSidebar> createState() => _CardsSidebarState();
}

class _CardsSidebarState extends State<CardsSidebar> {
  late final _query = TextEditingController(text: widget.shelf.query);

  @override
  void initState() {
    super.initState();
    widget.shelf.addListener(_follow);
  }

  @override
  void dispose() {
    widget.shelf.removeListener(_follow);
    _query.dispose();
    super.dispose();
  }

  /// The field shows the shelf's search, however it was cleared.
  void _follow() {
    if (_query.text != widget.shelf.query) {
      _query.text = widget.shelf.query;
    }
  }

  void _search(String text) {
    widget.shelf.search(text);
    if (widget.current != 0) {
      widget.onSelect(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final shelf = widget.shelf;
    final tabs = CardsTabBar.tabsOf(l10n);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: BorderDirectional(
          end: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        right: false,
        left: false,
        child: ListenableBuilder(
          listenable: shelf,
          builder: (context, _) {
            final categories = [...shelf.shelf.categories]
              ..sort((a, b) => a.rank.compareTo(b.rank));
            // A category reads as chosen only while the shelf is what shows.
            final onShelf = widget.current == 0 && !shelf.searching;
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                CardsSpace.md,
                CardsSpace.xl,
                CardsSpace.md,
                CardsSpace.xl,
              ),
              children: [
                const Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: CardsSpace.sm,
                    bottom: CardsSpace.lg,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: CardsLogo(size: 30, withName: true),
                  ),
                ),
                CardsSearchField(controller: _query, onChanged: _search),
                const SizedBox(height: CardsSpace.md),
                for (final (index, (label, icon, selected)) in tabs.indexed)
                  _SidebarItem(
                    label: label,
                    icon: index == widget.current ? selected : icon,
                    selected:
                        index == widget.current &&
                        (index != 0 || shelf.category == null),
                    // The shelf's own tab starts it over, as on the tab bar.
                    onTap: () => widget.onSelect(index),
                  ),
                if (categories.length > 1) ...[
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      CardsSpace.md,
                      CardsSpace.xl,
                      CardsSpace.md,
                      CardsSpace.sm,
                    ),
                    child: Text(
                      l10n.searchBrowseCategories,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final category in categories)
                    _SidebarItem(
                      label: category.name,
                      icon: categoryIcon(category.key),
                      selected: onShelf && shelf.category == category.key,
                      onTap: () => widget.onCategory(category.key),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One row of the sidebar: an icon and a name, the chosen one on a tinted
/// rounded bar, as a Mac's sidebars mark it.
class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = CardsTheme.link(theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? tint.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(CardsRadii.field),
        child: InkWell(
          borderRadius: BorderRadius.circular(CardsRadii.field),
          onTap: () {
            Haptics.select();
            onTap();
          },
          child: Semantics(
            selected: selected,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.md,
                vertical: 10,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: selected ? tint : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: CardsSpace.md),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: selected ? tint : theme.colorScheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
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

/// Whether the shell has a sidebar beside its pages: a desktop's wide
/// window, with no system side column and not a phone drawing Liquid Glass.
bool sidebarFits(BuildContext context) {
  final media = MediaQuery.of(context);
  return CardsLayout.desktop(media.size) &&
      !CardsTabBar.nativeGlass &&
      CardsTabBar.side(media.padding) == null;
}

/// Marks the pages beside the sidebar: they lay out for a desktop (no tab
/// bar to keep clear of, rows a mouse can use) in the room the sidebar
/// leaves them.
class CardsSidebarScope extends InheritedWidget {
  const CardsSidebarScope({super.key, required super.child});

  /// Whether [context] is a page beside the sidebar.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CardsSidebarScope>() != null;

  @override
  bool updateShouldNotify(CardsSidebarScope oldWidget) => false;
}
