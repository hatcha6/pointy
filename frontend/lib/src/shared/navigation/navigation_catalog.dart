import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'app_navigation.dart';

/// A single navigable destination in the app's navigation catalog.
///
/// This is the single source of truth shared by the navigation drawer/rail and
/// the global command palette, so the two can never drift out of sync.
class NavCatalogEntry {
  const NavCatalogEntry({
    required this.destination,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.keywords = const [],
  });

  final AppNavigationDestination destination;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Extra search terms (synonyms / latin aliases) the command palette matches
  /// against, on top of [label]. Not shown in the UI.
  final List<String> keywords;
}

/// A labelled group of related [NavCatalogEntry]s.
class NavCatalogGroup {
  const NavCatalogGroup({
    required this.label,
    required this.icon,
    required this.entries,
  });

  final String label;
  final IconData icon;
  final List<NavCatalogEntry> entries;
}

/// The ordered, grouped catalog of every top-level destination.
List<NavCatalogGroup> appNavigationCatalog(AppLocalizations l10n) {
  return [
    NavCatalogGroup(
      label: l10n.navigationGroupPrimary,
      icon: Icons.home_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.dashboard,
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          label: l10n.dashboardDrawerLabel,
          keywords: const ['dashboard', 'home'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.pos,
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long,
          label: l10n.posDrawerLabel,
          keywords: const ['pos', 'cashier', 'sell', 'بيع', 'كاشير'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.aiAssistant,
          icon: Icons.smart_toy_outlined,
          selectedIcon: Icons.smart_toy,
          label: l10n.aiAssistantDrawerLabel,
          keywords: const [
            'ai',
            'assistant',
            'chat',
            'مساعد',
            'ذكاء',
            'محادثة',
          ],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.operations,
          icon: Icons.handyman_outlined,
          selectedIcon: Icons.handyman,
          label: l10n.operationsDrawerLabel,
          keywords: const [
            'operations',
            'jobs',
            'repairs',
            'workshop',
            'صيانة',
          ],
        ),
      ],
    ),
    NavCatalogGroup(
      label: l10n.navigationGroupSales,
      icon: Icons.point_of_sale_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.invoices,
          icon: Icons.request_quote_outlined,
          selectedIcon: Icons.request_quote,
          label: l10n.invoicesDrawerLabel,
          keywords: const ['invoices', 'sales', 'فواتير', 'مبيعات'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.registerSessions,
          icon: Icons.manage_history_outlined,
          selectedIcon: Icons.manage_history,
          label: l10n.registerSessionsDrawerLabel,
          keywords: const ['register', 'sessions', 'shifts', 'صندوق', 'ورديات'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.discounts,
          icon: Icons.local_offer_outlined,
          selectedIcon: Icons.local_offer,
          label: l10n.discountsDrawerLabel,
          keywords: const ['discounts', 'offers', 'promo', 'خصومات', 'عروض'],
        ),
      ],
    ),
    NavCatalogGroup(
      label: l10n.navigationGroupStock,
      icon: Icons.inventory_2_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.catalog,
          icon: Icons.inventory_2_outlined,
          selectedIcon: Icons.inventory_2,
          label: l10n.catalogDrawerLabel,
          keywords: const ['catalog', 'products', 'items', 'منتجات', 'أصناف'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.categories,
          icon: Icons.category_outlined,
          selectedIcon: Icons.category,
          label: l10n.categoriesDrawerLabel,
          keywords: const ['categories', 'تصنيفات', 'فئات'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.purchasing,
          icon: Icons.add_shopping_cart_outlined,
          selectedIcon: Icons.add_shopping_cart,
          label: l10n.purchasingDrawerLabel,
          keywords: const [
            'purchasing',
            'purchase',
            'suppliers',
            'مشتريات',
            'شراء',
          ],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.stockCount,
          icon: Icons.fact_check_outlined,
          selectedIcon: Icons.fact_check,
          label: l10n.stockCountDrawerLabel,
          keywords: const ['stock count', 'stocktake', 'جرد'],
        ),
      ],
    ),
    NavCatalogGroup(
      label: l10n.navigationGroupPeople,
      icon: Icons.groups_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.contacts,
          icon: Icons.contacts_outlined,
          selectedIcon: Icons.contacts,
          label: l10n.contactsDrawerLabel,
          keywords: const [
            'contacts',
            'customers',
            'suppliers',
            'عملاء',
            'موردين',
          ],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.employees,
          icon: Icons.badge_outlined,
          selectedIcon: Icons.badge,
          label: l10n.employeesDrawerLabel,
          keywords: const ['employees', 'payroll', 'staff', 'موظفين', 'رواتب'],
        ),
      ],
    ),
    NavCatalogGroup(
      label: l10n.navigationGroupReports,
      icon: Icons.query_stats_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.expenses,
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long,
          label: l10n.expensesDrawerLabel,
          keywords: const ['expenses', 'مصروفات'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.payments,
          icon: Icons.account_balance_wallet_outlined,
          selectedIcon: Icons.account_balance_wallet,
          label: l10n.paymentsHubDrawerLabel,
          keywords: const [
            'payments',
            'treasury',
            'cash',
            'مدفوعات',
            'تحصيل',
            'سداد',
            'خزينة',
          ],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.reports,
          icon: Icons.summarize_outlined,
          selectedIcon: Icons.summarize,
          label: l10n.reportsDrawerLabel,
          keywords: const ['reports', 'تقارير'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.activityLog,
          icon: Icons.manage_search_outlined,
          selectedIcon: Icons.manage_search,
          label: l10n.activityLogDrawerLabel,
          keywords: const ['activity', 'audit', 'log', 'سجل', 'نشاط'],
        ),
      ],
    ),
    NavCatalogGroup(
      label: l10n.navigationGroupSettings,
      icon: Icons.tune_outlined,
      entries: [
        NavCatalogEntry(
          destination: AppNavigationDestination.userSettings,
          icon: Icons.manage_accounts_outlined,
          selectedIcon: Icons.manage_accounts,
          label: l10n.userSettingsDrawerLabel,
          keywords: const ['my account', 'profile', 'حسابي'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.deviceSettings,
          icon: Icons.devices_other_outlined,
          selectedIcon: Icons.devices_other,
          label: l10n.deviceSettingsDrawerLabel,
          keywords: const ['device', 'printer', 'أجهزة', 'طابعة'],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.users,
          icon: Icons.group_outlined,
          selectedIcon: Icons.group,
          label: l10n.usersDrawerLabel,
          keywords: const [
            'users',
            'roles',
            'permissions',
            'مستخدمين',
            'صلاحيات',
          ],
        ),
        NavCatalogEntry(
          destination: AppNavigationDestination.settings,
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          label: l10n.settingsDrawerLabel,
          keywords: const ['settings', 'shop', 'إعدادات', 'المتجر'],
        ),
      ],
    ),
  ];
}

/// Flattened entries across all groups, in catalog order.
List<NavCatalogEntry> appNavigationEntries(AppLocalizations l10n) => [
  for (final group in appNavigationCatalog(l10n)) ...group.entries,
];
