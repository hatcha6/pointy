import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_search_outcome.dart';
import '../../../shared/components/components.dart';

/// What to tell the cashier about how the grid's search results were found,
/// or null when they are simply what was typed.
///
/// The search forgives — it lifts a forgotten category chip, fixes a slip,
/// reads a word typed on the wrong keyboard layout — and a till that did so
/// silently would show results for «عصير» under a box that says «عصبر».
String? posSearchOutcomeMessage(
  AppLocalizations l10n,
  ProductSearchOutcome? outcome,
) {
  if (outcome == null) {
    return null;
  }
  final corrected = outcome.correctedQuery;
  switch (outcome.match) {
    case ProductSearchMatch.layout:
    case ProductSearchMatch.corrected:
      if (corrected != null) {
        return l10n.posSearchCorrectedNotice(corrected);
      }
      return l10n.posSearchFuzzyNotice;
    case ProductSearchMatch.fuzzy:
      return l10n.posSearchFuzzyNotice;
    case ProductSearchMatch.exact:
      return outcome.categoryFallback
          ? l10n.posSearchOtherCategoriesNotice
          : null;
    case ProductSearchMatch.none:
      return null;
  }
}

/// One compact line above the till's grid saying how the results were found.
class PosSearchOutcomeLine extends StatelessWidget {
  const PosSearchOutcomeLine({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PointyInlineMessage(
      key: const ValueKey('pos_search_outcome_line'),
      message: message,
      icon: Icons.manage_search,
      compact: true,
    );
  }
}
