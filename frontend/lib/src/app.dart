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
import 'data/services/connection_status_controller.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/auth/views/auth_gate.dart';
import 'features/connection/views/connection_gate.dart';
import 'features/onboarding/views/shop_setup_wizard.dart';
import 'features/price_checker/price_checker_mode_actions.dart';
import 'features/price_checker/views/price_checker_kiosk_screen.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'shared/design/design.dart';
import 'shared/price_checker/price_checker_mode_controller.dart';
import 'shared/shell/shell.dart';
import 'shared/theme/theme_controller.dart';

class PointyApp extends StatefulWidget {
  const PointyApp({super.key, this.apiService});

  final PosApiService? apiService;

  @override
  State<PointyApp> createState() => _PointyAppState();
}

class _PointyAppState extends State<PointyApp> with WidgetsBindingObserver {
  late final PointyAppDependencies _dependencies;
  late final PointyNavigationRailController _navigationRailController;
  // App-lifetime home for the nav drawer/rail scroll offsets: screens replace
  // each other as routes, so per-route PageStorage forgets the list position
  // on every navigation.
  final PageStorageBucket _navigationScrollBucket = PageStorageBucket();
  void Function(FlutterErrorDetails details)? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;
  late final TimingsCallback _frameTimingsCallback;

  @override
  void initState() {
    super.initState();
    _dependencies = PointyAppDependencies(apiService: widget.apiService);
    _navigationRailController = PointyNavigationRailController();
    _dependencies.authViewModel.addListener(_dependencies.handleAuthChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_dependencies.start());
    unawaited(_dependencies.analyticsEngine.start());
    _frameTimingsCallback = _dependencies.analyticsEngine.recordFrameTimings;
    SchedulerBinding.instance.addTimingsCallback(_frameTimingsCallback);
    _installErrorTracking();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground is the cheapest reliable signal that the
    // network may have changed (Wi-Fi reconnected, roamed APs, DHCP renewed).
    // Re-hunt for the LAN backend unless we already hold a healthy one.
    if (state == AppLifecycleState.resumed &&
        _dependencies.connectionStatus.phase != ConnectionPhase.connectedLocal) {
      unawaited(_dependencies.connectionCoordinator.rediscover());
    }
  }

  @override
  void dispose() {
    FlutterError.onError = _previousFlutterErrorHandler;
    PlatformDispatcher.instance.onError = _previousPlatformErrorHandler;
    WidgetsBinding.instance.removeObserver(this);
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
      // Rebuild on theme changes and when this device enters/leaves kiosk mode,
      // so top-level routing can swap between the kiosk and the auth gate.
      listenable: Listenable.merge([
        _dependencies.themeController,
        _dependencies.priceCheckerModeController,
      ]),
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
        child: PriceCheckerModeScope(
          controller: _dependencies.priceCheckerModeController,
          child: AnalyticsInteractionTracker(
            analyticsEngine: _dependencies.analyticsEngine,
            child: _PrinterConnectionNotifier(
              authViewModel: _dependencies.authViewModel,
              printingSettingsViewModel:
                  _dependencies.printingSettingsViewModel,
              child: PointyNavigationRailScope(
                isActive: false,
                controller: _navigationRailController,
                navigationBucket: _navigationScrollBucket,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
      home: _dependencies.priceCheckerModeController.enabled
          ? PriceCheckerKioskScreen(
              repository: _dependencies.priceCheckerRepository,
              controller: _dependencies.priceCheckerModeController,
            )
          : ConnectionGate(
              controller: _dependencies.connectionStatus,
              coordinator: _dependencies.connectionCoordinator,
              child: AuthGate(
                viewModel: _dependencies.authViewModel,
                analyticsEngine: _dependencies.analyticsEngine,
                authenticatedBuilder: _buildAuthenticatedHome,
                onEnterPriceCheckerMode: _enterPriceCheckerMode,
              ),
            ),
    );
  }

  Future<void> _enterPriceCheckerMode(BuildContext context) {
    return enterPriceCheckerMode(
      context,
      controller: _dependencies.priceCheckerModeController,
      repository: _dependencies.priceCheckerRepository,
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
