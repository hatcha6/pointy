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
import 'features/auth/views/auth_gate.dart';

class PointyApp extends StatefulWidget {
  const PointyApp({super.key, this.apiService});

  final PosApiService? apiService;

  @override
  State<PointyApp> createState() => _PointyAppState();
}

class _PointyAppState extends State<PointyApp> {
  late final PointyAppDependencies _dependencies;
  void Function(FlutterErrorDetails details)? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;
  late final TimingsCallback _frameTimingsCallback;

  @override
  void initState() {
    super.initState();
    _dependencies = PointyAppDependencies(apiService: widget.apiService);
    _dependencies.authViewModel.addListener(_dependencies.handleAuthChanged);
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
      builder: (context, child) => AnalyticsInteractionTracker(
        analyticsEngine: _dependencies.analyticsEngine,
        child: child ?? const SizedBox.shrink(),
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

    return AuthenticatedHome(
      dependencies: _dependencies,
      currentUser: currentUser,
    );
  }
}
