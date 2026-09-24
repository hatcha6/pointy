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
import 'features/companion/companion_bridge.dart';
import 'features/companion/companion_scope.dart';
import 'features/treasury/view_models/bank_routing.dart';
import 'shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'shared/barcode/camera_wedge/camera_wedge_scope.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'shared/documents/document_trail_scope.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/auth/views/auth_gate.dart';
import 'features/connection/views/connection_gate.dart';
import 'features/onboarding/views/shop_setup_wizard.dart';
import 'features/price_checker/price_checker_mode_actions.dart';
import 'features/price_checker/views/price_checker_kiosk_screen.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'shared/design/design.dart';
import 'shared/price_checker/price_checker_mode_controller.dart';
import 'shared/product_search/product_search_mode_controller.dart';
import 'shared/shell/shell.dart';
import 'shared/theme/theme_controller.dart';
import 'core/analytics_screen_tracker.dart';

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
  // each other as routes, and the routes left underneath stay alive with a
  // scroll position each, so the offset has to live above all of them.
  final PointyNavigationScrollStore _navigationScrollStore =
      PointyNavigationScrollStore();

  /// Lives as long as the app: [TrackedScreen]s subscribe to it so a screen
  /// knows when the route above it is popped and it is on show again.
  final AnalyticsRouteObserver _routeObserver = AnalyticsRouteObserver();
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
        _dependencies.connectionStatus.phase !=
            ConnectionPhase.connectedLocal) {
      unawaited(_dependencies.connectionCoordinator.rediscover());
    }
    if (state == AppLifecycleState.resumed) {
      // Coming back is when the screen is most likely to be stale — the device
      // was asleep while the back office was editing. Ask straight away rather
      // than waiting out the poll interval.
      _dependencies.serverStateWatcher.resume();
    }
    if (state != AppLifecycleState.resumed) {
      // Telemetry is written on a short delay rather than once per event, so
      // leaving the foreground is the last reliable moment to get it on disk:
      // the process may be suspended or killed before the timer would fire.
      unawaited(_dependencies.analyticsEngine.flushPendingWrites());
      // The open and held invoices are on the same kind of short delay, and
      // are worth a great deal more than the telemetry — a cashier who closes
      // the till app, or an Android system that kills it while backgrounded,
      // must not lose the item scanned a moment ago.
      unawaited(_dependencies.posViewModel.persistNow());
      // Nobody is looking: stop asking what changed until they are.
      _dependencies.serverStateWatcher.pause();
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
      navigatorObservers: [_routeObserver],
      // Outermost, so the printer notifier below shows its snackbar through
      // it too: every snackbar in the app runs on the same short timer.
      builder: (context, child) => PointyScaffoldMessenger(
        child: ThemeControllerScope(
          controller: _dependencies.themeController,
          child: PriceCheckerModeScope(
            controller: _dependencies.priceCheckerModeController,
            child: AnalyticsScreenScope(
              analyticsEngine: _dependencies.analyticsEngine,
              routeObserver: _routeObserver,
              child: AnalyticsInteractionTracker(
                analyticsEngine: _dependencies.analyticsEngine,
                child: _PrinterConnectionNotifier(
                  authViewModel: _dependencies.authViewModel,
                  printingSettingsViewModel:
                      _dependencies.printingSettingsViewModel,
                  child: PointyNavigationRailScope(
                    isActive: false,
                    controller: _navigationRailController,
                    navigationScrollStore: _navigationScrollStore,
                    // Above the Navigator, not inside `home`: pushed routes are
                    // siblings of the first route, so a scope installed there
                    // would be invisible to every screen but the first.
                    child: ValueListenableBuilder<CameraWedgeController?>(
                      valueListenable: _dependencies.cameraWedgeListenable,
                      builder: (context, wedge, companionChild) =>
                          CameraWedgeScope(
                            controller: wedge,
                            child: companionChild ?? const SizedBox.shrink(),
                          ),
                      child: ValueListenableBuilder<CompanionBridge?>(
                        valueListenable:
                            _dependencies.companionBridgeListenable,
                        builder: (context, bridge, railChild) => CompanionScope(
                          bridge: bridge,
                          repository: _dependencies.companionRepository,
                          // Same reasoning, one level in: every screen that shows a
                          // document can offer its history without a constructor
                          // parameter for it.
                          child: DocumentTrailScope(
                            repository: _dependencies.documentTrailRepository,
                            // And one more: the till, the record-payment dialog
                            // and the settings screen all need to know which
                            // bank account a card or transfer lands in.
                            child: BankRoutingScope(
                              routing: _dependencies.bankRouting,
                              // Per device, like the theme: the product
                              // searches on every route read whether this
                              // machine offers the search-mode picker.
                              child: ProductSearchModeScope(
                                controller:
                                    _dependencies.productSearchModeController,
                                child: railChild ?? const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
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
    // Watches the receipt printer: the one a sale waits on.
    final endpoint = widget.printingSettingsViewModel.receiptPrinter?.endpoint;
    final endpointKey = endpoint == null
        ? ''
        : '${endpoint.kind.name}:${endpoint.address}:${endpoint.port}';
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
