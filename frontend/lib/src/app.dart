import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/scheduler.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'app_dependencies.dart';
import 'authenticated_home.dart';
import 'core/analytics_interaction_tracker.dart';
import 'data/models/analytics_event.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/auth/views/auth_gate.dart';
import 'features/onboarding/views/shop_setup_wizard.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'shared/design/design.dart';
import 'shared/shell/shell.dart';
import 'shared/theme/theme_controller.dart';

class PointyApp extends StatefulWidget {
  const PointyApp({super.key, this.apiService});

  final PosApiService? apiService;

  @override
  State<PointyApp> createState() => _PointyAppState();
}

class _PointyAppState extends State<PointyApp> {
  late final PointyAppDependencies _dependencies;
  late final PointyNavigationRailController _navigationRailController;
  void Function(FlutterErrorDetails details)? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;
  late final TimingsCallback _frameTimingsCallback;

  @override
  void initState() {
    super.initState();
    _dependencies = PointyAppDependencies(apiService: widget.apiService);
    _navigationRailController = PointyNavigationRailController();
    _dependencies.authViewModel.addListener(_dependencies.handleAuthChanged);
    unawaited(_dependencies.start());
    unawaited(_dependencies.analyticsEngine.start());
    _frameTimingsCallback = _dependencies.analyticsEngine.recordFrameTimings;
    SchedulerBinding.instance.addTimingsCallback(_frameTimingsCallback);
    _installErrorTracking();
  }

  @override
  void dispose() {
    FlutterError.onError = _previousFlutterErrorHandler;
    PlatformDispatcher.instance.onError = _previousPlatformErrorHandler;
    SchedulerBinding.instance.removeTimingsCallback(_frameTimingsCallback);
    _dependencies.authViewModel.removeListener(_dependencies.handleAuthChanged);
    _navigationRailController.dispose();
    _dependencies.dispose();
    super.dispose();
  }

  void _installErrorTracking() {
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      final previousHandler = _previousFlutterErrorHandler;
      if (previousHandler == null) {
        FlutterError.presentError(details);
      } else {
        previousHandler(details);
      }
      unawaited(_dependencies.analyticsEngine.captureFlutterError(details));
    };

    _previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      unawaited(
        _dependencies.analyticsEngine.captureError(
          error,
          stackTrace,
          name: AnalyticsEventName.appPlatformError,
          severity: AnalyticsEventSeverity.critical,
        ),
      );
      return _previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _dependencies.themeController,
      builder: (context, _) => _buildApp(),
    );
  }

  Widget _buildApp() {
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
      theme: PointyTheme.light(),
      darkTheme: PointyTheme.dark(),
      themeMode: _dependencies.themeController.mode,
      builder: (context, child) => ThemeControllerScope(
        controller: _dependencies.themeController,
        child: AnalyticsInteractionTracker(
          analyticsEngine: _dependencies.analyticsEngine,
          child: _PrinterConnectionNotifier(
            authViewModel: _dependencies.authViewModel,
            printingSettingsViewModel: _dependencies.printingSettingsViewModel,
            child: PointyNavigationRailScope(
              isActive: false,
              controller: _navigationRailController,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      home: AuthGate(
        viewModel: _dependencies.authViewModel,
        analyticsEngine: _dependencies.analyticsEngine,
        authenticatedBuilder: _buildAuthenticatedHome,
      ),
    );
  }

  Widget _buildAuthenticatedHome(BuildContext context) {
    final currentUser = _dependencies.authViewModel.currentUser;
    if (currentUser == null) {
      return AuthGate(
        viewModel: _dependencies.authViewModel,
        analyticsEngine: _dependencies.analyticsEngine,
        authenticatedBuilder: _buildAuthenticatedHome,
      );
    }

    if (_dependencies.authViewModel.requiresShopSetup) {
      return ShopSetupWizard(
        shopSettingsRepository: _dependencies.shopSettingsRepository,
        onComplete: _dependencies.authViewModel.completeShopSetup,
      );
    }

    return AuthenticatedHome(
      dependencies: _dependencies,
      currentUser: currentUser,
    );
  }
}

class _PrinterConnectionNotifier extends StatefulWidget {
  const _PrinterConnectionNotifier({
    required this.authViewModel,
    required this.printingSettingsViewModel,
    required this.child,
  });

  final AuthViewModel authViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final Widget child;

  @override
  State<_PrinterConnectionNotifier> createState() =>
      _PrinterConnectionNotifierState();
}

class _PrinterConnectionNotifierState
    extends State<_PrinterConnectionNotifier> {
  String? _lastEndpointKey;
  String? _notifiedDisconnectedEndpointKey;

  @override
  void initState() {
    super.initState();
    widget.authViewModel.addListener(_handleStateChanged);
    widget.printingSettingsViewModel.addListener(_handleStateChanged);
  }

  @override
  void didUpdateWidget(_PrinterConnectionNotifier oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authViewModel != widget.authViewModel) {
      oldWidget.authViewModel.removeListener(_handleStateChanged);
      widget.authViewModel.addListener(_handleStateChanged);
    }
    if (oldWidget.printingSettingsViewModel !=
        widget.printingSettingsViewModel) {
      oldWidget.printingSettingsViewModel.removeListener(_handleStateChanged);
      widget.printingSettingsViewModel.addListener(_handleStateChanged);
    }
  }

  @override
  void dispose() {
    widget.authViewModel.removeListener(_handleStateChanged);
    widget.printingSettingsViewModel.removeListener(_handleStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  void _handleStateChanged() {
    final endpoint = widget.printingSettingsViewModel.config.endpoint;
    final endpointKey =
        '${endpoint.kind.name}:${endpoint.address}:${endpoint.port}';
    if (_lastEndpointKey != endpointKey) {
      _lastEndpointKey = endpointKey;
      _notifiedDisconnectedEndpointKey = null;
    }

    if (widget.printingSettingsViewModel.connectionState ==
        PrinterConnectionState.connected) {
      _notifiedDisconnectedEndpointKey = null;
      return;
    }

    if (widget.authViewModel.status != AuthStatus.authenticated ||
        !widget.printingSettingsViewModel.shouldWarnPrinterDisconnected ||
        _notifiedDisconnectedEndpointKey == endpointKey) {
      return;
    }

    _notifiedDisconnectedEndpointKey = endpointKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.printerDisconnectedSnackBar),
          action: SnackBarAction(
            label: l10n.checkPrinterConnectionButton,
            onPressed: widget.printingSettingsViewModel.checkPrinterConnection,
          ),
        ),
      );
    });
  }
}
