import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'app_dependencies.dart';
import 'core/result.dart';
import 'core/authorization.dart';
import 'data/models/pos_user.dart';
import 'data/models/purchase_submission.dart';
import 'data/models/analytics_event.dart';
import 'data/models/report_run.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/view_models/category_management_view_model.dart';
import 'features/catalog/views/category_management_screen.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/contacts/views/contact_management_screen.dart';
import 'features/dashboard/views/dashboard_screen.dart';
import 'features/device_settings/views/device_settings_screen.dart';
import 'features/discounts/views/discount_management_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/purchasing/views/purchase_order_details_screen.dart';
import 'features/purchasing/views/purchase_order_list_screen.dart';
import 'features/purchasing/views/purchasing_screen.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
import 'features/reports/pdf/report_document_builder.dart';
import 'features/reports/pdf/report_pdf.dart';
import 'features/reports/views/report_pdf_preview_screen.dart';
import 'features/reports/views/reports_screen.dart';
import 'features/settings/view_models/shop_settings_view_model.dart';
import 'features/settings/views/shop_settings_screen.dart';
import 'features/users/view_models/user_management_view_model.dart';
import 'features/users/views/user_management_screen.dart';

class AuthenticatedHome extends StatelessWidget {
  const AuthenticatedHome({
    super.key,
    required this.dependencies,
    required this.currentUser,
  });

  final PointyAppDependencies dependencies;
  final PosUser currentUser;

  @override
  Widget build(BuildContext context) {
    final routes = _AuthenticatedRoutes(
      dependencies: dependencies,
      currentUser: currentUser,
      capabilities: AuthorizationCapabilities.forUser(currentUser),
    );
    if (routes.capabilities.canViewDashboard) {
      return routes.buildDashboardScreen(context);
    }
    return routes.buildPosScreen(context);
  }
}

class _AuthenticatedRoutes {
  const _AuthenticatedRoutes({
    required this.dependencies,
    required this.currentUser,
    required this.capabilities,
  });

  final PointyAppDependencies dependencies;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;

  Widget buildDashboardScreen(BuildContext context) {
    return dashboardRouteBuilder(context);
  }

  Widget buildPosScreen(BuildContext context) {
    return _screen(
      'pos',
      PosScreen(
        viewModel: dependencies.posViewModel,
        contactRepository: dependencies.contactRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenCatalog: guardedAsyncAction(
          AppCapability.viewCatalogManagement,
          () async {
            await push(context, catalogRouteBuilder);
            await dependencies.posViewModel.loadCatalog();
          },
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => push(context, categoryRouteBuilder),
        ),
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(context),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => push(context, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => push(context, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAsyncAction(
          AppCapability.viewRegisterSessions,
          () async {
            await push(context, registerSessionsRouteBuilder);
          },
        ),
        onOpenDiscounts: guardedAsyncAction(
          AppCapability.viewDiscountRules,
          () async {
            await push(context, discountsRouteBuilder);
          },
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => push(context, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => push(context, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.asyncActionFor(
          AppCapability.manageUsers,
          () async {
            await push(context, usersRouteBuilder);
          },
        ),
        onOpenShopSettings: capabilities.asyncActionFor(
          AppCapability.manageShopSettings,
          () async {
            await push(context, shopSettingsRouteBuilder);
            await dependencies.posViewModel.loadCheckoutSettings();
          },
        ),
        onLogout: () => logout(context),
      ),
    );
  }

  Widget dashboardRouteBuilder(BuildContext routeContext) {
    return _screen(
      'dashboard',
      DashboardScreen(
        viewModel: dependencies.dashboardViewModel,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget posRouteBuilder(BuildContext routeContext) {
    return buildPosScreen(routeContext);
  }

  Widget catalogRouteBuilder(BuildContext routeContext) {
    return _screen(
      'catalog',
      CatalogScreen(
        viewModel: CatalogViewModel(dependencies.catalogRepository),
        inventoryRepository: dependencies.inventoryRepository,
        printingRepository: dependencies.printingRepository,
        purchaseRepository: dependencies.purchaseRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget categoryRouteBuilder(BuildContext routeContext) {
    return _screen(
      'categories',
      CategoryManagementScreen(
        viewModel: CategoryManagementViewModel(dependencies.catalogRepository),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget registerSessionsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'register_sessions',
      RegisterSessionHistoryScreen(
        viewModel: RegisterSessionHistoryViewModel(
          dependencies.registerSessionRepository,
          dependencies.saleRepository,
        ),
        contactRepository: dependencies.contactRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget usersRouteBuilder(BuildContext routeContext) {
    return _screen(
      'users',
      UserManagementScreen(
        viewModel: UserManagementViewModel(dependencies.userRepository),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget shopSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'shop_settings',
      ShopSettingsScreen(
        viewModel: ShopSettingsViewModel(
          dependencies.shopSettingsRepository,
          analyticsEngine: dependencies.analyticsEngine,
        ),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget discountsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'discounts',
      DiscountManagementScreen(
        viewModel: dependencies.discountManagementViewModel,
        catalogRepository: dependencies.catalogRepository,
        contactRepository: dependencies.contactRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget reportsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'reports',
      ReportsScreen(
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onPreviewPdf: (request) => previewReport(routeContext, request),
        onPrintReport: (request) => printReport(routeContext, request),
        onExportArchive: (request) => shareReport(routeContext, request),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget deviceSettingsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'device_settings',
      DeviceSettingsScreen(
        viewModel: dependencies.printingSettingsViewModel,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget contactsRouteBuilder(BuildContext routeContext) {
    return _screen(
      'contacts',
      ContactManagementScreen(
        viewModel: dependencies.contactManagementViewModel,
        purchaseRepository: dependencies.purchaseRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenPurchasing: guardedAction(
          AppCapability.accessPurchasing,
          () => replace(routeContext, purchasingRouteBuilder),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget purchasingRouteBuilder(BuildContext routeContext) {
    return _screen(
      'purchase_orders',
      PurchaseOrderListScreen(
        viewModel: dependencies.purchaseOrderListViewModel,
        contactRepository: dependencies.contactRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onCreatePurchaseOrder: guardedAction(
          AppCapability.createPurchaseOrder,
          () async {
            dependencies.purchaseViewModel.clearDraft();
            await push(routeContext, createPurchaseOrderRouteBuilder);
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
        onOpenPurchaseOrder: guardedPurchaseOrderAction(
          AppCapability.accessPurchasing,
          (order) async {
            _trackScreenView('purchase_order_details');
            await push(
              routeContext,
              (context) => PurchaseOrderDetailsScreen(
                purchaseRepository: dependencies.purchaseRepository,
                initialOrder: order,
                capabilities: capabilities,
              ),
            );
            await dependencies.purchaseOrderListViewModel.loadOrders();
          },
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget createPurchaseOrderRouteBuilder(BuildContext routeContext) {
    return _screen(
      'purchase_create',
      PurchasingScreen(
        viewModel: dependencies.purchaseViewModel,
        contactRepository: dependencies.contactRepository,
        currentUser: currentUser,
        capabilities: capabilities,
        showBackButton: true,
        onOpenDashboard: guardedAction(
          AppCapability.viewDashboard,
          () => openDashboard(routeContext),
        ),
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(
          AppCapability.viewCatalogManagement,
          () => replace(routeContext, catalogRouteBuilder),
        ),
        onOpenCategories: guardedAction(
          AppCapability.manageCategories,
          () => replace(routeContext, categoryRouteBuilder),
        ),
        onOpenContacts: guardedAction(
          AppCapability.manageContacts,
          () => replace(routeContext, contactsRouteBuilder),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () => replace(routeContext, registerSessionsRouteBuilder),
        ),
        onOpenDiscounts: guardedAction(
          AppCapability.viewDiscountRules,
          () => replace(routeContext, discountsRouteBuilder),
        ),
        onOpenReports: guardedAction(
          AppCapability.viewReports,
          () => replace(routeContext, reportsRouteBuilder),
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => replace(routeContext, deviceSettingsRouteBuilder),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => replace(routeContext, usersRouteBuilder),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => replace(routeContext, shopSettingsRouteBuilder),
        ),
        onLogout: () => logout(routeContext),
      ),
    );
  }

  Widget _screen(String screenName, Widget child) {
    _trackScreenView(screenName);
    return child;
  }

  void _trackScreenView(String screenName) {
    dependencies.analyticsEngine.setCurrentScreen(screenName);
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.frontendScreenViewed,
        attributes: {'screen': screenName, 'role': currentUser.role.toJson()},
      ),
    );
  }

  VoidCallback guardedAction(AppCapability capability, VoidCallback action) {
    return capabilities.actionFor(capability, action) ?? () {};
  }

  Future<void> Function() guardedAsyncAction(
    AppCapability capability,
    Future<void> Function() action,
  ) {
    return capabilities.asyncActionFor(capability, action) ?? () async {};
  }

  void Function(T value) guardedValueAction<T>(
    AppCapability capability,
    void Function(T value) action,
  ) {
    return capabilities.allows(capability) ? action : (_) {};
  }

  ValueChanged<PurchaseOrder> guardedPurchaseOrderAction(
    AppCapability capability,
    ValueChanged<PurchaseOrder> action,
  ) {
    return capabilities.allows(capability) ? action : (_) {};
  }

  Future<T?> push<T>(BuildContext context, WidgetBuilder builder) {
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(builder: builder));
  }

  void replace(BuildContext context, WidgetBuilder builder) {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute<void>(builder: builder));
  }

  void openDashboard(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void openPos(BuildContext context) {
    if (!capabilities.canViewDashboard) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final route = ModalRoute.of(context);
    if (route?.isFirst ?? false) {
      push(context, posRouteBuilder);
      return;
    }
    replace(context, posRouteBuilder);
  }

  void logout(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    dependencies.authViewModel.logout();
  }

  Future<void> previewReport(
    BuildContext context,
    ReportRequest request,
  ) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    unawaited(
      dependencies.analyticsEngine.trackUsage(
        AnalyticsEventName.reportPreviewed,
        attributes: _reportAttributes(request),
      ),
    );
    unawaited(push(context, (_) => ReportPdfPreviewScreen(document: document)));
  }

  Future<void> printReport(BuildContext context, ReportRequest request) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    final printed = await const ReportPrintingService().print(document);
    if (printed && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportPrinted,
          attributes: _reportAttributes(request),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportPrintQueuedMessage,
      );
    }
  }

  Future<void> shareReport(BuildContext context, ReportRequest request) async {
    final document = await buildReportDocument(context, request);
    if (document == null || !context.mounted) {
      return;
    }
    final shared = await const ReportPrintingService().share(document);
    if (shared && context.mounted) {
      unawaited(
        dependencies.analyticsEngine.trackUsage(
          AnalyticsEventName.reportShared,
          attributes: _reportAttributes(request),
        ),
      );
      _showReportMessage(
        context,
        AppLocalizations.of(context)!.reportArchiveSharedMessage,
      );
    }
  }

  Future<BusinessReportPdfDocument?> buildReportDocument(
    BuildContext context,
    ReportRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    final result = await dependencies.reportRepository.createReportRun(
      ReportRunDraft(
        reportType: _reportRunTypeForRequest(request.type),
        outputFormat: ReportOutputFormat.pdf,
        params: {
          "start_date": _apiDate(request.dateRange.start),
          "end_date": _apiDate(request.dateRange.end),
          "granularity": request.granularity.name,
        },
      ),
    );
    if (!context.mounted) {
      return null;
    }

    switch (result) {
      case Ok<ReportRun>(value: final run):
        if (run.status == ReportRunStatus.failed) {
          unawaited(
            dependencies.analyticsEngine.trackUsage(
              AnalyticsEventName.reportGenerationFailed,
              severity: AnalyticsEventSeverity.warning,
              attributes: {
                ..._reportAttributes(request),
                'error_message': run.errorMessage,
              },
              flushImmediately: true,
            ),
          );
          _showReportMessage(
            context,
            run.errorMessage.isEmpty
                ? AppLocalizations.of(context)!.reportGenerationError
                : run.errorMessage,
          );
          return null;
        }
        unawaited(
          dependencies.analyticsEngine.trackPerformance(
            name: analyticsEventNameToJson(
              AnalyticsEventName.frontendOperation,
            ),
            duration: stopwatch.elapsed,
            attributes: {
              ..._reportAttributes(request),
              'operation': 'report.generate_pdf',
              'report_run_id': run.id,
            },
            metrics: {'row_count': run.rowCount},
          ),
        );
        unawaited(
          dependencies.analyticsEngine.trackUsage(
            AnalyticsEventName.reportGenerated,
            attributes: {
              ..._reportAttributes(request),
              'report_run_id': run.id,
              'status': run.status.name,
            },
            metrics: {'row_count': run.rowCount},
          ),
        );
        return buildBusinessReportPdfDocument(
          run: run,
          l10n: AppLocalizations.of(context)!,
          currentUser: currentUser,
          includeAuditTrail: request.includeAuditTrail,
          includePreparedBy: request.includePreparedBy,
        );
      case Error<ReportRun>():
        unawaited(
          dependencies.analyticsEngine.trackUsage(
            AnalyticsEventName.reportGenerationFailed,
            severity: AnalyticsEventSeverity.error,
            attributes: _reportAttributes(request),
            flushImmediately: true,
          ),
        );
        _showReportMessage(
          context,
          AppLocalizations.of(context)!.reportGenerationError,
        );
        return null;
    }
  }

  Map<String, Object?> _reportAttributes(ReportRequest request) {
    return {
      'report_type': request.type.name,
      'granularity': request.granularity.name,
      'start_date': _apiDate(request.dateRange.start),
      'end_date': _apiDate(request.dateRange.end),
      'include_audit_trail': request.includeAuditTrail,
      'include_prepared_by': request.includePreparedBy,
    };
  }

  ReportRunType _reportRunTypeForRequest(ReportType type) {
    return switch (type) {
      ReportType.salesSummary => ReportRunType.salesSummary,
      ReportType.registerSessions => ReportRunType.registerClosure,
      ReportType.payments => ReportRunType.paymentMethods,
      ReportType.inventoryValue => ReportRunType.inventoryStatus,
      ReportType.stockMovement => ReportRunType.stockMovements,
      ReportType.purchases => ReportRunType.purchasingSummary,
    };
  }

  String _apiDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  void _showReportMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
