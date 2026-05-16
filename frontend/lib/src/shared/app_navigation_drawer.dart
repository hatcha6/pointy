import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/authorization.dart';
import '../data/models/pos_user.dart';

enum AppNavigationDestination {
  pos,
  catalog,
  registerSessions,
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
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onLogout,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final AppNavigationDestination selectedDestination;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final destinations = [
      _DrawerDestination(
        destination: AppNavigationDestination.pos,
        capability: AppCapability.accessPos,
        icon: const Icon(Icons.receipt_long_outlined),
        selectedIcon: const Icon(Icons.receipt_long),
        label: l10n.posDrawerLabel,
        onTap: onOpenPos,
      ),
      _DrawerDestination(
        destination: AppNavigationDestination.catalog,
        capability: AppCapability.viewCatalogManagement,
        icon: const Icon(Icons.inventory_2_outlined),
        selectedIcon: const Icon(Icons.inventory_2),
        label: l10n.catalogDrawerLabel,
        onTap: onOpenCatalog,
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
    ].where((destination) => destination.isAvailable(capabilities)).toList();
    final selectedIndex = destinations.indexWhere(
      (destination) => destination.destination == selectedDestination,
    );

    return NavigationDrawer(
      selectedIndex: selectedIndex == -1 ? null : selectedIndex,
      onDestinationSelected: (index) {
        Navigator.of(context).pop();
        destinations[index].onTap?.call();
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                child: const Icon(Icons.point_of_sale),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentUser.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _roleLabel(l10n, currentUser.role),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        for (final destination in destinations)
          NavigationDrawerDestination(
            icon: destination.icon,
            selectedIcon: destination.selectedIcon,
            label: Text(destination.label),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l10n.logoutButton),
          onTap: () {
            Navigator.of(context).pop();
            onLogout();
          },
        ),
      ],
    );
  }

  String _roleLabel(AppLocalizations l10n, UserRole role) {
    return switch (role) {
      UserRole.manager => l10n.managerRoleLabel,
      UserRole.cashier => l10n.cashierRoleLabel,
    };
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
