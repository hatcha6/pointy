import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyNavigationSurface extends StatelessWidget {
  const PointyNavigationSurface({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.userLabel,
    required this.roleLabel,
    required this.destinations,
    required this.logoutTile,
  });

  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final String userLabel;
  final String roleLabel;
  final List<Widget> destinations;
  final Widget logoutTile;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return NavigationDrawer(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.lg,
            spacing.xl,
            spacing.lg,
            spacing.md,
          ),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryStrong,
                  borderRadius: BorderRadius.circular(PointyRadii.card),
                ),
                child: Padding(
                  padding: EdgeInsets.all(spacing.sm),
                  child: Icon(Icons.point_of_sale, color: colors.surface),
                ),
              ),
              SizedBox(width: spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Text(
                      roleLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        ...destinations,
        const Divider(),
        logoutTile,
      ],
    );
  }
}

class PointyNavigationRailSurface extends StatelessWidget {
  const PointyNavigationRailSurface({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.userLabel,
    required this.roleLabel,
    required this.destinations,
    required this.logoutTooltip,
    required this.onLogout,
  });

  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final String userLabel;
  final String roleLabel;
  final List<NavigationRailDestination> destinations;
  final String logoutTooltip;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      labelType: NavigationRailLabelType.none,
      scrollable: true,
      trailingAtBottom: true,
      minWidth: 88,
      backgroundColor: colors.surface,
      useIndicator: true,
      indicatorColor: PointyColors.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.button),
      ),
      selectedIconTheme: IconThemeData(color: colors.primaryDark),
      unselectedIconTheme: IconThemeData(color: colors.mutedInk),
      selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
        color: colors.primaryDark,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w500,
      ),
      leading: Padding(
        padding: EdgeInsetsDirectional.only(
          top: spacing.md,
          bottom: spacing.sm,
        ),
        child: Tooltip(
          message: '$userLabel\n$roleLabel',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryStrong,
              borderRadius: BorderRadius.circular(PointyRadii.card),
            ),
            child: Padding(
              padding: EdgeInsets.all(spacing.sm),
              child: Icon(Icons.point_of_sale, color: colors.surface),
            ),
          ),
        ),
      ),
      trailing: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Tooltip(
          message: logoutTooltip,
          child: IconButton(
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
          ),
        ),
      ),
      destinations: destinations,
    );
  }
}
