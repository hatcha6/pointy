import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/analytics_interaction_tracker.dart';
import '../core/authorization.dart';
import '../data/models/pos_user.dart';
import 'components/components.dart';
import 'shell/pointy_user_settings_route_scope.dart';

enum AppNavigationDestination {
  userSettings,
  dashboard,
  pos,
  invoices,
  purchasing,
  contacts,
  catalog,
  categories,
  registerSessions,
  employees,
  discounts,
  reports,
  activityLog,
  deviceSettings,
  users,
  settings,
}

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({
    super.key,
    required this.selectedDestination,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenInvoices,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenCategories,
    this.onOpenEmployees,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final AppNavigationDestination selectedDestination;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback? onOpenInvoices;
  final VoidCallback? onOpenPurchasing;
  final VoidCallback? onOpenContacts;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenCategories;
  final VoidCallback? onOpenEmployees;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = _availableGroups(l10n, context);

    return PointyNavigationSurface(
      userLabel: currentUser.label,
      roleLabel: _roleLabel(l10n, currentUser.role),
      navigationChildren: [
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
    final groups = _availableGroups(l10n, context);

    return PointyNavigationRailSurface(
      userLabel: currentUser.label,
      roleLabel: _roleLabel(l10n, currentUser.role),
      logoutTooltip: l10n.logoutButton,
      onLogout: () {
        _logout(context, target: 'navigation_rail', closeDrawer: false);
      },
      extended: extended,
      navigationChildren: [
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
      ],
    );
  }

  List<_NavigationGroup> _availableGroups(
    AppLocalizations l10n,
    BuildContext context,
  ) {
    final userSettingsScope = PointyUserSettingsRouteScope.maybeOf(context);
    final groups = [
      _NavigationGroup(
        label: l10n.navigationGroupPrimary,
        icon: Icons.home_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.dashboard,
            capability: AppCapability.viewDashboard,
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: l10n.dashboardDrawerLabel,
            onTap: onOpenDashboard,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.pos,
            capability: AppCapability.accessPos,
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            label: l10n.posDrawerLabel,
            onTap: onOpenPos,
          ),
        ],
      ),
      _NavigationGroup(
        label: l10n.navigationGroupSales,
        icon: Icons.point_of_sale_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.invoices,
            capability: AppCapability.viewInvoices,
            icon: const Icon(Icons.request_quote_outlined),
            selectedIcon: const Icon(Icons.request_quote),
            label: l10n.invoicesDrawerLabel,
            onTap: onOpenInvoices,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.registerSessions,
            capability: AppCapability.viewRegisterSessions,
            icon: const Icon(Icons.manage_history_outlined),
            selectedIcon: const Icon(Icons.manage_history),
            label: l10n.registerSessionsDrawerLabel,
            onTap: onOpenRegisterSessions,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.discounts,
            capability: AppCapability.viewDiscountRules,
            icon: const Icon(Icons.local_offer_outlined),
            selectedIcon: const Icon(Icons.local_offer),
            label: l10n.discountsDrawerLabel,
            onTap: onOpenDiscounts,
          ),
        ],
      ),
      _NavigationGroup(
        label: l10n.navigationGroupStock,
        icon: Icons.inventory_2_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.catalog,
            capability: AppCapability.viewCatalogManagement,
            icon: const Icon(Icons.inventory_2_outlined),
            selectedIcon: const Icon(Icons.inventory_2),
            label: l10n.catalogDrawerLabel,
            onTap: onOpenCatalog,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.categories,
            capability: AppCapability.manageCategories,
            icon: const Icon(Icons.category_outlined),
            selectedIcon: const Icon(Icons.category),
            label: l10n.categoriesDrawerLabel,
            onTap: onOpenCategories,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.purchasing,
            capability: AppCapability.accessPurchasing,
            icon: const Icon(Icons.add_shopping_cart_outlined),
            selectedIcon: const Icon(Icons.add_shopping_cart),
            label: l10n.purchasingDrawerLabel,
            onTap: onOpenPurchasing,
          ),
        ],
      ),
      _NavigationGroup(
        label: l10n.navigationGroupPeople,
        icon: Icons.groups_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.contacts,
            capability: AppCapability.manageContacts,
            icon: const Icon(Icons.contacts_outlined),
            selectedIcon: const Icon(Icons.contacts),
            label: l10n.contactsDrawerLabel,
            onTap: onOpenContacts,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.employees,
            capability: AppCapability.viewEmployees,
            icon: const Icon(Icons.badge_outlined),
            selectedIcon: const Icon(Icons.badge),
            label: l10n.employeesDrawerLabel,
            onTap: onOpenEmployees,
          ),
        ],
      ),
      _NavigationGroup(
        label: l10n.navigationGroupReports,
        icon: Icons.query_stats_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.reports,
            capability: AppCapability.viewReports,
            icon: const Icon(Icons.summarize_outlined),
            selectedIcon: const Icon(Icons.summarize),
            label: l10n.reportsDrawerLabel,
            onTap: onOpenReports,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.activityLog,
            capability: AppCapability.viewActivityLog,
            icon: const Icon(Icons.manage_search_outlined),
            selectedIcon: const Icon(Icons.manage_search),
            label: l10n.activityLogDrawerLabel,
            onTap: onOpenActivityLog,
          ),
        ],
      ),
      _NavigationGroup(
        label: l10n.navigationGroupSettings,
        icon: Icons.tune_outlined,
        destinations: [
          _DrawerDestination(
            destination: AppNavigationDestination.userSettings,
            capability: AppCapability.manageOwnAccount,
            icon: const Icon(Icons.manage_accounts_outlined),
            selectedIcon: const Icon(Icons.manage_accounts),
            label: l10n.userSettingsDrawerLabel,
            onTap: userSettingsScope == null
                ? null
                : () => userSettingsScope.onOpenUserSettings(context),
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.deviceSettings,
            capability: AppCapability.manageDeviceSettings,
            icon: const Icon(Icons.devices_other_outlined),
            selectedIcon: const Icon(Icons.devices_other),
            label: l10n.deviceSettingsDrawerLabel,
            onTap: onOpenDeviceSettings,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.users,
            capability: AppCapability.manageUsers,
            icon: const Icon(Icons.group_outlined),
            selectedIcon: const Icon(Icons.group),
            label: l10n.usersDrawerLabel,
            onTap: onOpenUsers,
          ),
          _DrawerDestination(
            destination: AppNavigationDestination.settings,
            capability: AppCapability.manageShopSettings,
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.settingsDrawerLabel,
            onTap: onOpenShopSettings,
          ),
        ],
      ),
    ];

    return [
      for (final group in groups)
        _NavigationGroup(
          label: group.label,
          icon: group.icon,
          destinations: group.destinations
              .where((destination) => destination.isAvailable(capabilities))
              .toList(growable: false),
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
    destination.onTap?.call();
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
    onLogout();
  }

  String _roleLabel(AppLocalizations l10n, UserRole role) {
    return switch (role) {
      UserRole.manager => l10n.managerRoleLabel,
      UserRole.cashier => l10n.cashierRoleLabel,
      UserRole.accountant => l10n.accountantRoleLabel,
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
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: destination.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: IconButton(
          isSelected: selected,
          style: IconButton.styleFrom(
            backgroundColor: selected ? colorScheme.primaryContainer : null,
            foregroundColor: selected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
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
    required this.capability,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
  });

  final AppNavigationDestination destination;
  final AppCapability capability;
  final Widget icon;
  final Widget selectedIcon;
  final String label;
  final VoidCallback? onTap;

  bool isAvailable(AuthorizationCapabilities capabilities) {
    return onTap != null && capabilities.allows(capability);
  }
}
