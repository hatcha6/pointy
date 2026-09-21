import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'pointy_navigation_rail_scope.dart';

/// The navigation surfaces that can hold a scroll offset of their own.
///
/// All three list the same destinations, but at three densities: the compact
/// drawer's roomy tiles, the extended rail's dense ones, and the collapsed
/// rail's bare icons. One shared number would mean a different place in each,
/// so each keeps its own.
enum PointyNavigationSurfaceKind { drawer, railExtended, railCollapsed }

/// Where the navigation list's scroll offset lives — one value per surface,
/// for the life of the app.
///
/// Every screen builds its own drawer/rail inside its own route, so several
/// navigation lists are alive at once: the one on show, plus one for every
/// route still on the stack beneath it. [PageStorage], which this replaces,
/// only ever reached a list at the moment it was built. The lists underneath
/// kept whatever offset they happened to hold when they were last on show, so
/// going back — the back button, and choosing the dashboard, which pops to the
/// first route — put a stale offset back on screen, and the next screen opened
/// from there restored the offset of the screen *before* it. The rail
/// oscillated between two remembered places instead of staying where the user
/// left it.
///
/// This store is the single source of truth instead: a list records its offset
/// here while the user scrolls it, and reads it back whenever it comes on show.
class PointyNavigationScrollStore {
  final Map<PointyNavigationSurfaceKind, double> _offsets =
      <PointyNavigationSurfaceKind, double>{};

  double offsetOf(PointyNavigationSurfaceKind kind) => _offsets[kind] ?? 0;

  void record(PointyNavigationSurfaceKind kind, double offset) {
    if (!offset.isFinite) {
      return;
    }
    _offsets[kind] = math.max(0, offset);
  }
}

/// A navigation list that opens where the navigation was last left — on every
/// screen, and however that screen was reached.
///
/// Hands [builder] the [ScrollController] the list must use. The offset comes
/// from the [PointyNavigationScrollStore] on the nearest
/// [PointyNavigationRailScope] (every PointyScaffold provides one), and is
/// re-applied whenever this list comes back on show — which is the only way a
/// route that was kept alive underneath another one can catch up with a scroll
/// that happened while it was hidden.
class PointyNavigationScrollView extends StatefulWidget {
  const PointyNavigationScrollView({
    super.key,
    required this.kind,
    required this.builder,
  });

  final PointyNavigationSurfaceKind kind;
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<PointyNavigationScrollView> createState() =>
      _PointyNavigationScrollViewState();
}

class _PointyNavigationScrollViewState
    extends State<PointyNavigationScrollView> {
  /// Used when no shell provides one (previews, isolated widget tests): the
  /// list then simply keeps its own offset, as any list does.
  final PointyNavigationScrollStore _fallbackStore =
      PointyNavigationScrollStore();

  late PointyNavigationScrollStore _store;
  late ScrollController _controller;
  bool _hasController = false;

  /// Whether this list is the one the user can see. A route kept alive under
  /// another one is built and holds a live scroll position, but nobody is
  /// scrolling it, so it must neither record nor be trusted.
  bool _onShow = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store =
        PointyNavigationRailScope.maybeOf(context)?.navigationScrollStore ??
        _fallbackStore;
    if (!_hasController || !identical(store, _store)) {
      _store = store;
      _resetController();
    }
    // Reading the ticker mode subscribes this element to it, so this runs
    // again the moment the route above is popped and this screen is on show
    // once more — the [Overlay] turns tickers off for the routes it keeps
    // alive out of sight.
    final onShow = TickerMode.of(context);
    final cameBackOnShow = onShow && !_onShow;
    _onShow = onShow;
    if (cameBackOnShow) {
      _scheduleRestore();
    }
  }

  @override
  void didUpdateWidget(PointyNavigationScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _resetController();
    }
  }

  @override
  void dispose() {
    if (_hasController) {
      _controller.removeListener(_recordOffset);
      _controller.dispose();
    }
    super.dispose();
  }

  void _resetController() {
    if (_hasController) {
      final previous = _controller;
      previous.removeListener(_recordOffset);
      // The list is still attached to it for the rest of this build; let it
      // detach before the controller goes.
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    _controller = ScrollController(
      initialScrollOffset: _store.offsetOf(widget.kind),
      // The offset belongs to the store, not to this route's PageStorage.
      keepScrollOffset: false,
    )..addListener(_recordOffset);
    _hasController = true;
  }

  void _recordOffset() {
    if (!_onShow || !_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) {
      return;
    }
    final pixels = position.pixels;
    // A screen whose rail has less room than the one the offset came from
    // sits pinned at its own bottom. Recording that would cut the offset down
    // for every taller screen, so leave the stored one where it is.
    if (pixels >= position.maxScrollExtent - precisionErrorTolerance &&
        _store.offsetOf(widget.kind) > position.maxScrollExtent) {
      return;
    }
    _store.record(widget.kind, pixels);
  }

  void _scheduleRestore() {
    // Jumping now would move a list in the middle of the build that revealed
    // it, and would fire scroll notifications into widgets already built this
    // frame. The next frame is soon enough: the route is still animating in.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _restoreOffset();
    });
  }

  void _restoreOffset() {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) {
      return;
    }
    final target = _store
        .offsetOf(widget.kind)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((position.pixels - target).abs() < precisionErrorTolerance) {
      return;
    }
    position.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    // Scrolling the navigation is the navigation's own business: without this
    // the rail's notifications reach the screen's [Scaffold], whose app bar
    // treats them as its content scrolling under it.
    return NotificationListener<ScrollNotification>(
      onNotification: (_) => true,
      // Keyed on the surface, so switching between the extended and the
      // collapsed rail builds a new list rather than handing the old one a new
      // controller: a [Scrollable] that is merely updated keeps the scroll
      // position it already has, and the collapsed rail would open at a number
      // that means somewhere else.
      child: KeyedSubtree(
        key: ValueKey(widget.kind),
        child: widget.builder(context, _controller),
      ),
    );
  }
}
