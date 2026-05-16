import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/pos_user.dart';

enum AppNavigationDestination { pos, catalog, registerSessions, users }

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({
    super.key,
    required this.selectedDestination,
    required this.currentUser,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onLogout,
    this.onOpenUsers,
  });

  final AppNavigationDestination selectedDestination;
  final PosUser currentUser;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback? onOpenUsers;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedIndex = switch (selectedDestination) {
      AppNavigationDestination.pos => 0,
      AppNavigationDestination.catalog => 1,
      AppNavigationDestination.registerSessions => 2,
      AppNavigationDestination.users => 3,
    };
    final canManageUsers = currentUser.role.isManager && onOpenUsers != null;

    return NavigationDrawer(
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) {
        Navigator.of(context).pop();
        if (index == 0) {
          onOpenPos();
        } else if (index == 1) {
          onOpenCatalog();
        } else if (index == 2) {
          onOpenRegisterSessions();
        } else {
          onOpenUsers?.call();
        }
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
        NavigationDrawerDestination(
          icon: const Icon(Icons.receipt_long_outlined),
          selectedIcon: const Icon(Icons.receipt_long),
          label: Text(l10n.posDrawerLabel),
        ),
        NavigationDrawerDestination(
          icon: const Icon(Icons.inventory_2_outlined),
          selectedIcon: const Icon(Icons.inventory_2),
          label: Text(l10n.catalogDrawerLabel),
        ),
        NavigationDrawerDestination(
          icon: const Icon(Icons.manage_history_outlined),
          selectedIcon: const Icon(Icons.manage_history),
          label: Text(l10n.registerSessionsDrawerLabel),
        ),
        if (canManageUsers)
          NavigationDrawerDestination(
            icon: const Icon(Icons.group_outlined),
            selectedIcon: const Icon(Icons.group),
            label: Text(l10n.usersDrawerLabel),
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
