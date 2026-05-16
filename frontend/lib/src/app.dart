import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/auth/views/auth_gate.dart';
import 'features/catalog/view_models/catalog_view_model.dart';
import 'features/catalog/views/catalog_screen.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/pos/views/pos_screen.dart';
import 'features/register_sessions/view_models/register_session_history_view_model.dart';
import 'features/register_sessions/views/register_session_history_screen.dart';
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
  late final UserRepository _userRepository;
  late final AuthViewModel _authViewModel;
  late final PosViewModel _posViewModel;
  int? _lastAuthenticatedUserId;

  @override
  void initState() {
    super.initState();
    _service = widget.apiService ?? PosApiService();
    _authRepository = AuthRepository(_service);
    _catalogRepository = CatalogRepository(_service);
    _registerSessionRepository = RegisterSessionRepository(_service);
    _saleRepository = SaleRepository(_service);
    _userRepository = UserRepository(_service);
    _authViewModel = AuthViewModel(_authRepository)
      ..addListener(_handleAuthChanged);
    _posViewModel = PosViewModel(
      _catalogRepository,
      _registerSessionRepository,
      _saleRepository,
    );
  }

  @override
  void dispose() {
    _authViewModel.removeListener(_handleAuthChanged);
    _authViewModel.dispose();
    _posViewModel.dispose();
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

    void openPos(BuildContext routeContext) {
      Navigator.of(routeContext).popUntil((route) => route.isFirst);
    }

    late WidgetBuilder catalogRouteBuilder;
    late WidgetBuilder registerSessionsRouteBuilder;
    late WidgetBuilder usersRouteBuilder;

    void logout(BuildContext routeContext) {
      Navigator.of(routeContext).popUntil((route) => route.isFirst);
      _authViewModel.logout();
    }

    void openUsers(BuildContext routeContext) {
      if (!currentUser.role.isManager) {
        return;
      }
      Navigator.of(
        routeContext,
      ).pushReplacement(MaterialPageRoute<void>(builder: usersRouteBuilder));
    }

    catalogRouteBuilder = (routeContext) {
      return CatalogScreen(
        viewModel: CatalogViewModel(_catalogRepository),
        currentUser: currentUser,
        onOpenPos: () => openPos(routeContext),
        onOpenRegisterSessions: () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
          );
        },
        onOpenUsers: currentUser.role.isManager
            ? () => openUsers(routeContext)
            : null,
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
        onOpenPos: () => openPos(routeContext),
        onOpenCatalog: () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        },
        onOpenUsers: currentUser.role.isManager
            ? () => openUsers(routeContext)
            : null,
        onLogout: () => logout(routeContext),
      );
    };

    usersRouteBuilder = (routeContext) {
      return UserManagementScreen(
        viewModel: UserManagementViewModel(_userRepository),
        currentUser: currentUser,
        onOpenPos: () => openPos(routeContext),
        onOpenCatalog: () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: catalogRouteBuilder),
          );
        },
        onOpenRegisterSessions: () {
          Navigator.of(routeContext).pushReplacement(
            MaterialPageRoute<void>(builder: registerSessionsRouteBuilder),
          );
        },
        onLogout: () => logout(routeContext),
      );
    };

    return PosScreen(
      viewModel: _posViewModel,
      currentUser: currentUser,
      onOpenCatalog: () async {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: catalogRouteBuilder));
        await _posViewModel.loadCatalog();
      },
      onOpenRegisterSessions: () async {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: registerSessionsRouteBuilder));
        await _posViewModel.loadCatalog();
      },
      onOpenUsers: currentUser.role.isManager
          ? () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: usersRouteBuilder));
              await _posViewModel.loadCatalog();
            }
          : null,
      onLogout: () => logout(context),
    );
  }
}
