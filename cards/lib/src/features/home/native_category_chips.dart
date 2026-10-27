import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../shared/native_glass_chips.dart';
import '../shelf/shelf_model.dart';

/// The shelf's categories as the system's Liquid Glass chips, «الكل» first.
class NativeCategoryChips extends StatelessWidget {
  const NativeCategoryChips({
    super.key,
    required this.shelf,
    required this.onCategory,
    this.column = EdgeInsets.zero,
  });

  final ShelfModel shelf;

  /// The system side column the row runs under.
  final EdgeInsets column;
  final ValueChanged<String?> onCategory;

  static const double height = NativeGlassChips.height;

  /// Each category's SF Symbol, matching the Material icons elsewhere.
  static String symbolOf(String? key) => switch (key) {
    null => 'sparkles',
    'telecom' => 'simcard',
    'intl_topup' => 'globe',
    'internet' => 'wifi',
    'gaming' => 'gamecontroller',
    'gift_cards' => 'gift',
    'tv' => 'tv',
    'services' => 'graduationcap',
    _ => 'square.stack',
  };

  @override
  Widget build(BuildContext context) {
    final categories = [...shelf.shelf.categories]
      ..sort((a, b) => a.rank.compareTo(b.rank));
    return NativeGlassChips(
      column: column,
      chips: [
        (
          key: '',
          label: AppLocalizations.of(context).allCategories,
          symbol: symbolOf(null),
        ),
        for (final category in categories)
          (
            key: category.key,
            label: category.name,
            symbol: symbolOf(category.key),
          ),
      ],
      selected: shelf.category ?? '',
      onSelect: (key) => onCategory(key.isEmpty ? null : key),
    );
  }
}
