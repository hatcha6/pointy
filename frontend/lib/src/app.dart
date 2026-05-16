import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'core/authorization.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/shop_settings_repository.dart';
import 'data/repositories/printing_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/auth/views/auth_gate.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/device_settings/views/device_settings_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
import 'features/settings/view_models/shop_settings_view_model.dart';
import 'features/settings/views/shop_settings_screen.dart';
import 'features/users/view_models/user_management_view_model.dart';
import 'features/users/views/user_management_screen.dart';

class PointyApp extends StatefulWidget {
  const PointyApp({super.key, this.apiService});

  final PosApiService? apiService;

  @override
  State<PointyApp> createState() => _PointyAppState();
}

class _PointyAppState extends State<PointyApp> {
  late final PosApiService _service;
  late final AuthRepository _authRepository;
  late final CatalogRepository _catalogRepository;
  late final RegisterSessionRepository _registerSessionRepository;
  late final SaleRepository _saleRepository;
  late final ShopSettingsRepository _shopSettingsRepository;
  late final PrintingRepository _printingRepository;
  late final UserRepository _userRepository;
  late final AuthViewModel _authViewModel;
  late final PosViewModel _posViewModel;
  late final PrintingSettingsViewModel _printingSettingsViewModel;
  int? _lastAuthenticatedUserId;

  @override
  void initState() {
    super.initState();
    _service = widget.apiService ?? PosApiService();
    _authRepository = AuthRepository(_service);
    _catalogRepository = CatalogRepository(_service);
    _registerSessionRepository = RegisterSessionRepository(_service);
    _saleRepository = SaleRepository(_service);
    _shopSettingsRepository = ShopSettingsRepository(_service);
    _printingRepository = PrintingRepository(_service);
    _userRepository = UserRepository(_service);
    _authViewModel = AuthViewModel(_authRepository)
      ..addListener(_handleAuthChanged);
    _posViewModel = PosViewModel(
      _catalogRepository,
      _registerSessionRepository,
      _saleRepository,
    );
    _printingSettingsViewModel = PrintingSettingsViewModel(_printingRepository);
  }

  @override
  void dispose() {
    _authViewModel.removeListener(_handleAuthChanged);
    _authViewModel.dispose();
    _posViewModel.dispose();
    _printingSettingsViewModel.dispose();
    super.dispose();
  }

  void _handleAuthChanged() {
    final currentUser = _authViewModel.currentUser;
    if (_authViewModel.status == AuthStatus.authenticated &&
        currentUser != null &&
        _lastAuthenticatedUserId != currentUser.id) {
      _lastAuthenticatedUserId = currentUser.id;
      _posViewModel.loadCurrentRegisterSession();
    }

    if (_authViewModel.status == AuthStatus.unauthenticated) {
      _lastAuthenticatedUserId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) {
          return AuthGate(
            viewModel: _authViewModel,
            authenticatedBuilder: _buildAuthenticatedHome,
          );
        },
      ),
    );
  }

  Widget _buildAuthenticatedHome(BuildContext context) {
    final currentUser = _authViewModel.currentUser;
    if (currentUser == null) {
      return AuthGate(
        viewModel: _authViewModel,
        authenticatedBuilder: _buildAuthenticatedHome,
      );
    }

    final capabilities = AuthorizationCapabilities.forUser(currentUser);

    VoidCallback guardedAction(AppCapability capability, VoidCallback action) {
      return capabilities.actionFor(capability, action) ?? () {};
    }

    Future<void> Function() guardedAsyncAction(
      AppCapability capability,
      Future<void> Function() action,
    ) {
      return capabilities.asyncActionFor(capability, action) ?? () async {};
    }

    void openPos(BuildContext routeContext) {
      Navigator.of(routeContext).popUntil((route) => route.isFirst);
    }

    late WidgetBuilder catalogRouteBuilder;
    late WidgetBuilder registerSessionsRouteBuilder;
    late WidgetBuilder deviceSettingsRouteBuilder;
    late WidgetBuilder usersRouteBuilder;
    late WidgetBuilder shopSettingsRouteBuilder;

    void logout(BuildContext routeContext) {
      Navigator.of(routeContext).popUntil((route) => route.isFirst);
      _authViewModel.logout();
    }

    void openUsers(BuildContext routeContext) {
      Navigator.of(
        routeContext,
      ).pushReplacement(MaterialPageRoute<void>(builder: usersRouteBuilder));
    }

    void openDeviceSettings(BuildContext routeContext) {
      Navigator.of(routeContext).pushReplacement(
        MaterialPageRoute<void>(builder: deviceSettingsRouteBuilder),
      );
    }

    void openShopSettings(BuildContext routeContext) {
      Navigator.of(routeContext).pushReplacement(
        MaterialPageRoute<void>(builder: shopSettingsRouteBuilder),
      );
    }

    catalogRouteBuilder = (routeContext) {
      return CatalogScreen(
        viewModel: CatalogViewModel(_catalogRepository),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () {
            Navigator.of(routeContext).pushReplacement(
              MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
            );
          },
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => openDeviceSettings(routeContext),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => openUsers(routeContext),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => openShopSettings(routeContext),
        ),
        onLogout: () => logout(routeContext),
      );
    };

    registerSessionsRouteBuilder = (routeContext) {
      return RegisterSessionHistoryScreen(
        viewModel: RegisterSessionHistoryViewModel(
          _registerSessionRepository,
          _saleRepository,
        ),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(AppCapability.viewCatalogManagement, () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        }),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => openDeviceSettings(routeContext),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => openUsers(routeContext),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => openShopSettings(routeContext),
        ),
        onLogout: () => logout(routeContext),
      );
    };

    usersRouteBuilder = (routeContext) {
      return UserManagementScreen(
        viewModel: UserManagementViewModel(_userRepository),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(AppCapability.viewCatalogManagement, () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        }),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () {
            Navigator.of(routeContext).pushReplacement(
              MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
            );
          },
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => openDeviceSettings(routeContext),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => openShopSettings(routeContext),
        ),
        onLogout: () => logout(routeContext),
      );
    };

    shopSettingsRouteBuilder = (routeContext) {
      return ShopSettingsScreen(
        viewModel: ShopSettingsViewModel(_shopSettingsRepository),
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(AppCapability.viewCatalogManagement, () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        }),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () {
            Navigator.of(routeContext).pushReplacement(
              MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
            );
          },
        ),
        onOpenDeviceSettings: guardedAction(
          AppCapability.manageDeviceSettings,
          () => openDeviceSettings(routeContext),
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => openUsers(routeContext),
        ),
        onLogout: () => logout(routeContext),
      );
    };

    deviceSettingsRouteBuilder = (routeContext) {
      return DeviceSettingsScreen(
        viewModel: _printingSettingsViewModel,
        currentUser: currentUser,
        capabilities: capabilities,
        onOpenPos: guardedAction(
          AppCapability.accessPos,
          () => openPos(routeContext),
        ),
        onOpenCatalog: guardedAction(AppCapability.viewCatalogManagement, () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        }),
        onOpenRegisterSessions: guardedAction(
          AppCapability.viewRegisterSessions,
          () {
            Navigator.of(routeContext).pushReplacement(
              MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
            );
          },
        ),
        onOpenUsers: capabilities.actionFor(
          AppCapability.manageUsers,
          () => openUsers(routeContext),
        ),
        onOpenShopSettings: capabilities.actionFor(
          AppCapability.manageShopSettings,
          () => openShopSettings(routeContext),
        ),
        onLogout: () => logout(routeContext),
      );
    };

    return PosScreen(
      viewModel: _posViewModel,
      currentUser: currentUser,
      capabilities: capabilities,
      onOpenCatalog: guardedAsyncAction(
        AppCapability.viewCatalogManagement,
        () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: catalogRouteBuilder));
          await _posViewModel.loadCatalog();
        },
      ),
      onOpenRegisterSessions: guardedAsyncAction(
        AppCapability.viewRegisterSessions,
        () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
          );
          await _posViewModel.loadCatalog();
        },
      ),
      onOpenDeviceSettings: guardedAction(
        AppCapability.manageDeviceSettings,
        () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: deviceSettingsRouteBuilder));
        },
      ),
      onOpenUsers: capabilities.asyncActionFor(
        AppCapability.manageUsers,
        () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: usersRouteBuilder));
          await _posViewModel.loadCatalog();
        },
      ),
      onOpenShopSettings: capabilities.asyncActionFor(
        AppCapability.manageShopSettings,
        () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: shopSettingsRouteBuilder));
          await _posViewModel.loadCatalog();
        },
      ),
      onLogout: () => logout(context),
    );
  }
}
