import 'package:flutter/material.dart';

import 'app_dependencies.dart';
import 'core/authorization.dart';
import 'data/models/pos_user.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/device_settings/views/device_settings_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
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

  Widget buildPosScreen(BuildContext context) {
    return PosScreen(
      viewModel: dependencies.posViewModel,
      currentUser: currentUser,
      capabilities: capabilities,
      onOpenCatalog: guardedAsyncAction(
        AppCapability.viewCatalogManagement,
        () async {
          await push(context, catalogRouteBuilder);
          await dependencies.posViewModel.loadCatalog();
        },
      ),
      onOpenRegisterSessions: guardedAsyncAction(
        AppCapability.viewRegisterSessions,
        () async {
          await push(context, registerSessionsRouteBuilder);
          await dependencies.posViewModel.loadCatalog();
        },
      ),
      onOpenDeviceSettings: guardedAction(
        AppCapability.manageDeviceSettings,
        () => push(context, deviceSettingsRouteBuilder),
      ),
      onOpenUsers: capabilities.asyncActionFor(
        AppCapability.manageUsers,
        () async {
          await push(context, usersRouteBuilder);
          await dependencies.posViewModel.loadCatalog();
        },
      ),
      onOpenShopSettings: capabilities.asyncActionFor(
        AppCapability.manageShopSettings,
        () async {
          await push(context, shopSettingsRouteBuilder);
          await dependencies.posViewModel.loadCatalog();
          await dependencies.posViewModel.loadCheckoutSettings();
        },
      ),
      onLogout: () => logout(context),
    );
  }

  Widget catalogRouteBuilder(BuildContext routeContext) {
    return CatalogScreen(
      viewModel: CatalogViewModel(dependencies.catalogRepository),
      inventoryRepository: dependencies.inventoryRepository,
      printingRepository: dependencies.printingRepository,
      currentUser: currentUser,
      capabilities: capabilities,
      onOpenPos: guardedAction(
        AppCapability.accessPos,
        () => openPos(routeContext),
      ),
      onOpenRegisterSessions: guardedAction(
        AppCapability.viewRegisterSessions,
        () => replace(routeContext, registerSessionsRouteBuilder),
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
    );
  }

  Widget registerSessionsRouteBuilder(BuildContext routeContext) {
    return RegisterSessionHistoryScreen(
      viewModel: RegisterSessionHistoryViewModel(
        dependencies.registerSessionRepository,
        dependencies.saleRepository,
      ),
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
    );
  }

  Widget usersRouteBuilder(BuildContext routeContext) {
    return UserManagementScreen(
      viewModel: UserManagementViewModel(dependencies.userRepository),
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
      onOpenRegisterSessions: guardedAction(
        AppCapability.viewRegisterSessions,
        () => replace(routeContext, registerSessionsRouteBuilder),
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
    );
  }

  Widget shopSettingsRouteBuilder(BuildContext routeContext) {
    return ShopSettingsScreen(
      viewModel: ShopSettingsViewModel(dependencies.shopSettingsRepository),
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
      onOpenRegisterSessions: guardedAction(
        AppCapability.viewRegisterSessions,
        () => replace(routeContext, registerSessionsRouteBuilder),
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
    );
  }

  Widget deviceSettingsRouteBuilder(BuildContext routeContext) {
    return DeviceSettingsScreen(
      viewModel: dependencies.printingSettingsViewModel,
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
      onOpenRegisterSessions: guardedAction(
        AppCapability.viewRegisterSessions,
        () => replace(routeContext, registerSessionsRouteBuilder),
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

  void openPos(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void logout(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    dependencies.authViewModel.logout();
  }
}
