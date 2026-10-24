import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../design/cards_tokens.dart';

/// A shelf's title, with «عرض الكل» on the far side when there is more.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.onSeeAll,
    this.padding,
  });

  final String title;
  final VoidCallback? onSeeAll;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          padding ??
          // The title takes the gutter; «عرض الكل» keeps its own ink inset.
          const EdgeInsetsDirectional.fromSTEB(
            CardsSpace.gutter,
            CardsSpace.xl,
            CardsSpace.sm,
            CardsSpace.sm,
          ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              child: Text(AppLocalizations.of(context).seeAll),
            ),
        ],
      ),
    );
  }
}
