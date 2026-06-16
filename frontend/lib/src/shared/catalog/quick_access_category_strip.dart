import 'package:flutter/material.dart';

import '../../core/result.dart';
import '../../data/models/product_category.dart';
import '../../data/repositories/catalog_repository.dart';
import 'pointy_category_strip.dart';

/// One-tap category filter chips shown above the POS / purchasing catalog
/// search. The chips are the shop's "quick access" categories (curated in the
/// category management screen); tapping one filters the catalog to that
/// category and all of its descendants. Any category that is currently active
/// but not pinned is still shown so the cashier can clear it.
///
/// The strip quietly collapses to nothing when there is nothing to show, so it
/// never adds empty chrome to a shop that hasn't pinned any categories.
class QuickAccessCategoryStrip extends StatefulWidget {
  const QuickAccessCategoryStrip({
    super.key,
    required this.catalogRepository,
    required this.selectedCategories,
    required this.allLabel,
    required this.onSelectAll,
    required this.onSelectCategory,
  });

  final CatalogRepository catalogRepository;
  final List<ProductCategory> selectedCategories;
  final String allLabel;
  final VoidCallback onSelectAll;
  final ValueChanged<ProductCategory> onSelectCategory;

  @override
  State<QuickAccessCategoryStrip> createState() =>
      _QuickAccessCategoryStripState();
}

class _QuickAccessCategoryStripState extends State<QuickAccessCategoryStrip> {
  List<ProductCategory> _quickAccess = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.catalogRepository.loadQuickAccessCategories();
    if (!mounted) {
      return;
    }
    if (result case Ok<List<ProductCategory>>(value: final categories)) {
      setState(() => _quickAccess = categories);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Quick-access categories first, then any active-but-unpinned category so
    // a filter chosen from the filter sheet still shows (and can be cleared).
    final quickAccessIds = {for (final c in _quickAccess) c.id};
    final extras = [
      for (final category in widget.selectedCategories)
        if (!quickAccessIds.contains(category.id) &&
            category.name.trim().isNotEmpty)
          category,
    ];
    final categories = [
      for (final category in _quickAccess)
        if (category.name.trim().isNotEmpty) category,
      ...extras,
    ];

    if (categories.isEmpty) {
      // Nothing pinned and nothing selected: don't take up space. While the
      // first load is still in flight we also stay collapsed to avoid a flash.
      return const SizedBox.shrink();
    }

    final selectedValues = {
      for (final category in widget.selectedCategories) category.id,
    };
    final byId = {for (final category in categories) category.id: category};

    return PointyCategoryStrip<int>(
      allLabel: widget.allLabel,
      items: [
        for (final category in categories)
          PointyCategoryStripItem(value: category.id, label: category.name),
      ],
      selectedValues: selectedValues,
      onSelectAll: widget.onSelectAll,
      onSelected: (categoryId) {
        final category = byId[categoryId];
        if (category != null) {
          widget.onSelectCategory(category);
        }
      },
    );
  }
}
