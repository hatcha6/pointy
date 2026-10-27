import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/generated/app_localizations.dart';
import 'dependencies.dart';
import 'design/cards_theme.dart';
import 'features/links/link_inbox.dart';
import 'features/onboarding/first_run.dart';
import 'features/shell/cards_shell.dart';
import 'features/splash/splash_handoff.dart';
import 'features/splash/splash_overlay.dart';
import 'shared/cards_scope.dart';

/// «دفتر كروت»: Arabic and right to left unless the customer picks English
/// or French, light or dark as they choose or as the phone is set.
class CardsApp extends StatelessWidget {
  const CardsApp({
    super.key,
    required this.dependencies,
    this.home,
    this.themeMode,
    this.splash,
    this.overlay,
  });

  final CardsDependencies dependencies;

  /// Replaces the shell: the preview harness renders single surfaces.
  final Widget? home;

  /// The customer's choice by default; the preview harness forces one.
  final ThemeMode? themeMode;

  /// The opening to play over the app as it starts; none in tests.
  final SplashOpening? splash;

  /// Draws over every screen, sheets included: the preview harness's
  /// controls. None in the app.
  final TransitionBuilder? overlay;

  @override
  Widget build(BuildContext context) {
    final settings = dependencies.settings;
    return CardsScope(
      dependencies: dependencies,
      child: LinkListener(
        inbox: dependencies.links,
        child: _Home(
          home: home,
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => MaterialApp(
              onGenerateTitle: (context) =>
                  AppLocalizations.of(context).appTitle,
              debugShowCheckedModeBanner: false,
              locale: settings.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: CardsTheme.light(),
              darkTheme: CardsTheme.dark(),
              themeMode: themeMode ?? settings.themeMode,
              scrollBehavior: const _CardsScrollBehavior(),
              navigatorObservers: [?dependencies.analytics.observer],
              builder: (context, child) {
                var app = child!;
                if (overlay != null) {
                  app = overlay!(context, app);
                }
                if (splash != null) {
                  app = _WithSplash(opening: splash!, child: app);
                }
                return dependencies.analytics.wrap(app);
              },
              // The app always starts on its shell. A link it was opened with
              // waits in [LinkInbox] for the shell rather than naming a route.
              onGenerateInitialRoutes: (_) => [_shellRoute()],
              onGenerateRoute: (settings) =>
                  settings.name == Navigator.defaultRouteName
                  ? _shellRoute()
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Route<void> _shellRoute() => MaterialPageRoute<void>(
    settings: const RouteSettings(name: Navigator.defaultRouteName),
    builder: (context) =>
        _Home.of(context) ?? const FirstRun(child: CardsShell()),
  );
}

/// The first page, read by the route as the app rebuilds: a new [home]
/// replaces it, as `MaterialApp.home` would.
class _Home extends InheritedWidget {
  const _Home({required this.home, required super.child});

  final Widget? home;

  static Widget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Home>()!.home;

  @override
  bool updateShouldNotify(_Home oldWidget) => oldWidget.home != home;
}

/// The app with the opening over it until the opening is done.
class _WithSplash extends StatefulWidget {
  const _WithSplash({required this.opening, required this.child});

  final SplashOpening opening;
  final Widget child;

  @override
  State<_WithSplash> createState() => _WithSplashState();
}

class _WithSplashState extends State<_WithSplash> {
  bool _showing = true;

  /// A screen underneath may take the tile (the onboarding does).
  final _handoff = SplashHandoff();

  @override
  void dispose() {
    _handoff.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SplashHandoffScope(handoff: _handoff, child: widget.child),
        if (_showing)
          Positioned.fill(
            child: SplashOverlay(
              run: widget.opening.run,
              art: widget.opening.art,
              handoff: _handoff,
              onDone: () {
                setState(() => _showing = false);
                _handoff.land();
              },
            ),
          ),
      ],
    );
  }
}

/// A mouse drags what a finger swipes: on a desktop the onboarding's pages
/// and a pager of several cards would otherwise not move at all.
class _CardsScrollBehavior extends MaterialScrollBehavior {
  const _CardsScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
