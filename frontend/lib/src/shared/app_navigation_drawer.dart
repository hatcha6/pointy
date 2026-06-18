import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/analytics_interaction_tracker.dart';
import '../data/models/pos_user.dart';
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
      roleLabel: _roleLabel(l10n, navigation.currentUser.role),
      navigationChildren: [
        const _CommandPaletteTile(closeDrawer: true),
        for (final group in groups)
          _DrawerNavigationGroupTile(
            group: group,
            selectedDestination: selectedDestination,
            onSelect: (destination) {
              _selectDestination(
                context,
                destination,
                target: 'navigation_drawer',
                closeDrawer: true,
              );
            },
          ),
        const Divider(height: 12),
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
      roleLabel: _roleLabel(l10n, navigation.currentUser.role),
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
            _RailNavigationGroupTile(
              group: group,
              selectedDestination: selectedDestination,
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
                  icon: Icon(entry.icon),
                  selectedIcon: Icon(entry.selectedIcon),
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

  String _roleLabel(AppLocalizations l10n, UserRole role) {
    return switch (role) {
      UserRole.manager => l10n.managerRoleLabel,
      UserRole.cashier => l10n.cashierRoleLabel,
      UserRole.accountant => l10n.accountantRoleLabel,
      UserRole.technician => l10n.technicianRoleLabel,
    };
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

class _DrawerNavigationGroupTile extends StatelessWidget {
  const _DrawerNavigationGroupTile({
    required this.group,
    required this.selectedDestination,
    required this.onSelect,
  });

  final _NavigationGroup group;
  final AppNavigationDestination selectedDestination;
  final ValueChanged<_DrawerDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    final hasSelectedChild = group.destinations.any(
      (destination) => destination.destination == selectedDestination,
    );
    return ExpansionTile(
      initiallyExpanded: hasSelectedChild,
      leading: Icon(group.icon),
      title: Text(group.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      children: [
        for (final destination in group.destinations)
          _DrawerDestinationTile(
            destination: destination,
            selected: destination.destination == selectedDestination,
            onTap: () => onSelect(destination),
          ),
      ],
    );
  }
}

class _DrawerDestinationTile extends StatelessWidget {
  const _DrawerDestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _DrawerDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      leading: selected ? destination.selectedIcon : destination.icon,
      title: Text(
        destination.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      contentPadding: const EdgeInsetsDirectional.only(start: 40, end: 24),
      onTap: onTap,
    );
  }
}

class _RailNavigationGroupTile extends StatelessWidget {
  const _RailNavigationGroupTile({
    required this.group,
    required this.selectedDestination,
    required this.onSelect,
  });

  final _NavigationGroup group;
  final AppNavigationDestination selectedDestination;
  final ValueChanged<_DrawerDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    final hasSelectedChild = group.destinations.any(
      (destination) => destination.destination == selectedDestination,
    );
    return ExpansionTile(
      initiallyExpanded: hasSelectedChild,
      tilePadding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
      childrenPadding: EdgeInsets.zero,
      leading: Icon(group.icon),
      title: Text(group.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      children: [
        for (final destination in group.destinations)
          _RailDestinationTile(
            destination: destination,
            selected: destination.destination == selectedDestination,
            onTap: () => onSelect(destination),
          ),
      ],
    );
  }
}

class _RailDestinationTile extends StatelessWidget {
  const _RailDestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _DrawerDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: selected ? destination.selectedIcon : destination.icon,
      title: Text(
        destination.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 8),
      onTap: onTap,
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
            backgroundColor: selected ? PointyColors.primaryContainer : null,
            foregroundColor: selected ? colors.primaryDark : colors.mutedInk,
          ),
          onPressed: onTap,
          icon: selected ? destination.selectedIcon : destination.icon,
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
  final Widget icon;
  final Widget selectedIcon;
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
