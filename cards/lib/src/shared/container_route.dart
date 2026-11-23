import 'dart:math' as math;

import 'package:animations/animations.dart';
import 'package:flutter/cupertino.dart' show CupertinoRouteTransitionMixin;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import '../design/cards_tokens.dart';

/// What a page opens out of: a card on a shelf, a row of a list. It is what
/// grows into the page: the page's container starts as this very widget, at
/// its place and size, and enlarges from there; and it is what the page
/// shrinks back into. Its own place stands empty meanwhile.
class ContainerSource extends StatefulWidget {
  const ContainerSource({super.key, required this.child, this.backing});

  /// A whole row or card marks its picture inside with a [ContainerHero].
  final Widget child;

  /// What it stands on where it is (a row's card), for a source with no
  /// ground of its own: on its way it is drawn over this, not over whatever
  /// it passes.
  final Color? backing;

  /// The source at or above [context], else the one inside it: a tile may
  /// be tapped as a whole while only its artwork is the source.
  ///
  /// [context] must be the tapped tile's own. Under a context shared by
  /// several tiles (a list's `itemBuilder` one) there is more than one source
  /// inside it and no telling which was tapped: none is chosen, rather than
  /// the first, which would open the page out of the wrong tile.
  static ContainerSourceState? find(BuildContext context) {
    final above = context.findAncestorStateOfType<ContainerSourceState>();
    if (above != null || context is! Element) {
      return above;
    }
    final found = <ContainerSourceState>[];
    void visit(Element element) {
      if (found.length > 1) {
        return;
      }
      if (element is StatefulElement && element.state is ContainerSourceState) {
        found.add(element.state as ContainerSourceState);
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildren(visit);
    assert(
      found.length < 2,
      'openContainer was given a context with several ContainerSources '
      "inside it. Pass the tapped tile's own context.",
    );
    return found.length == 1 ? found.single : null;
  }

  @override
  State<ContainerSource> createState() => ContainerSourceState();
}

/// The picture inside a [ContainerSource] that is a whole row or card (its
/// flag, its card art): what the page's [ContainerLanding] is the page's own
/// copy of. The page still opens out of the whole row, but it is this that
/// goes to the landing, from its own place in the row (at the row's start,
/// say), while the rest of the row stays where it is and fades.
class ContainerHero extends StatelessWidget {
  const ContainerHero({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final flown =
        context.dependOnInheritedWidgetOfExactType<_HeroFlown>()?.flown ??
        false;
    return Visibility(
      visible: !flown,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: child,
    );
  }
}

/// Over the route's copy of a source: whether its [ContainerHero] has left
/// its place in it (it is drawn apart, on its way to the landing).
class _HeroFlown extends InheritedWidget {
  const _HeroFlown({required this.flown, required super.child});

  final bool flown;

  @override
  bool updateShouldNotify(_HeroFlown old) => old.flown != flown;
}

/// Sets [notifier] now, or once the frame ends when a build is under way.
void _setWhenAllowed(State state, ValueNotifier<bool> notifier, bool value) {
  if (!state.mounted || notifier.value == value) {
    return;
  }
  if (SchedulerBinding.instance.schedulerPhase !=
      SchedulerPhase.persistentCallbacks) {
    notifier.value = value;
  } else {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (state.mounted) {
        notifier.value = value;
      }
    });
  }
}

/// [child], or its empty place while it is [away].
Widget _placeOf(ValueNotifier<bool> away, Widget child) =>
    ValueListenableBuilder<bool>(
      valueListenable: away,
      builder: (context, away, child) => Visibility(
        visible: !away,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: child!,
      ),
      child: child,
    );

class ContainerSourceState extends State<ContainerSource> {
  final _away = ValueNotifier(false);

  /// Leaves its place empty ([away]) while its page is open, and fills it
  /// again as the page lands.
  ///
  /// Never set in the middle of a build (the page's first painted frame, a
  /// route let go of as the tree is torn down): then it waits for the frame
  /// to end. At any other moment it is at once, so the frame that drops the
  /// page is the frame that shows this again.
  set away(bool away) => _setWhenAllowed(this, _away, away);

  @override
  void dispose() {
    _away.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _placeOf(_away, widget.child);
}

/// Where the source lands in the page it opens: the page's own copy of the
/// same thing (a brand's card at the top of its page). The source, enlarging
/// with the container, glides onto it; there the page's own takes its place,
/// in the same frame and the same spot, and the rest of the page fades in
/// around it. It is one card from the shelf to the page and back.
class ContainerLanding extends StatefulWidget {
  const ContainerLanding({
    super.key,
    required this.child,
    this.radius = CardsRadii.tile,
    this.same = true,
    this.arriving,
  });

  final Widget child;

  /// What is drawn of it over a source that turns into it, where [child]
  /// itself cannot be drawn twice (it holds a key, or state of its own).
  final Widget? arriving;

  /// Its corner, for the window the page's cover leaves over it.
  final double radius;

  /// Whether it is the very picture the source is (a brand's card on the
  /// shelf and on its page): then the source simply arrives and this takes
  /// over from it. Where it only stands for the same thing (a muted card, a
  /// destination's banner where the source is a flag), it is drawn over the
  /// source as the source glides here, clearer and clearer, so the one turns
  /// into the other on the way with a picture there at every moment.
  final bool same;

  @override
  State<ContainerLanding> createState() => _ContainerLandingState();
}

class _ContainerLandingState extends State<ContainerLanding> {
  ContainerPageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ContainerPageRoute && route != _route) {
      _route = route.._landing = this;
    }
  }

  @override
  void dispose() {
    if (_route?._landing == this) {
      _route?._landing = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Material's container transform (the `animations` package's
/// `OpenContainer`) as a real page route: the thing tapped grows into the
/// page, and the page shrinks back into it.
///
/// `OpenContainer` itself cannot be used where the system's back gestures
/// matter: its route is private and is not a page route, so it answers
/// neither the iOS edge swipe nor Android's predictive back. This route
/// answers both, and the gesture drives the transform itself: the page
/// shrinks towards where it came from as the finger moves, goes back there on
/// release, and grows back if the gesture is called off. A back button or a
/// `pop` plays it from start to end.
///
/// How it looks goes by the container's size, not by the clock. It starts as
/// the source itself, drawn again inside the container (the same widget, so
/// the same pixels under any renderer), which enlarges with it and fades;
/// the page shows inside only once the container has grown well clear of the
/// source's size, and is covered again before it has shrunk back to it. So
/// the page is never seen squeezed into the tile, and the tile is never seen
/// stretched over the page, whatever curve or finger is moving it.
///
/// Built to cost little per frame: the page is laid out once at its full
/// size and only scaled; it keeps one place in the tree from the push to the
/// pop, so nothing is rebuilt as a gesture starts or ends; it never fades
/// through an offscreen layer (it shows from under a cover that thins); and
/// while the cover is whole it is not painted at all.
class ContainerPageRoute<T> extends MaterialPageRoute<T> {
  ContainerPageRoute({
    required BuildContext from,
    required super.builder,
    super.settings,
    this.radius = CardsRadii.card,
  }) : _source = ContainerSource.find(from),
       _tapped = from {
    final source = _source;
    if (source != null) {
      // The source again, for inside the container, under the styles it
      // stands under where it is.
      final navigator = Navigator.of(source.context).context;
      _closed = InheritedTheme.captureAll(
        source.context,
        source.widget.child,
        to: navigator,
      );
      final hero = _hero = _heroIn(source.context);
      if (hero != null) {
        _heroCopy = InheritedTheme.captureAll(
          hero,
          (hero.widget as ContainerHero).child,
          to: navigator,
        );
      }
    }
    _rect = _measure();
  }

  static Element? _heroIn(BuildContext source) {
    Element? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element.widget is ContainerHero) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    source.visitChildElements(visit);
    return found;
  }

  /// The source's [ContainerHero], where it marks one; that picture again,
  /// for its way to the landing; and where it stands in the source.
  Element? _hero;
  Widget? _heroCopy;
  Rect? _heroAt;

  /// The thing tapped, and its [ContainerSource] where it has one.
  final BuildContext _tapped;
  final ContainerSourceState? _source;

  /// The source while it is still in the tree, else what was tapped. A
  /// source can leave while its page is up (the list under it rebuilt), and
  /// a disposed [State] has no context to ask.
  BuildContext get _from {
    final source = _source;
    return source != null && source.mounted ? source.context : _tapped;
  }

  Widget? _closed;
  Rect? _rect;

  /// The page's [ContainerLanding], when it has one.
  _ContainerLandingState? _landing;

  /// The landing again, for over the source as it arrives: under the styles
  /// it stands under in the page.
  Widget? _arriving() {
    final landing = _landing;
    final navigator = this.navigator;
    if (landing == null || !landing.mounted || navigator == null) {
      return null;
    }
    final child = landing.widget.arriving ?? landing.widget.child;
    if (!identical(child, _arrivingOf)) {
      _arrivingOf = child;
      _arrivingCopy = InheritedTheme.captureAll(
        landing.context,
        child,
        to: navigator.context,
      );
    }
    return _arrivingCopy;
  }

  Widget? _arrivingOf;
  Widget? _arrivingCopy;

  /// The corner of the thing tapped.
  final double radius;

  /// The container itself, for tests to measure.
  @visibleForTesting
  static const boxKey = ValueKey('container-page-route-box');

  /// Where the source stands now, in the navigator's own space. It is asked
  /// again each time the page turns back, so the page lands on the source
  /// where it now is.
  Rect? _measure() {
    if (!_from.mounted) {
      return _rect;
    }
    final box = _from.findRenderObject();
    final navigator = Navigator.maybeOf(_from)?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return _rect;
    }
    final hero = _hero;
    final heroBox = hero != null && hero.mounted
        ? hero.findRenderObject()
        : null;
    if (heroBox is RenderBox && heroBox.attached && heroBox.hasSize) {
      _heroAt =
          heroBox.localToGlobal(Offset.zero, ancestor: box) & heroBox.size;
    }
    return box.localToGlobal(
          Offset.zero,
          ancestor: navigator is RenderBox ? navigator : null,
        ) &
        box.size;
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  void install() {
    super.install();
    // The source stands in its place again the moment the page has landed.
    // (It leaves it as the page first paints: see [_ContainerTransform].)
    animation!.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        _source?.away = false;
      }
    });
  }

  @override
  void dispose() {
    _source?.away = false;
    super.dispose();
  }

  // The page beneath stands still: it does not slide away as it would under
  // the platform's own transition.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => _still;

  /// Whether the page over this one is another of these. The framework hands
  /// a page beneath the transition of the page above only when the two differ,
  /// so one of these under another was left to the platform's own: it slid a
  /// third of the screen aside, and the page above, on its way back, measured
  /// its source there and landed beside it. Under another of these, this one
  /// stands still by its own doing.
  bool _underAnother = false;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    _underAnother = nextRoute is ContainerPageRoute;
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _underAnother = nextRoute is ContainerPageRoute;
    super.didPopNext(nextRoute);
  }

  static Widget? _still(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    final platform = Theme.of(context).platform;
    if (_underAnother) {
      secondaryAnimation = kAlwaysDismissedAnimation;
    }
    Widget page = _ContainerTransform(route: this, child: child);
    if (platform == TargetPlatform.iOS) {
      // The system's edge swipe, without its slide: the finger moves this
      // route's own animation, which is the transform above. When another
      // page opens over this one, it slides aside as any page does.
      return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        this,
        context,
        kAlwaysCompleteAnimation,
        secondaryAnimation,
        page,
      );
    }
    page = SharedAxisTransition(
      animation: kAlwaysCompleteAnimation,
      secondaryAnimation: secondaryAnimation,
      transitionType: SharedAxisTransitionType.scaled,
      fillColor: Colors.transparent,
      child: page,
    );
    return platform == TargetPlatform.android && !kIsWeb
        ? _PredictiveBack(route: this, child: page)
        : page;
  }
}

/// Opens [builder]'s page out of the widget at [from]: its [ContainerSource]
/// where it has one, else the widget itself.
Future<T?> openContainer<T>(
  BuildContext context, {
  required BuildContext from,
  required WidgetBuilder builder,
  RouteSettings? settings,
  double radius = CardsRadii.card,
}) => Navigator.of(context).push<T>(
  ContainerPageRoute<T>(
    from: from,
    builder: builder,
    settings: settings,
    radius: radius,
  ),
);

/// The route a page opens with: out of [from] where the page was opened from
/// something on screen, else the platform's own.
PageRoute<T> routeFrom<T>(
  BuildContext? from, {
  required WidgetBuilder builder,
  RouteSettings? settings,
}) => from == null
    ? MaterialPageRoute<T>(builder: builder, settings: settings)
    : ContainerPageRoute<T>(from: from, builder: builder, settings: settings);

class _ContainerTransform extends StatefulWidget {
  const _ContainerTransform({required this.route, required this.child});

  final ContainerPageRoute<dynamic> route;
  final Widget child;

  @override
  State<_ContainerTransform> createState() => _ContainerTransformState();
}

class _ContainerTransformState extends State<_ContainerTransform> {
  Animation<double> get _animation => widget.route.animation!;

  /// The page at its full size: what its [ContainerLanding] is measured in.
  final _pageRoot = GlobalKey();

  /// Where the page's landing stands in the page, or none.
  Rect? _landing() {
    final landing = widget.route._landing;
    final root = _pageRoot.currentContext?.findRenderObject();
    if (landing == null || !landing.mounted || root is! RenderBox) {
      return null;
    }
    final box = landing.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero, ancestor: root) & box.size;
  }

  /// The first moment ([t]) the container, growing from [from] to [full],
  /// holds the whole of [landing]: before it the page's own copy would be cut
  /// by the container's edge.
  static double _handover(Rect from, Rect landing, Rect full) {
    double needs(double start, double end, double mark) {
      // An edge going from [start] to [end] passes [mark] at this fraction.
      final way = end - start;
      return way == 0 ? 0 : ((mark - start) / way).clamp(0.0, 1.0);
    }

    var t = 0.0;
    if (from.left > landing.left) {
      t = math.max(t, needs(from.left, full.left, landing.left));
    }
    if (from.top > landing.top) {
      t = math.max(t, needs(from.top, full.top, landing.top));
    }
    if (from.right < landing.right) {
      t = math.max(t, needs(from.right, full.right, landing.right));
    }
    if (from.bottom < landing.bottom) {
      t = math.max(t, needs(from.bottom, full.bottom, landing.bottom));
    }
    // A little past it, for the landing's shadow; never so early that the
    // source has no way to go, nor so late that the page has no time.
    return (t + 0.04).clamp(0.4, 0.9);
  }

  /// A finger is moving the page, or has just let go of it: the page keeps
  /// pace with the finger, and with the same pace to the end, so it never
  /// jumps as the finger lifts.
  bool _held = false;

  @override
  void initState() {
    super.initState();
    _animation.addStatusListener(_turned);
  }

  @override
  void dispose() {
    _animation.removeStatusListener(_turned);
    super.dispose();
  }

  void _turned(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      widget.route._rect = widget.route._measure();
    }
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final surface = Theme.of(context).scaffoldBackgroundColor;
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = Offset.zero & constraints.biggest;
        // Laid out once, at its full size, and never moved or scaled: the
        // container opens over it like a window, so everything in it is
        // where it will be from the first frame it shows.
        final page = SizedBox.fromSize(
          key: _pageRoot,
          size: full.size,
          child: widget.child,
        );
        return AnimatedBuilder(
          animation: _animation,
          child: page,
          builder: (context, page) {
            final value = _animation.value;
            final open = _animation.isCompleted;
            if (open || _animation.isDismissed) {
              _held = false;
            } else if (route.popGestureInProgress && !_held) {
              _held = true;
              route._rect = route._measure();
            }
            // The source leaves its place only once the page is painted over
            // it. A pushed page's first frame is built unseen, and the source
            // gone a frame early would leave a hole for that frame.
            if (!route.offstage && !_animation.isDismissed) {
              route._source?.away = true;
            }
            final t = _held ? value : Curves.fastOutSlowIn.transform(value);
            final from = route._rect;
            final box = from == null ? full : Rect.lerp(from, full, t)!;
            final corner = BorderRadius.circular(
              from == null ? 0 : route.radius * (1 - t),
            );
            // All of it goes by the container's size ([t]), not the clock.
            final closed = from == null ? null : route._closed;
            final landing = closed == null ? null : _landing();
            final same = route._landing?.widget.same ?? true;
            // What goes to the landing: the source's marked picture, from
            // its own place in the source, where it marks one; else the
            // source itself.
            final heroAt = landing == null || route._heroCopy == null
                ? null
                : route._heroAt;
            final flies = heroAt != null;
            final flyer = flies ? heroAt.shift(from!.topLeft) : from;
            // Where the page takes over from the source. The two are never
            // painted in the same frame: under the iPhone's renderer a page
            // painted with the source over it came out over the source on
            // the way back. With a landing, that moment is the first at
            // which the container holds the whole landing, so the page's
            // own is never cut by the container's edge as it takes over.
            final handover = landing == null
                ? 0.28
                : _handover(from!, landing, full);
            final sourced = closed != null && t < handover;
            // It rides in the container: its middle keeps a place in the
            // container that goes from where it starts in it (the middle,
            // for a source that is the container; its own place in the row,
            // for a row's picture) to where its landing's middle is in the
            // container at the handover; its size goes from its own to its
            // landing's. It moves as the container moves, is always inside
            // it, and arrives on its landing slowing down.
            final ride = Curves.easeOut.transform(
              (t / handover).clamp(0.0, 1.0),
            );
            var sourceBox = Rect.zero;
            if (sourced) {
              if (landing == null) {
                // It fills the container's width, and grows with it.
                sourceBox =
                    box.topLeft &
                    Size(box.width, box.width * from!.height / from.width);
              } else {
                final then = Rect.lerp(from, full, handover)!;
                final place = Offset.lerp(
                  Offset(
                    (flyer!.center.dx - from!.left) / from.width,
                    (flyer.center.dy - from.top) / from.height,
                  ),
                  Offset(
                    (landing.center.dx - then.left) / then.width,
                    (landing.center.dy - then.top) / then.height,
                  ),
                  ride,
                )!;
                sourceBox = Rect.fromCenter(
                  center:
                      box.topLeft +
                      Offset(place.dx * box.width, place.dy * box.height),
                  width: flyer.width + (landing.width - flyer.width) * ride,
                  height: flyer.height + (landing.height - flyer.height) * ride,
                );
              }
            }
            // With no landing it fades as it enlarges, over the container's
            // whole surface: that surface's colour drawn over it is the same
            // fade, with no offscreen layer.
            final faded = !sourced || landing != null
                ? 0.0
                : ((t - 0.03) / 0.25).clamp(0.0, 1.0);
            // The rest of a row whose picture has left it stays where it is
            // and is gone early, as the container's surface comes in.
            final rest = 1 - ((t - 0.02) / 0.2).clamp(0.0, 1.0);
            // On a landing that is not its very picture (a banner, where it
            // is a flag), the landing itself is drawn over it as it goes,
            // clearer and clearer: well before it arrives it is the landing,
            // which the page's own then takes over from.
            final arriving = landing == null || same ? null : route._arriving();
            final arrived = ((ride - 0.1) / 0.6).clamp(0.0, 1.0);
            final landingCorner = landing == null
                ? 0.0
                : (route._landing?.widget.radius ?? 0) * ride;
            // The container's own surface comes in as it grows clear of the
            // source, and goes as it shrinks back to it: near the source
            // there is no box around it, only the source.
            final surfaced = from == null
                ? t
                : Curves.easeOut.transform((t / 0.3).clamp(0.0, 1.0));
            // The page, from under that surface, once the source has gone:
            // the surface thins, and leaves a window over the landing from
            // the start, so the card that just arrived is never dimmed.
            final cover = t <= handover
                ? surfaced
                : (1 - (t - handover) / ((1 - handover) * 0.9)).clamp(0.0, 1.0);
            final window = t > handover && landing != null
                ? RRect.fromRectAndRadius(
                    landing,
                    Radius.circular(route._landing?.widget.radius ?? 0),
                  )
                : null;
            // The same widgets at every moment, the page among them: what
            // changes from frame to frame is only their figures.
            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: open
                          ? Colors.transparent
                          : Colors.black.withValues(alpha: 0.28 * t),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: box,
                  child: DecoratedBox(
                    key: ContainerPageRoute.boxKey,
                    decoration: BoxDecoration(
                      borderRadius: corner,
                      boxShadow: open || from == null
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: 0.2 * surfaced,
                                ),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                    ),
                    child: ClipRRect(
                      borderRadius: corner,
                      clipBehavior: open ? Clip.none : Clip.antiAlias,
                      child: Stack(
                        clipBehavior: open ? Clip.none : Clip.hardEdge,
                        children: [
                          // Where it will be, whatever the container's place
                          // and size; not painted at all under a whole
                          // cover.
                          Positioned(
                            left: -box.left,
                            top: -box.top,
                            width: full.width,
                            height: full.height,
                            child: Opacity(
                              opacity: t > handover ? 1 : 0,
                              child: page,
                            ),
                          ),
                          Positioned(
                            left: -box.left,
                            top: -box.top,
                            width: full.width,
                            height: full.height,
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _CoverPainter(
                                  color: surface.withValues(alpha: cover),
                                  window: window,
                                  // Only the container's own part of it.
                                  within: box,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // A row whose picture goes to the landing by itself: the rest
                // of it, in its place, with the picture's own place empty.
                if (closed != null && route._heroCopy != null)
                  Positioned.fromRect(
                    rect: from!,
                    child: Offstage(
                      offstage: !sourced || !flies || rest == 0,
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: Opacity(
                            opacity: rest,
                            child: !flies
                                ? const SizedBox.shrink()
                                : Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (route._source?.widget.backing
                                          case final backing?)
                                        ColoredBox(color: backing),
                                      Material(
                                        type: MaterialType.transparency,
                                        child: _HeroFlown(
                                          flown: true,
                                          child: closed,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // The source, over it all. Kept in the tree all along, shown
                // or not, so it is never built afresh on the way back.
                if (closed != null)
                  Positioned.fromRect(
                    rect: sourceBox,
                    child: Offstage(
                      offstage: !sourced,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(landingCorner),
                        clipBehavior: landingCorner > 0
                            ? Clip.antiAlias
                            : Clip.none,
                        child: IgnorePointer(
                          child: ExcludeSemantics(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // At its own size, scaled into its box: it
                                // enlarges, it is never laid out again. It
                                // keeps its own shape: where its landing has
                                // another, it fills that and is cut to it.
                                if (route._source?.widget.backing
                                    case final backing? when !flies)
                                  ColoredBox(color: backing),
                                FittedBox(
                                  // Never blown up past its landing's
                                  // width: a row that lands on a taller
                                  // banner keeps its size as the box grows.
                                  // A row's picture that turns into
                                  // another (a round flag, into a banner)
                                  // stays whole as it does.
                                  fit: flies && !same
                                      ? BoxFit.contain
                                      : landing != null &&
                                            flyer!.width * landing.height >
                                                landing.width * flyer.height
                                      ? BoxFit.fitWidth
                                      : BoxFit.cover,
                                  clipBehavior: Clip.hardEdge,
                                  child: SizedBox.fromSize(
                                    size: flyer!.size,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Material(
                                          type: MaterialType.transparency,
                                          child: flies
                                              ? route._heroCopy
                                              : closed,
                                        ),
                                        ColoredBox(
                                          color: surface.withValues(
                                            alpha: faded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (arriving != null)
                                  Opacity(
                                    opacity: arrived,
                                    child: FittedBox(
                                      fit: BoxFit.fill,
                                      child: SizedBox.fromSize(
                                        size: landing!.size,
                                        child: Material(
                                          type: MaterialType.transparency,
                                          child: arriving,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The container's surface over the page, with a [window] left clear.
class _CoverPainter extends CustomPainter {
  const _CoverPainter({
    required this.color,
    required this.window,
    required this.within,
  });

  final Color color;
  final RRect? window;

  /// The container's box, in the page's own space: the surface is the
  /// container's, and is not drawn outside it.
  final Rect within;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) {
      return;
    }
    final paint = Paint()..color = color;
    final window = this.window;
    if (window == null) {
      canvas.drawRect(within, paint);
    } else {
      canvas.drawDRRect(
        RRect.fromRectAndRadius(within, Radius.zero),
        window,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      old.color != color || old.window != window || old.within != within;
}

/// Android's predictive back, moving the route's own animation: a back swipe
/// from the screen's edge shrinks the page towards where it came from.
class _PredictiveBack extends StatefulWidget {
  const _PredictiveBack({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_PredictiveBack> createState() => _PredictiveBackState();
}

class _PredictiveBackState extends State<_PredictiveBack>
    with WidgetsBindingObserver {
  /// How far a whole swipe takes the page back: the rest is played when the
  /// finger lets go, as the system's own predictive back does.
  static const _reach = 0.45;

  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    if (backEvent.isButtonEvent ||
        !route.isCurrent ||
        !route.popGestureEnabled) {
      return false;
    }
    _dragging = true;
    route.handleStartBackGesture(progress: 1 - backEvent.progress * _reach);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_dragging) {
      widget.route.handleUpdateBackGestureProgress(
        progress: 1 - backEvent.progress * _reach,
      );
    }
  }

  @override
  void handleCancelBackGesture() {
    if (_dragging) {
      _dragging = false;
      widget.route.handleCancelBackGesture();
    }
  }

  @override
  void handleCommitBackGesture() {
    if (_dragging) {
      _dragging = false;
      widget.route.handleCommitBackGesture();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
