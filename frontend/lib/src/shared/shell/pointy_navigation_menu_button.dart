import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'pointy_navigation_rail_scope.dart';

class PointyNavigationMenuButton extends StatelessWidget {
  const PointyNavigationMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final railScope = PointyNavigationRailScope.maybeOf(context);
    if (railScope?.isActive ?? false) {
      return IconButton(
        tooltip: railScope!.isExpanded
            ? l10n.navigationRailCollapseTooltip
            : l10n.navigationRailExpandTooltip,
        onPressed: railScope.toggleExpanded,
        icon: const Icon(Icons.menu),
      );
    }

    final scaffold = Scaffold.maybeOf(context);
    return IconButton(
      tooltip: l10n.navigationMenuTooltip,
      onPressed: scaffold?.openDrawer,
      icon: const Icon(Icons.menu),
    );
  }
}
