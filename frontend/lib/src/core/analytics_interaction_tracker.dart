import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models/analytics_event.dart';
import 'analytics_engine.dart';

class AnalyticsInteractionTracker extends StatefulWidget {
  const AnalyticsInteractionTracker({
    super.key,
    required this.analyticsEngine,
    required this.child,
    this.scrollUpdateSampleInterval = const Duration(milliseconds: 250),
    this.clock,
  });

  final AnalyticsEngine analyticsEngine;
  final Widget child;
  final Duration scrollUpdateSampleInterval;
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

class _AnalyticsInteractionTrackerState
    extends State<AnalyticsInteractionTracker>
    with WidgetsBindingObserver {
  late DateTime Function() _clock;
  DateTime? _lastScrollUpdateAt;
  String? _lastFocusTarget;

  @override
  void initState() {
    super.initState();
    _clock = widget.clock ?? (() => DateTime.now().toUtc());
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
    FocusManager.instance.removeListener(_handleFocusChanged);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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

    _recordInteraction(
      event is KeyRepeatEvent ? 'key_repeat' : 'key_down',
      target: 'keyboard',
      attributes: {
        'key_category': _keyCategory(event.logicalKey),
        'key_label': _safeKeyLabel(event),
        'is_printable': _isPrintableKey(event),
        'shift_pressed': HardwareKeyboard.instance.isShiftPressed,
        'control_pressed': HardwareKeyboard.instance.isControlPressed,
        'alt_pressed': HardwareKeyboard.instance.isAltPressed,
        'meta_pressed': HardwareKeyboard.instance.isMetaPressed,
      },
    );
    return false;
  }

  void _handleFocusChanged() {
    final target = FocusManager
        .instance
        .primaryFocus
        ?.context
        ?.widget
        .runtimeType
        .toString();
    if (target == _lastFocusTarget) {
      return;
    }

    _lastFocusTarget = target;
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
