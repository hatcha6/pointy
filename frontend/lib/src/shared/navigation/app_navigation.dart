import 'package:flutter/widgets.dart';

import '../../core/authorization.dart';
import '../../data/models/pos_user.dart';

/// Top-level destinations reachable from the app drawer and navigation rail.
enum AppNavigationDestination {
  userSettings,
  dashboard,
  pos,
  aiAssistant,
  operations,
  assets,
  invoices,
  returnsExchange,
  purchasing,
  contacts,
  conversations,
  campaigns,
  catalog,
  categories,
  stockCount,
  registerSessions,
  employees,
  expenses,
  payments,
  discounts,
  reports,
  activityLog,
  deviceSettings,
  users,
  settings,
}

/// The capability that makes a destination visible and reachable.
///
/// Single source of truth consumed by the drawer, the rail, and the central
/// navigation handler, so an item can never be visible without being
/// navigable or vice versa.
AppCapability appNavigationDestinationCapability(
  AppNavigationDestination destination,
) {
  return switch (destination) {
    AppNavigationDestination.userSettings => AppCapability.manageOwnAccount,
    AppNavigationDestination.dashboard => AppCapability.viewDashboard,
    AppNavigationDestination.pos => AppCapability.accessPos,
    AppNavigationDestination.aiAssistant => AppCapability.useAiAssistant,
    AppNavigationDestination.operations => AppCapability.viewOperations,
    AppNavigationDestination.assets => AppCapability.viewAssets,
    AppNavigationDestination.invoices => AppCapability.viewInvoices,
    AppNavigationDestination.returnsExchange =>
      AppCapability.processReturnsByLookup,
    AppNavigationDestination.purchasing => AppCapability.accessPurchasing,
    AppNavigationDestination.contacts => AppCapability.manageContacts,
    AppNavigationDestination.conversations => AppCapability.viewConversations,
    AppNavigationDestination.campaigns => AppCapability.manageCampaigns,
    AppNavigationDestination.catalog => AppCapability.viewCatalogManagement,
    AppNavigationDestination.categories => AppCapability.manageCategories,
    AppNavigationDestination.stockCount => AppCapability.countStock,
    AppNavigationDestination.registerSessions =>
      AppCapability.viewRegisterSessions,
    AppNavigationDestination.employees => AppCapability.viewEmployees,
    AppNavigationDestination.expenses => AppCapability.viewExpenses,
    AppNavigationDestination.payments => AppCapability.viewPayments,
    AppNavigationDestination.discounts => AppCapability.viewDiscountRules,
    AppNavigationDestination.reports => AppCapability.viewReports,
    AppNavigationDestination.activityLog => AppCapability.viewActivityLog,
    AppNavigationDestination.deviceSettings =>
      AppCapability.manageDeviceSettings,
    AppNavigationDestination.users => AppCapability.manageUsers,
    AppNavigationDestination.settings => AppCapability.manageShopSettings,
  };
}

/// Central handle for app-level navigation.
///
/// Implemented once by the authenticated shell and handed to every screen, so
/// the drawer/rail behaves identically everywhere instead of each screen
/// wiring (and forgetting) its own per-destination callbacks.
abstract interface class AppNavigation {
  PosUser get currentUser;
  AuthorizationCapabilities get capabilities;

  /// Navigate to [destination] with uniform stack semantics.
  ///
  /// [from] is the destination of the screen initiating the navigation; it
  /// lets the handler keep the POS workspace on the stack and skip
  /// navigating to the screen that is already shown.
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  });

  /// Open the AI assistant, optionally seeding the composer with [seedPrompt]
  /// and immediately sending it ([autoSend]). Proactive AI hints across the app
  /// call this to drop the user straight into a relevant question. A no-op when
  /// the shop's AI entitlement is inactive, so callers needn't pre-check.
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  });

  void logout(BuildContext context);
}

extension AppNavigationAvailability on AppNavigation {
  bool isDestinationAvailable(AppNavigationDestination destination) {
    return capabilities.allows(appNavigationDestinationCapability(destination));
  }
}
