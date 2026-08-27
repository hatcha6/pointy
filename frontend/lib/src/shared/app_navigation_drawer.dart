import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/analytics_interaction_tracker.dart';
import '../features/users/role_presentation.dart';
import 'command_palette/command_palette.dart';
import 'components/components.dart';
import 'design/design.dart';
import 'navigation/app_navigation.dart';
import 'navigation/navigation_catalog.dart';
import 'theme/theme_mode_controls.dart';

export 'navigation/app_navigation.dart';

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({
    super.key,
    required this.selectedDestination,
    required this.navigation,
  });

  final AppNavigationDestination selectedDestination;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = _availableGroups(l10n);

    return PointyNavigationSurface(
      userLabel: navigation.currentUser.label,
      roleLabel: roleLabelFor(context, navigation.currentUser.role),
      navigationChildren: [
        const _CommandPaletteTile(closeDrawer: true),
        const SizedBox(height: 4),
        for (final group in groups)
          // Every destination is rendered directly under a static section
          // header — no expand step — so a destination is always one tap away.
          _NavigationSection(
            group: group,
            selectedDestination: selectedDestination,
            dense: false,
            onSelect: (destination) {
              _selectDestination(
                context,
                destination,
                target: 'navigation_drawer',
                closeDrawer: true,
              );
            },
          ),
        const Divider(height: 24),
        const ThemeModeDrawerTile(),
      ],
      logoutTile: ListTile(
        leading: const Icon(Icons.logout),
        title: Text(
          l10n.logoutButton,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          _logout(context, target: 'navigation_drawer', closeDrawer: true);
        },
      ),
    );
  }

  Widget buildRail(BuildContext context, {bool extended = false}) {
    final l10n = AppLocalizations.of(context)!;
    final groups = _availableGroups(l10n);

    return PointyNavigationRailSurface(
      userLabel: navigation.currentUser.label,
      roleLabel: roleLabelFor(context, navigation.currentUser.role),
      logoutTooltip: l10n.logoutButton,
      onLogout: () {
        _logout(context, target: 'navigation_rail', closeDrawer: false);
      },
      extended: extended,
      navigationChildren: [
        if (extended)
          const _CommandPaletteTile(closeDrawer: false)
        else
          const _CollapsedCommandPaletteButton(),
        if (extended)
          for (final group in groups)
            _NavigationSection(
              group: group,
              selectedDestination: selectedDestination,
              dense: true,
              onSelect: (destination) {
                _selectDestination(
                  context,
                  destination,
                  target: 'navigation_rail',
                  closeDrawer: false,
                );
              },
            )
        else
          for (
            var groupIndex = 0;
            groupIndex < groups.length;
            groupIndex++
          ) ...[
            if (groupIndex > 0) const Divider(height: 12),
            for (final destination in groups[groupIndex].destinations)
              _CollapsedRailDestinationTile(
                destination: destination,
                selected: destination.destination == selectedDestination,
                onTap: () {
                  _selectDestination(
                    context,
                    destination,
                    target: 'navigation_rail',
                    closeDrawer: false,
                  );
                },
              ),
          ],
        const Divider(height: 12),
        if (extended)
          const ThemeModeDrawerTile()
        else
          const ThemeModeToggleButton(),
      ],
    );
  }

  List<_NavigationGroup> _availableGroups(AppLocalizations l10n) {
    // Built from the shared navigation catalog (the single source of truth that
    // also feeds the command palette), filtered to the destinations this user's
    // capabilities allow — so the same user sees the same destinations on every
    // screen, and the drawer and palette can never drift apart.
    return [
      for (final group in appNavigationCatalog(l10n))
        _NavigationGroup(
          label: group.label,
          icon: group.icon,
          destinations: [
            for (final entry in group.entries)
              if (navigation.isDestinationAvailable(entry.destination))
                _DrawerDestination(
                  destination: entry.destination,
                  icon: entry.icon,
                  selectedIcon: entry.selectedIcon,
                  label: entry.label,
                ),
          ],
        ),
    ].where((group) => group.destinations.isNotEmpty).toList(growable: false);
  }

  void _selectDestination(
    BuildContext context,
    _DrawerDestination destination, {
    required String target,
    required bool closeDrawer,
  }) {
    unawaited(
      AnalyticsInteractionTracker.maybeOf(context)?.trackInteraction(
            action: 'navigation_destination_selected',
            target: target,
            attributes: {
              'destination': destination.destination.name,
              'was_selected': destination.destination == selectedDestination,
            },
          ) ??
          Future<void>.value(),
    );
    if (closeDrawer) {
      Navigator.of(context).pop();
    }
    navigation.navigateTo(
      context,
      destination.destination,
      from: selectedDestination,
    );
  }

  void _logout(
    BuildContext context, {
    required String target,
    required bool closeDrawer,
  }) {
    AnalyticsInteractionTracker.track(
      context,
      action: 'logout_selected',
      target: target,
    );
    if (closeDrawer) {
      Navigator.of(context).pop();
    }
    navigation.logout(context);
  }
}

class _NavigationGroup {
  const _NavigationGroup({
    required this.label,
    required this.icon,
    required this.destinations,
  });

  final String label;
  final IconData icon;
  final List<_DrawerDestination> destinations;
}

/// A static, always-expanded navigation section: a muted section header with
/// every destination rendered directly beneath it. Replaces the old
/// expand-then-select [ExpansionTile] so reaching any screen is a single tap.
class _NavigationSection extends StatelessWidget {
  const _NavigationSection({
    required this.group,
    required this.selectedDestination,
    required this.onSelect,
    required this.dense,
  });

  final _NavigationGroup group;
  final AppNavigationDestination selectedDestination;
  final ValueChanged<_DrawerDestination> onSelect;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NavSectionHeader(label: group.label, icon: group.icon, dense: dense),
        for (final destination in group.destinations)
          _NavDestinationTile(
            destination: destination,
            selected: destination.destination == selectedDestination,
            dense: dense,
            onTap: () => onSelect(destination),
          ),
      ],
    );
  }
}

class _NavSectionHeader extends StatelessWidget {
  const _NavSectionHeader({
    required this.label,
    required this.icon,
    required this.dense,
  });

  final String label;
  final IconData icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        dense ? 12 : 20,
        dense ? 14 : 18,
        12,
        6,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.mutedInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavDestinationTile extends StatelessWidget {
  const _NavDestinationTile({
    required this.destination,
    required this.selected,
    required this.dense,
    required this.onTap,
  });

  final _DrawerDestination destination;
  final bool selected;
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final foreground = selected ? colors.primaryDark : colors.ink;

    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: dense ? 6 : 10,
        vertical: 2,
      ),
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              dense ? 12 : 16,
              dense ? 9 : 11,
              12,
              dense ? 9 : 11,
            ),
            child: Row(
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 20,
                  color: selected ? colors.primaryDark : colors.mutedInk,
                ),
                SizedBox(width: dense ? 12 : 14),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedRailDestinationTile extends StatelessWidget {
  const _CollapsedRailDestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _DrawerDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Tooltip(
      message: destination.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: IconButton(
          isSelected: selected,
          style: IconButton.styleFrom(
            backgroundColor: selected ? colors.primaryContainer : null,
            foregroundColor: selected ? colors.primaryDark : colors.mutedInk,
          ),
          onPressed: onTap,
          icon: Icon(selected ? destination.selectedIcon : destination.icon),
        ),
      ),
    );
  }
}

class _DrawerDestination {
  const _DrawerDestination({
    required this.destination,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final AppNavigationDestination destination;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Entry point that opens the global command palette from the drawer / rail.
class _CommandPaletteTile extends StatelessWidget {
  const _CommandPaletteTile({required this.closeDrawer});

  final bool closeDrawer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      leading: const Icon(Icons.search),
      title: Text(
        l10n.commandPaletteOpenLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const _ShortcutHint(),
      onTap: () {
        if (closeDrawer) {
          Navigator.of(context).pop();
        }
        openCommandPalette();
      },
    );
  }
}

class _CollapsedCommandPaletteButton extends StatelessWidget {
  const _CollapsedCommandPaletteButton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IconButton(
        tooltip: l10n.commandPaletteOpenLabel,
        onPressed: openCommandPalette,
        icon: const Icon(Icons.search),
      ),
    );
  }
}

/// A small keyboard-shortcut hint chip (⌘K / Ctrl K) shown on the palette tile.
class _ShortcutHint extends StatelessWidget {
  const _ShortcutHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final isApple =
        theme.platform == TargetPlatform.macOS ||
        theme.platform == TargetPlatform.iOS;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          isApple ? '⌘K' : 'Ctrl K',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.mutedInk,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
