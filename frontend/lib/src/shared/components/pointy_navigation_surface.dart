import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import '../shell/pointy_navigation_rail_scope.dart';

/// Wraps a navigation list in the app shell's scroll bucket (when one is
/// provided): screens replace each other as routes (each with per-route
/// PageStorage), so without the app-level bucket the drawer/rail list forgets
/// its scroll offset on every navigation. Without a shell (tests, previews)
/// the child renders as-is.
Widget _withNavigationScrollBucket(BuildContext context, Widget child) {
  final bucket = PointyNavigationRailScope.maybeOf(context)?.navigationBucket;
  if (bucket == null) {
    return child;
  }
  return PageStorage(bucket: bucket, child: child);
}

class PointyNavigationSurface extends StatelessWidget {
  const PointyNavigationSurface({
    super.key,
    required this.userLabel,
    required this.roleLabel,
    required this.navigationChildren,
    required this.logoutTile,
  });

  final String userLabel;
  final String roleLabel;
  final List<Widget> navigationChildren;
  final Widget logoutTile;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return _withNavigationScrollBucket(
      context,
      NavigationDrawer(
        key: const PageStorageKey('app-navigation-drawer'),
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
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
          ...navigationChildren,
          const Divider(),
          logoutTile,
        ],
      ),
    );
  }
}

class PointyNavigationRailSurface extends StatelessWidget {
  const PointyNavigationRailSurface({
    super.key,
    required this.userLabel,
    required this.roleLabel,
    required this.navigationChildren,
    required this.logoutTooltip,
    required this.onLogout,
    this.extended = false,
  });

  final String userLabel;
  final String roleLabel;
  final List<Widget> navigationChildren;
  final String logoutTooltip;
  final VoidCallback onLogout;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Material(
      color: colors.surface,
      child: SizedBox(
        width: extended ? 240 : 88,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsetsDirectional.only(
                top: spacing.md,
                bottom: spacing.sm,
              ),
              child: extended
                  ? _ExtendedRailHeader(
                      userLabel: userLabel,
                      roleLabel: roleLabel,
                    )
                  : Tooltip(
                      message: '$userLabel\n$roleLabel',
                      child: const _RailMark(),
                    ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: _withNavigationScrollBucket(
                  context,
                  ListView(
                    // Per-mode keys: the same offset means a different place
                    // in the denser collapsed layout.
                    key: PageStorageKey(
                      extended
                          ? 'app-navigation-rail-extended'
                          : 'app-navigation-rail-collapsed',
                    ),
                    padding: EdgeInsetsDirectional.symmetric(
                      vertical: spacing.sm,
                      horizontal: extended ? spacing.sm : spacing.xs,
                    ),
                    children: navigationChildren,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: extended
                  ? FilledButton.tonalIcon(
                      onPressed: onLogout,
                      icon: const Icon(Icons.logout),
                      label: Text(logoutTooltip),
                    )
                  : Tooltip(
                      message: logoutTooltip,
                      child: IconButton(
                        onPressed: onLogout,
                        icon: const Icon(Icons.logout),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtendedRailHeader extends StatelessWidget {
  const _ExtendedRailHeader({required this.userLabel, required this.roleLabel});

  final String userLabel;
  final String roleLabel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return SizedBox(
      width: 208,
      child: Padding(
        padding: EdgeInsetsDirectional.symmetric(horizontal: spacing.md),
        child: Row(
          children: [
            const _RailMark(),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    userLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    roleLabel,
                    maxLines: 1,
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
    );
  }
}

class _RailMark extends StatelessWidget {
  const _RailMark();

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primaryStrong,
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Icon(Icons.point_of_sale, color: colors.surface),
      ),
    );
  }
}
