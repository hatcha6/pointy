import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models/analytics_event.dart';
import 'analytics_engine.dart';
import 'analytics_burst_coalescer.dart';

class AnalyticsInteractionTracker extends StatefulWidget {
  const AnalyticsInteractionTracker({
    super.key,
    required this.analyticsEngine,
    required this.child,
    this.keystrokeIdleTimeout = const Duration(milliseconds: 400),
    this.inputIdleTimeout = const Duration(seconds: 4),
    this.inputMaxRunDuration = const Duration(seconds: 60),
    this.scrollIdleTimeout = const Duration(milliseconds: 1200),
    this.scrollMaxRunDuration = const Duration(seconds: 30),
    this.clock,
    this.scheduler,
  });

  final AnalyticsEngine analyticsEngine;
  final Widget child;

  /// How long raw input on one screen may pause before the run counts as over.
  ///
  /// Pointer downs and ups, wheel ticks and focus moves were 46,793 rows in one
  /// field week — 28% of everything the clients sent — and individually none of
  /// them says anything: a `pointer_down` at (154, 130) on `register_sessions`
  /// is not a finding, it is a co-ordinate. What the run says instead is how
  /// much the till was touched, where, and whether the same spot was hit over
  /// and over because nothing happened the first time.
  final Duration inputIdleTimeout;
  final Duration inputMaxRunDuration;

  /// How long a scroll may pause before it counts as a separate gesture.
  ///
  /// One flick of a product grid used to produce a start, a direction, several
  /// updates and an end — five rows describing one movement of one thumb,
  /// 28,143 of them in a week, and the thing anyone actually wants to know
  /// (how far did they have to scroll to find it, did they hit the end) was
  /// spread across all five and joinable from none of them.
  final Duration scrollIdleTimeout;
  final Duration scrollMaxRunDuration;

  /// How long a keyboard run may pause before it counts as finished.
  ///
  /// Individual keystrokes were 1,455,832 rows in the field — half of all
  /// interaction telemetry — and none of them said anything the run did not. A
  /// scanner fires a whole code in a few milliseconds and a person pauses far
  /// longer than this between words, so the boundary lands where a human would
  /// draw it.
  final Duration keystrokeIdleTimeout;
  final DateTime Function()? clock;

  /// Injected together with [clock] so a test drives run boundaries by hand
  /// instead of racing a real timer.
  final Timer Function(Duration, void Function())? scheduler;

  static AnalyticsEngine? maybeOf(BuildContext context) {
    final scope = context
        .getElementForInheritedWidgetOfExactType<_AnalyticsInteractionScope>()
        ?.widget;
    return scope is _AnalyticsInteractionScope ? scope.analyticsEngine : null;
  }

  static void track(
    BuildContext context, {
    required String action,
    required String target,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
  }) {
    final analyticsEngine = maybeOf(context);
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.trackInteraction(
        action: action,
        target: target,
        attributes: attributes,
        metrics: metrics,
      ),
    );
  }

  @override
  State<AnalyticsInteractionTracker> createState() =>
      _AnalyticsInteractionTrackerState();
}

class _AnalyticsInteractionScope extends InheritedWidget {
  const _AnalyticsInteractionScope({
    required this.analyticsEngine,
    required super.child,
  });

  final AnalyticsEngine analyticsEngine;

  @override
  bool updateShouldNotify(_AnalyticsInteractionScope oldWidget) {
    return analyticsEngine != oldWidget.analyticsEngine;
  }
}

/// What a run of keystrokes adds up to.
class _KeystrokeRun {
  _KeystrokeRun({required this.firstKey, required this.firstCategory});

  final String firstKey;
  final String firstCategory;
  String lastKey = '';
  String lastCategory = '';
  int printableCount = 0;
  int repeatCount = 0;

  void absorb({
    required String label,
    required String category,
    required bool printable,
    required bool repeat,
  }) {
    lastKey = label;
    lastCategory = category;
    if (printable) {
      printableCount += 1;
    }
    if (repeat) {
      repeatCount += 1;
    }
  }

  /// A wedge scanner delivers a whole code faster than a hand can type it.
  ///
  /// Deliberately a heuristic on the run's shape rather than a claim: it is a
  /// hint for reading telemetry, not a control-flow decision. The POS has its
  /// own scan detection (ScanBurstGuard) and does not consult this.
  bool looksLikeScan(Duration duration, int count) {
    if (count < 4 || printableCount < 4) {
      return false;
    }
    final perKey = duration.inMilliseconds / count;
    return perKey <= 30;
  }
}

/// What a run of raw input on one screen adds up to.
///
/// The counters are the point. A tap is worth a row only in aggregate; what a
/// run can say that a stream of taps cannot is *how many of those taps landed
/// on the same spot as the one before it* — 21.7% of them did in the field,
/// with 558 runs of three or more. That is a control that did not respond, and
/// it was invisible in 28,531 individual rows because nothing joined them.
class _InputRun {
  _InputRun({required this.screen});

  /// Stamped at emission because the run may outlive the navigation that
  /// started it, and the enricher would bill it to wherever the user ended up.
  final String? screen;

  int presses = 0;
  int releases = 0;
  int cancels = 0;
  int wheelTicks = 0;
  int focusChanges = 0;
  int repeatPresses = 0;
  int maxRepeatRun = 0;
  int _currentRepeatRun = 0;
  double wheelDistance = 0;
  final Set<String> kinds = {};
  double viewportWidth = 0;
  double viewportHeight = 0;

  /// Where the presses landed, as a coarse grid over the viewport.
  ///
  /// Raw coordinates were never once used in a field analysis and cost two
  /// numbers on every event; throwing them away entirely would still be
  /// irreversible, and this keeps the question askable for twelve integers a
  /// run instead.
  static const int gridColumns = 4;
  static const int gridRows = 3;
  final List<int> grid = List<int>.filled(gridColumns * gridRows, 0);

  double? _lastPressX;
  double? _lastPressY;
  DateTime? _lastPressAt;

  /// How near, and how soon, a second press has to be to count as a repeat.
  static const double repeatRadius = 24;
  static const Duration repeatWindow = Duration(milliseconds: 1200);

  void absorbPress({
    required double x,
    required double y,
    required DateTime at,
    required String kind,
  }) {
    presses += 1;
    kinds.add(kind);
    final lastX = _lastPressX;
    final lastY = _lastPressY;
    final lastAt = _lastPressAt;
    final near =
        lastX != null &&
        lastY != null &&
        lastAt != null &&
        at.difference(lastAt) <= repeatWindow &&
        (x - lastX).abs() <= repeatRadius &&
        (y - lastY).abs() <= repeatRadius;
    if (near) {
      repeatPresses += 1;
      _currentRepeatRun = _currentRepeatRun == 0 ? 2 : _currentRepeatRun + 1;
    } else {
      _currentRepeatRun = 1;
    }
    if (_currentRepeatRun > maxRepeatRun) {
      maxRepeatRun = _currentRepeatRun;
    }
    _lastPressX = x;
    _lastPressY = y;
    _lastPressAt = at;
    _recordOnGrid(x, y);
  }

  void absorbViewport(double width, double height) {
    if (width > 0) {
      viewportWidth = width;
    }
    if (height > 0) {
      viewportHeight = height;
    }
  }

  void _recordOnGrid(double x, double y) {
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      return;
    }
    final column = ((x / viewportWidth) * gridColumns).floor().clamp(
      0,
      gridColumns - 1,
    );
    final row = ((y / viewportHeight) * gridRows).floor().clamp(0, gridRows - 1);
    grid[row * gridColumns + column] += 1;
  }
}

/// What one scroll gesture adds up to.
class _ScrollRun {
  _ScrollRun({
    required this.screen,
    required this.axis,
    required this.depth,
    required this.startPixels,
  }) : endPixels = startPixels;

  final String? screen;
  final String axis;
  final int depth;
  final double startPixels;

  double endPixels;
  double distance = 0;
  int updates = 0;
  int reversals = 0;
  String? lastDirection;
  int overscrolls = 0;
  double maxOverscroll = 0;
  int wheelTicks = 0;
  double maxScrollExtent = 0;
  double viewportDimension = 0;
  bool ended = false;

  double get netDelta => endPixels - startPixels;

  /// Whether the gesture ran the list out. A cashier who reaches the bottom of
  /// a catalog did not find what they wanted where they expected it.
  bool get reachedEnd => maxScrollExtent > 0 && endPixels >= maxScrollExtent;

  void absorbMetrics(ScrollMetrics metrics) {
    endPixels = metrics.pixels;
    if (metrics.maxScrollExtent > maxScrollExtent) {
      maxScrollExtent = metrics.maxScrollExtent;
    }
    if (metrics.viewportDimension > viewportDimension) {
      viewportDimension = metrics.viewportDimension;
    }
  }

  void absorbDirection(String direction) {
    // `idle` is the settling between movements, not a change of mind.
    if (direction == 'idle') {
      return;
    }
    if (lastDirection != null && lastDirection != direction) {
      reversals += 1;
    }
    lastDirection = direction;
  }
}

/// The name of the widget that currently holds focus, or null.
///
/// [context] is an Element, and reading `.widget` off one the framework has
/// already unmounted throws: `Element.widget` is a `_widget!` on a field that
/// is nulled at unmount. `?.` guards a *missing* context, not a *defunct* one,
/// and focus lands on a dying node routinely — a route pops, a dialog closes, a
/// list item scrolls out of view. It happens inside a FocusManager microtask,
/// where nothing catches it, so it surfaced as an unhandled "Null check
/// operator used on a null value": 241 of them in the field, from telemetry
/// code that is supposed to be invisible.
/// Stable, build-independent name for a pointer event.
///
/// `runtimeType.toString()` returns the obfuscated symbol in release builds
/// (`flutter build --obfuscate`), so telemetry would carry a different piece of
/// gibberish for the same event on every release and the dashboards would stop
/// aggregating. These strings are the exact names the unobfuscated build
/// produced, so historical data keeps lining up.
String pointerEventName(PointerEvent event) {
  if (event is PointerDownEvent) return 'PointerDownEvent';
  if (event is PointerUpEvent) return 'PointerUpEvent';
  if (event is PointerMoveEvent) return 'PointerMoveEvent';
  if (event is PointerHoverEvent) return 'PointerHoverEvent';
  if (event is PointerCancelEvent) return 'PointerCancelEvent';
  if (event is PointerEnterEvent) return 'PointerEnterEvent';
  if (event is PointerExitEvent) return 'PointerExitEvent';
  if (event is PointerScrollEvent) return 'PointerScrollEvent';
  if (event is PointerScrollInertiaCancelEvent) {
    return 'PointerScrollInertiaCancelEvent';
  }
  if (event is PointerScaleEvent) return 'PointerScaleEvent';
  if (event is PointerPanZoomStartEvent) return 'PointerPanZoomStartEvent';
  if (event is PointerPanZoomUpdateEvent) return 'PointerPanZoomUpdateEvent';
  if (event is PointerPanZoomEndEvent) return 'PointerPanZoomEndEvent';
  // Unknown subclass: obfuscated in release, readable in debug. Better than
  // dropping the attribute entirely.
  return event.runtimeType.toString();
}

/// NOTE: unlike [pointerEventName] this cannot be made obfuscation-stable —
/// it reports whichever widget happens to hold focus, so there is no fixed set
/// to map. Under `flutter build --obfuscate` it returns the obfuscated symbol,
/// which is opaque AND changes between releases, so this attribute stops
/// aggregating across versions. Giving tracked widgets an explicit stable name
/// is the fix if this telemetry matters; see CODE_PROTECTION_PLAN.md P0.1.
@visibleForTesting
String? focusedWidgetTypeName(BuildContext? context) {
  if (context == null || !context.mounted) {
    return null;
  }
  return context.widget.runtimeType.toString();
}

class _AnalyticsInteractionTrackerState
    extends State<AnalyticsInteractionTracker>
    with WidgetsBindingObserver {
  late DateTime Function() _clock;
  late final BurstCoalescer<_KeystrokeRun> _keystrokes;
  late final BurstCoalescer<_InputRun> _input;
  late final BurstCoalescer<_ScrollRun> _scrolls;
  String? _lastFocusTarget;

  @override
  void initState() {
    super.initState();
    _clock = widget.clock ?? (() => DateTime.now().toUtc());
    _keystrokes = BurstCoalescer<_KeystrokeRun>(
      idleTimeout: widget.keystrokeIdleTimeout,
      clock: () => _clock(),
      scheduler: widget.scheduler,
      onSettled: _emitKeystrokeRun,
    );
    _input = BurstCoalescer<_InputRun>(
      idleTimeout: widget.inputIdleTimeout,
      maxRunDuration: widget.inputMaxRunDuration,
      clock: () => _clock(),
      scheduler: widget.scheduler,
      onSettled: _emitInputRun,
    );
    _scrolls = BurstCoalescer<_ScrollRun>(
      idleTimeout: widget.scrollIdleTimeout,
      maxRunDuration: widget.scrollMaxRunDuration,
      clock: () => _clock(),
      scheduler: widget.scheduler,
      onSettled: _emitScrollRun,
    );
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    FocusManager.instance.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant AnalyticsInteractionTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.clock != oldWidget.clock) {
      _clock = widget.clock ?? (() => DateTime.now().toUtc());
    }
  }

  @override
  void dispose() {
    // Emit whatever is half-typed, half-scrolled or half-tapped rather than
    // losing it. Coalescing only pays if the tail of a run still arrives.
    _keystrokes.dispose();
    _input.dispose();
    _scrolls.dispose();
    FocusManager.instance.removeListener(_handleFocusChanged);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // The last reliable moment before the process may be suspended.
      _keystrokes.settleAll();
      _input.settleAll();
      _scrolls.settleAll();
      widget.analyticsEngine.flushFrameSummaries();
    }
    unawaited(
      widget.analyticsEngine.trackUsage(
        AnalyticsEventName.appLifecycleChanged,
        attributes: {'state': state.name},
        flushImmediately: state != AppLifecycleState.resumed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AnalyticsInteractionScope(
      analyticsEngine: widget.analyticsEngine,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _recordPointer('pointer_down', event),
          onPointerUp: (event) => _recordPointer('pointer_up', event),
          onPointerCancel: (event) => _recordPointer('pointer_cancel', event),
          onPointerSignal: _recordPointerSignal,
          child: widget.child,
        ),
      ),
    );
  }

  void _recordPointer(String action, PointerEvent event) {
    final viewport = MediaQuery.maybeSizeOf(context);
    _addToInputRun((run) {
      if (viewport != null) {
        run.absorbViewport(viewport.width, viewport.height);
      }
      switch (action) {
        case 'pointer_down':
          run.absorbPress(
            x: event.position.dx,
            y: event.position.dy,
            at: _clock(),
            kind: event.kind.name,
          );
        case 'pointer_up':
          run.releases += 1;
        case 'pointer_cancel':
          run.cancels += 1;
      }
    });
  }

  void _recordPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final distance = event.scrollDelta.dy.abs() + event.scrollDelta.dx.abs();
      // A wheel tick is counted on the gesture it drives when one is open, so
      // it is not also counted as loose input. It produces a ScrollUpdate of
      // its own, which is what opens that gesture.
      final gesture = _openScrollRun();
      if (gesture != null) {
        gesture.wheelTicks += 1;
        return;
      }
      _addToInputRun((run) {
        run.wheelTicks += 1;
        run.wheelDistance += distance;
        run.kinds.add(event.kind.name);
      });
      return;
    }

    // Everything else a pointer can signal — one such event in a whole field
    // week — is rare enough to keep whole.
    _recordInteraction(
      'pointer_signal',
      target: 'pointer',
      attributes: {'kind': event.kind.name, 'event': pointerEventName(event)},
      metrics: {
        'x': _round(event.position.dx),
        'y': _round(event.position.dy),
        ..._viewportMetrics(),
      },
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    final key = _scrollRunKey(notification);
    _scrolls.add(
      key,
      start: () => _ScrollRun(
        screen: widget.analyticsEngine.currentScreen,
        axis: metrics.axis.name,
        depth: notification.depth,
        startPixels: metrics.pixels,
      )..absorbMetrics(metrics),
      merge: (run) => run..absorbMetrics(metrics),
    );

    final run = _scrolls.valueOf(key);
    if (run == null) {
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      run.updates += 1;
      // Summed on every update, never sampled: a throttle that dropped four
      // updates out of five would leave the distance short by exactly the
      // amount it dropped, and distance is the reason this event exists.
      final delta = notification.scrollDelta;
      if (delta != null) {
        run.distance += delta.abs();
      }
    } else if (notification is OverscrollNotification) {
      run.overscrolls += 1;
      final overscroll = notification.overscroll.abs();
      if (overscroll > run.maxOverscroll) {
        run.maxOverscroll = overscroll;
      }
    } else if (notification is UserScrollNotification) {
      run.absorbDirection(notification.direction.name);
    } else if (notification is ScrollEndNotification) {
      // The real boundary. Settling here rather than waiting out the idle
      // timer keeps one flick as one gesture.
      run.ended = true;
      _scrolls.settle(key);
    }
    return false;
  }

  /// The gesture currently being scrolled, if any — used to attribute a wheel
  /// tick to the movement it caused rather than to loose input.
  _ScrollRun? _openScrollRun() => _scrolls.anyOpenValue();

  String _scrollRunKey(ScrollNotification notification) {
    return '${notification.metrics.axis.name}:${notification.depth}';
  }

  /// Folds one raw input sample into the open run for the current screen.
  ///
  /// Keyed by screen so a navigation starts a fresh run instead of smearing
  /// one across two places.
  void _addToInputRun(void Function(_InputRun run) absorb) {
    final screen = widget.analyticsEngine.currentScreen;
    final key = screen ?? '';
    _input.add(
      key,
      start: () {
        final run = _InputRun(screen: screen);
        final viewport = MediaQuery.maybeSizeOf(context);
        if (viewport != null) {
          run.absorbViewport(viewport.width, viewport.height);
        }
        absorb(run);
        return run;
      },
      merge: (run) {
        absorb(run);
        return run;
      },
    );
  }

  void _emitInputRun(String key, CoalescedBurst<_InputRun> burst) {
    final run = burst.value;
    _recordInteraction(
      'input_activity',
      target: 'input',
      attributes: {
        if (run.screen != null && run.screen!.isNotEmpty) 'screen': run.screen,
        'kinds': run.kinds.toList(growable: false)..sort(),
        // Kept as a histogram rather than as points: enough to draw a heat map
        // of a screen, not enough to reconstruct a gesture.
        'press_grid': run.grid,
      },
      metrics: {
        'sample_count': burst.count,
        'press_count': run.presses,
        'release_count': run.releases,
        'cancel_count': run.cancels,
        'wheel_count': run.wheelTicks,
        'wheel_distance': _round(run.wheelDistance),
        'focus_change_count': run.focusChanges,
        // The finding the raw stream could not produce: a tap that landed
        // where the last one did, because the last one did nothing.
        'repeat_press_count': run.repeatPresses,
        'max_repeat_run': run.maxRepeatRun,
        'duration_ms': burst.duration.inMilliseconds,
        'grid_columns': _InputRun.gridColumns,
        'grid_rows': _InputRun.gridRows,
        if (run.viewportWidth > 0) 'viewport_width': _round(run.viewportWidth),
        if (run.viewportHeight > 0)
          'viewport_height': _round(run.viewportHeight),
      },
    );
  }

  void _emitScrollRun(String key, CoalescedBurst<_ScrollRun> burst) {
    final run = burst.value;
    // Touching a scrollable opens and closes a scroll even when the finger
    // never moves — a tap on a list row is a start and an end with nothing in
    // between. Those are the rows this change exists to stop sending.
    if (run.distance == 0 && run.overscrolls == 0 && run.wheelTicks == 0) {
      return;
    }
    _recordInteraction(
      'scrolled',
      target: 'scrollable',
      attributes: {
        if (run.screen != null && run.screen!.isNotEmpty) 'screen': run.screen,
        'axis': run.axis,
        'depth': run.depth,
        'direction': run.netDelta == 0
            ? 'none'
            : (run.netDelta > 0 ? 'forward' : 'reverse'),
        'reached_end': run.reachedEnd,
        // False means the gesture was cut off — by a navigation, by the app
        // going away, by the run outliving its cap — not that it is still
        // going. Worth knowing before trusting a distance.
        'completed': run.ended,
      },
      metrics: {
        'sample_count': burst.count,
        'update_count': run.updates,
        // How far the thumb travelled, which is not the same as how far the
        // list moved: a search that scrolls down and back covers ground and
        // ends where it started.
        'distance': _round(run.distance),
        'net_delta': _round(run.netDelta),
        'reversal_count': run.reversals,
        'overscroll_count': run.overscrolls,
        'max_overscroll': _round(run.maxOverscroll),
        'wheel_count': run.wheelTicks,
        'start_pixels': _round(run.startPixels),
        'end_pixels': _round(run.endPixels),
        'max_scroll_extent': _round(run.maxScrollExtent),
        'viewport_dimension': _round(run.viewportDimension),
        'duration_ms': burst.duration.inMilliseconds,
      },
    );
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }

    final printable = _isPrintableKey(event);
    final label = _safeKeyLabel(event);
    final category = _keyCategory(event.logicalKey);
    final repeat = event is KeyRepeatEvent;

    _keystrokes.add(
      _keystrokeRunKey,
      start: () => _KeystrokeRun(firstKey: label, firstCategory: category)
        ..absorb(
          label: label,
          category: category,
          printable: printable,
          repeat: repeat,
        ),
      merge: (run) => run
        ..absorb(
          label: label,
          category: category,
          printable: printable,
          repeat: repeat,
        ),
    );

    // A commit key is the end of the entry, not a pause in it — a scanner
    // finishes its code with one. Settling here makes the run boundary the real
    // one instead of whatever the idle timer would have guessed.
    if (_isCommitKey(event.logicalKey)) {
      _keystrokes.settle(_keystrokeRunKey);
    }
    return false;
  }

  static const _keystrokeRunKey = 'keyboard';

  static bool _isCommitKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab;
  }

  void _emitKeystrokeRun(String key, CoalescedBurst<_KeystrokeRun> burst) {
    final run = burst.value;
    _recordInteraction(
      'keys_entered',
      target: 'keyboard',
      attributes: {
        'first_key': run.firstKey,
        'first_key_category': run.firstCategory,
        'last_key': run.lastKey,
        'last_key_category': run.lastCategory,
        // A scanner delivers a whole code faster than any hand: the shape of
        // the run is what distinguishes a scan from typing, and it is the one
        // thing per-key events could never say directly.
        'looks_like_scan': run.looksLikeScan(burst.duration, burst.count),
      },
      metrics: {
        'key_count': burst.count,
        'printable_count': run.printableCount,
        'repeat_count': run.repeatCount,
        'duration_ms': burst.duration.inMilliseconds,
      },
    );
  }

  void _handleFocusChanged() {
    final target = focusedWidgetTypeName(
      FocusManager.instance.primaryFocus?.context,
    );
    if (target == _lastFocusTarget) {
      return;
    }

    _lastFocusTarget = target;
    // Typing into a different field is a different entry.
    _keystrokes.settleAll();
    // Counted, not reported. 12,200 of these arrived in one field week and
    // 12,170 of them named `FocusScope`, `Focus`, or an obfuscated private
    // symbol — the framework wrapper that took focus, never the field. Only 30
    // recorded a *loss*, so there was not even a dwell time to be had. The
    // rate is the whole of what that stream supported, and the run carries it.
    // If field-level attribution is ever wanted, the fix is to give the widgets
    // stable names (see CODE_PROTECTION_PLAN.md P0.1), not to ship the symbols.
    _addToInputRun((run) => run.focusChanges += 1);
  }

  void _recordInteraction(
    String action, {
    required String target,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
  }) {
    unawaited(
      widget.analyticsEngine.trackInteraction(
        action: action,
        target: target,
        attributes: attributes,
        metrics: metrics,
      ),
    );
  }

  Map<String, num> _viewportMetrics() {
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null) {
      return const {};
    }
    return {
      'viewport_width': _round(size.width),
      'viewport_height': _round(size.height),
    };
  }

  String _keyCategory(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return 'submit';
    }
    if (key == LogicalKeyboardKey.escape) {
      return 'escape';
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      return 'delete';
    }
    if (key == LogicalKeyboardKey.tab) {
      return 'navigation';
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      return 'navigation';
    }
    if (key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return 'modifier';
    }
    if (key.keyLabel.startsWith('F') && key.keyLabel.length <= 3) {
      return 'function';
    }
    return 'character';
  }

  String _safeKeyLabel(KeyEvent event) {
    if (_isPrintableKey(event)) {
      return 'printable_character';
    }
    final label = event.logicalKey.keyLabel;
    if (label.isNotEmpty) {
      return label;
    }
    return event.logicalKey.debugName ?? 'unknown';
  }

  bool _isPrintableKey(KeyEvent event) {
    final character = event.character;
    return character != null && character.isNotEmpty;
  }

  double _round(double value) {
    return (value * 100).round() / 100;
  }
}
