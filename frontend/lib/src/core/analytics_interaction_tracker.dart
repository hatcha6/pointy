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
    this.scrollUpdateSampleInterval = const Duration(milliseconds: 250),
    this.keystrokeIdleTimeout = const Duration(milliseconds: 400),
    this.clock,
  });

  final AnalyticsEngine analyticsEngine;
  final Widget child;
  final Duration scrollUpdateSampleInterval;

  /// How long a keyboard run may pause before it counts as finished.
  ///
  /// Individual keystrokes were 1,455,832 rows in the field — half of all
  /// interaction telemetry — and none of them said anything the run did not. A
  /// scanner fires a whole code in a few milliseconds and a person pauses far
  /// longer than this between words, so the boundary lands where a human would
  /// draw it.
  final Duration keystrokeIdleTimeout;
  final DateTime Function()? clock;

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
  DateTime? _lastScrollUpdateAt;
  String? _lastFocusTarget;

  @override
  void initState() {
    super.initState();
    _clock = widget.clock ?? (() => DateTime.now().toUtc());
    _keystrokes = BurstCoalescer<_KeystrokeRun>(
      idleTimeout: widget.keystrokeIdleTimeout,
      clock: () => _clock(),
      onSettled: _emitKeystrokeRun,
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
    // Emit whatever is half-typed rather than losing it.
    _keystrokes.dispose();
    FocusManager.instance.removeListener(_handleFocusChanged);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _keystrokes.settleAll();
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
    _recordInteraction(
      action,
      target: 'pointer',
      attributes: {
        'kind': event.kind.name,
        'event': event.runtimeType.toString(),
      },
      metrics: {
        'x': _round(event.position.dx),
        'y': _round(event.position.dy),
        'local_x': _round(event.localPosition.dx),
        'local_y': _round(event.localPosition.dy),
        'buttons': event.buttons,
        'device': event.device,
        ..._viewportMetrics(),
      },
    );
  }

  void _recordPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _recordInteraction(
        'pointer_scroll',
        target: 'pointer',
        attributes: {'kind': event.kind.name},
        metrics: {
          'x': _round(event.position.dx),
          'y': _round(event.position.dy),
          'scroll_dx': _round(event.scrollDelta.dx),
          'scroll_dy': _round(event.scrollDelta.dy),
          ..._viewportMetrics(),
        },
      );
      return;
    }

    _recordInteraction(
      'pointer_signal',
      target: 'pointer',
      attributes: {
        'kind': event.kind.name,
        'event': event.runtimeType.toString(),
      },
      metrics: {
        'x': _round(event.position.dx),
        'y': _round(event.position.dy),
        ..._viewportMetrics(),
      },
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final action = _scrollAction(notification);
    if (action == 'scroll_update' && !_shouldRecordScrollUpdate()) {
      return false;
    }

    _recordInteraction(
      action,
      target: 'scrollable',
      attributes: {
        'axis': notification.metrics.axis.name,
        'depth': notification.depth,
        if (notification is UserScrollNotification)
          'direction': notification.direction.name,
      },
      metrics: {
        'pixels': _round(notification.metrics.pixels),
        'min_scroll_extent': _round(notification.metrics.minScrollExtent),
        'max_scroll_extent': _round(notification.metrics.maxScrollExtent),
        'viewport_dimension': _round(notification.metrics.viewportDimension),
        if (notification is ScrollUpdateNotification &&
            notification.scrollDelta != null)
          'scroll_delta': _round(notification.scrollDelta!),
        if (notification is OverscrollNotification)
          'overscroll': _round(notification.overscroll),
      },
    );
    return false;
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
    final attributes = <String, Object?>{'has_focus': target != null};
    if (target != null) {
      attributes['widget_type'] = target;
    }
    _recordInteraction(
      'focus_changed',
      target: 'focus',
      attributes: attributes,
    );
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

  bool _shouldRecordScrollUpdate() {
    if (widget.scrollUpdateSampleInterval == Duration.zero) {
      return true;
    }

    final now = _clock();
    final lastUpdate = _lastScrollUpdateAt;
    if (lastUpdate != null &&
        now.difference(lastUpdate) < widget.scrollUpdateSampleInterval) {
      return false;
    }
    _lastScrollUpdateAt = now;
    return true;
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

  String _scrollAction(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      return 'scroll_start';
    }
    if (notification is ScrollUpdateNotification) {
      return 'scroll_update';
    }
    if (notification is OverscrollNotification) {
      return 'scroll_overscroll';
    }
    if (notification is ScrollEndNotification) {
      return 'scroll_end';
    }
    if (notification is UserScrollNotification) {
      return 'scroll_direction';
    }
    return 'scroll';
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
