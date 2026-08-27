import 'package:flutter/material.dart';

import 'analytics_engine.dart';

/// How a screen came to be the current one.
enum ScreenEntry {
  /// Mounted for the first time — pushed, replaced, or swapped in.
  opened,

  /// Already on the stack; whatever was pushed on top of it went away.
  returned,
}

/// The navigator observer [TrackedScreen] listens to. One per app, handed to
/// `MaterialApp.navigatorObservers` and to [AnalyticsScreenScope].
class AnalyticsRouteObserver extends RouteObserver<ModalRoute<dynamic>> {}

/// Makes the engine and the route observer reachable from any [TrackedScreen]
/// without threading them through every screen constructor.
///
/// Absent in tests that don't care, and [TrackedScreen] then does nothing.
class AnalyticsScreenScope extends InheritedWidget {
  const AnalyticsScreenScope({
    super.key,
    required this.analyticsEngine,
    required this.routeObserver,
    required super.child,
  });

  final AnalyticsEngine? analyticsEngine;
  final AnalyticsRouteObserver routeObserver;

  static AnalyticsScreenScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AnalyticsScreenScope>();
  }

  @override
  bool updateShouldNotify(AnalyticsScreenScope oldWidget) {
    return analyticsEngine != oldWidget.analyticsEngine ||
        routeObserver != oldWidget.routeObserver;
  }
}

/// Marks its subtree as one named screen, and keeps
/// [AnalyticsEngine.setCurrentScreen] pointing at whichever screen the user is
/// actually looking at.
///
/// ## Why this exists
///
/// Screen attribution used to be a side effect inside `build`: each route
/// builder called `setCurrentScreen` as it constructed its widget. That is
/// wrong in both directions.
///
/// *Nothing put it back on the way out.* Leaving the POS for the invoice list
/// set the screen to `invoices`; popping back to the POS did not set it back,
/// because a route underneath is already built and its builder never runs
/// again. Every barcode scan the cashier made afterwards was filed under
/// `invoices` — which is how a selling screen's work ended up attributed to a
/// screen nobody sells from.
///
/// *And it fired at times that were not navigation at all.* The home screen is
/// built directly by `AuthenticatedHome.build`, so any rebuild of it reset the
/// screen to `pos`/`dashboard` even while the user stood on a pushed route.
///
/// So: set it when the screen is mounted, and set it again when the route above
/// it is popped ([RouteAware.didPopNext]). Both are real navigation; a rebuild
/// is not, and no longer counts as one.
///
/// Nest at most one of these per route. Nested trackers are not *wrong* —
/// ancestors subscribe before descendants and the observer notifies in
/// subscription order, so the innermost (most specific) screen wins — but each
/// one fires its own [onEnter], so two on one route means two view events.
class TrackedScreen extends StatefulWidget {
  const TrackedScreen({
    super.key,
    required this.name,
    required this.child,
    this.onEnter,
  });

  final String name;
  final Widget child;

  /// Called on each entry, so a caller can record its own event alongside.
  final void Function(String name, ScreenEntry entry)? onEnter;

  @override
  State<TrackedScreen> createState() => _TrackedScreenState();
}

class _TrackedScreenState extends State<TrackedScreen> with RouteAware {
  AnalyticsScreenScope? _scope;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AnalyticsScreenScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (scope == _scope && route == _route) {
      return;
    }
    _scope?.routeObserver.unsubscribe(this);
    _scope = scope;
    _route = route;
    if (scope != null && route != null) {
      // subscribe() calls didPush() straight away when this is the top route,
      // so a freshly pushed screen is recorded here rather than needing its own
      // initState path.
      scope.routeObserver.subscribe(this, route);
    } else {
      // No route to observe (the auth screens swap inside one route). Mounting
      // is the only entry signal there is.
      _enter(ScreenEntry.opened);
    }
  }

  @override
  void didUpdateWidget(TrackedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.name != oldWidget.name) {
      _enter(ScreenEntry.opened);
    }
  }

  @override
  void dispose() {
    _scope?.routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() => _enter(ScreenEntry.opened);

  @override
  void didPopNext() => _enter(ScreenEntry.returned);

  void _enter(ScreenEntry entry) {
    _scope?.analyticsEngine?.setCurrentScreen(widget.name);
    widget.onEnter?.call(widget.name, entry);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
