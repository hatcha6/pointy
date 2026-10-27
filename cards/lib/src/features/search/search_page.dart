import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/category_icon.dart';
import '../../shared/empty_state.dart';
import '../../shared/grouped.dart';
import '../../shared/search_field.dart';
import '../../shared/section_header.dart';
import '../../shared/side_back.dart';
import '../shelf/shelf_model.dart';
import 'search_result_row.dart';
import '../../core/analytics/analytics.dart';

/// Search as a page of its own, as Apple's apps open it from a search
/// button: a title, the field ready to type in, the categories to browse
/// until something is typed, then the brands found.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.shelf, required this.onCategory});

  final ShelfModel shelf;

  /// A category picked to browse: the page closes and the shelf shows it.
  final ValueChanged<String> onCategory;

  static Future<void> open(
    BuildContext context, {
    required ShelfModel shelf,
    required ValueChanged<String> onCategory,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: screenSettings('search'),
      builder: (_) => SearchPage(shelf: shelf, onCategory: onCategory),
    ),
  );

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// The shelf switches first, hidden under this page, then the page
  /// leaves to show it.
  void _browse(String key) {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onCategory(key);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Asked here, outside the side column's room: inside it the column is
    // already set aside and cannot be seen.
    final sideBack = SideBack.active(context);
    return SideBack(
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // One readable column; the rows bring their own gutters.
              final column = CardsLayout.column(constraints.maxWidth);
              final inset = EdgeInsets.symmetric(
                horizontal: column.left - CardsSpace.gutter,
              );
              return ListenableBuilder(
                listenable: Listenable.merge([widget.shelf, _query]),
                builder: (context, _) => CustomScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    if (!sideBack) const SliverAppBar(pinned: true),
                    SliverPadding(
                      padding: inset,
                      sliver: SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            CardsSpace.gutter,
                            sideBack ? CardsSpace.xl : CardsSpace.sm,
                            CardsSpace.gutter,
                            CardsSpace.md,
                          ),
                          child: Text(
                            l10n.searchTitle,
                            style: theme.textTheme.headlineLarge,
                          ),
                        ),
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _FieldHeader(
                        inset: inset,
                        field: CardsSearchField(
                          controller: _query,
                          autofocus: true,
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: inset.copyWith(
                        bottom:
                            MediaQuery.paddingOf(context).bottom +
                            CardsSpace.huge,
                      ),
                      sliver: _body(context),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shelf = widget.shelf;
    final text = _query.text.trim();
    if (text.isEmpty) {
      final categories = [...shelf.shelf.categories]
        ..sort((a, b) => a.rank.compareTo(b.rank));
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.lg,
            CardsSpace.gutter,
            0,
          ),
          child: Grouped(
            title: l10n.searchBrowseCategories,
            children: [
              for (final category in categories)
                ListTile(
                  leading: Icon(categoryIcon(category.key)),
                  title: Text(category.name),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _browse(category.key),
                ),
            ],
          ),
        ),
      );
    }
    final found = shelf.find(text);
    if (found.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: l10n.searchNoResultsTitle(text),
          body: l10n.searchNoResultsBody,
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: SectionHeader(title: l10n.searchResults)),
        SliverList.separated(
          itemCount: found.length,
          separatorBuilder: (_, _) => const SizedBox(height: CardsSpace.xs),
          itemBuilder: (context, index) =>
              SearchResultRow(brand: found[index], shelf: shelf),
        ),
      ],
    );
  }
}

/// The field, pinned while the results scroll under it.
class _FieldHeader extends SliverPersistentHeaderDelegate {
  _FieldHeader({required this.inset, required this.field});

  final EdgeInsets inset;
  final Widget field;

  static const double _height = 68;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Padding(
      padding:
          inset +
          const EdgeInsets.fromLTRB(
            CardsSpace.gutter,
            CardsSpace.sm,
            CardsSpace.gutter,
            CardsSpace.sm,
          ),
      child: field,
    ),
  );

  @override
  bool shouldRebuild(covariant _FieldHeader oldDelegate) =>
      oldDelegate.inset != inset || oldDelegate.field != field;
}
